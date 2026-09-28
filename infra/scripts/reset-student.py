#!/usr/bin/env python3
"""Reclaim one used workshop slot without touching another student's resources.

Requires the operator kubeconfig and the generated state from the deployed classroom.
Run without --confirm to inspect the target; --confirm permanently removes its data.
"""

from __future__ import annotations

import argparse
import base64
import contextlib
import csv
import io
import json
import os
from pathlib import Path
import re
import secrets
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request


INFRA = Path(__file__).resolve().parent.parent


def command(*args: str, input_text: str | None = None, env: dict[str, str] | None = None) -> str:
    result = subprocess.run(args, input=input_text, text=True, capture_output=True, check=False, env=env)
    if result.returncode:
        raise RuntimeError(f"{' '.join(args[:5])} failed: {result.stderr.strip()}")
    return result.stdout


def kube(namespace: str | None, *args: str, input_text: str | None = None) -> str:
    prefix = ("kubectl", "-n", namespace) if namespace else ("kubectl",)
    return command(*prefix, *args, input_text=input_text)


def secret_data(namespace: str, name: str, field: str) -> bytes:
    secret = json.loads(kube(namespace, "get", f"secret/{name}", "-o", "json"))
    encoded = secret.get("data", {}).get(field)
    if not encoded:
        raise RuntimeError(f"{namespace}/secret/{name} is missing {field}")
    return base64.b64decode(encoded, validate=True)


def optional_resource(namespace: str | None, kind_name: str) -> dict | None:
    prefix = ["kubectl", "-n", namespace] if namespace else ["kubectl"]
    result = subprocess.run([*prefix, "get", kind_name, "-o", "json"], text=True, capture_output=True, check=False)
    if result.returncode == 0:
        return json.loads(result.stdout)
    if "NotFound" in result.stderr:
        return None
    raise RuntimeError(f"cannot inspect {kind_name}: {result.stderr.strip()}")


def value(source: str, key: str) -> str:
    match = re.search(rf"(?m)^{re.escape(key)}:\s*(.*?)\s*(?:#.*)?$", source)
    if not match:
        raise RuntimeError(f"generated Helm values are missing {key}")
    return match.group(1).strip().strip('"\'')


def documents(source: str) -> list[str]:
    return [part.strip() + "\n" for part in re.split(r"(?m)^---\s*$", source) if part.strip()]


def identity(document: str) -> tuple[str, str, str]:
    kind = re.search(r"(?m)^kind:\s*(\S+)", document)
    metadata = re.search(r"(?m)^metadata:\s*\n((?:^  .*\n|^\s*\n)*)", document)
    if not kind or not metadata:
        return "", "", ""
    name = re.search(r"(?m)^  name:\s*(\S+)", metadata.group(1))
    namespace = re.search(r"(?m)^  namespace:\s*(\S+)", metadata.group(1))
    return kind.group(1), name.group(1) if name else "", namespace.group(1) if namespace else ""


def selected(path: Path, namespace: str, *, include_namespace: bool = False) -> str:
    chosen = []
    for doc in documents(path.read_text(encoding="utf-8")):
        kind, name, doc_namespace = identity(doc)
        if doc_namespace == namespace or (include_namespace and kind == "Namespace" and name == namespace):
            chosen.append(doc)
    if not chosen:
        raise RuntimeError(f"no resources for {namespace} in {path}")
    return "---\n".join(chosen)


def atomic_write(path: Path, content: str) -> None:
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, prefix=path.name + ".", delete=False) as handle:
        temporary = Path(handle.name)
        handle.write(content)
    try:
        os.chmod(temporary, path.stat().st_mode & 0o777)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def rotate_local(generated: Path, slot: str, old_password: str, new_password: str) -> bytes:
    csv_path = generated / "access-cards.csv"
    with csv_path.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    row = next((item for item in rows if item["student_number"] == slot), None)
    if row is None or row["password"] != old_password:
        raise RuntimeError("local access-cards.csv does not match the expected slot/password")
    row["password"] = new_password
    buffer = io.StringIO(newline="")
    writer = csv.DictWriter(buffer, fieldnames=["student_number", "url", "password"])
    writer.writeheader()
    writer.writerows(rows)

    number = slot[1:]
    secret_path = generated / "workspace-secrets.yaml"
    secret_docs = documents(secret_path.read_text(encoding="utf-8"))
    changed = 0
    for index, doc in enumerate(secret_docs):
        if identity(doc)[1] == f"ws-{number}-password":
            previous = f'  password: "{old_password}"'
            if previous not in doc:
                raise RuntimeError("local workspace Secret differs from access-cards.csv")
            secret_docs[index] = doc.replace(previous, f'  password: "{new_password}"', 1)
            changed += 1
    if changed != 1:
        raise RuntimeError("expected exactly one generated workspace password Secret")

    portal_path = generated / "student-access.yaml"
    portal = portal_path.read_text(encoding="utf-8")
    encoded = re.search(r"(?m)^  slots\.json: (\S+)$", portal)
    if not encoded:
        raise RuntimeError("generated portal inventory is missing")
    slots = json.loads(base64.b64decode(encoded.group(1), validate=True))
    matches = [item for item in slots if item["student_number"] == slot]
    if len(matches) != 1 or matches[0]["workspace_password"] != old_password:
        raise RuntimeError("generated portal inventory differs from access-cards.csv")
    matches[0]["workspace_password"] = new_password
    inventory = json.dumps(slots, separators=(",", ":")).encode("utf-8")
    portal = portal[:encoded.start(1)] + base64.b64encode(inventory).decode("ascii") + portal[encoded.end(1):]

    atomic_write(csv_path, buffer.getvalue())
    atomic_write(secret_path, "---\n".join(secret_docs))
    atomic_write(portal_path, portal)
    return inventory


def storage_location(generated: Path, slot: str, student_ns: str) -> tuple[str, str]:
    with (generated / "object-storage.csv").open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    row = next((item for item in rows if item["student_number"] == slot), None)
    if row is None or not row["bucket"].endswith("-" + slot):
        raise RuntimeError("managed storage row is missing or has an unexpected bucket")
    prefix = row["bucket"][: -len(slot) - 1]
    manifest = selected(generated / "workspace-object-storage.yaml", student_ns)
    docs = [doc for doc in documents(manifest) if identity(doc)[1] == f"ws-{slot[1:]}-object-storage"]
    if len(docs) != 1:
        raise RuntimeError("managed storage Secret is missing from the generated baseline")
    region = re.search(r'(?m)^  SESSION_REGION:\s*"([A-Za-z0-9-]+)"$', docs[0])
    if not region:
        raise RuntimeError("managed storage region is missing from the generated baseline")
    return prefix, region.group(1)


def replace_scoped_kubeconfig(generated: Path, slot: str, student_ns: str, fresh: str) -> None:
    path = generated / "workspace-kubeconfigs.yaml"
    docs = documents(path.read_text(encoding="utf-8"))
    fresh_docs = documents(fresh)
    if len(fresh_docs) != 1 or identity(fresh_docs[0]) != ("Secret", f"ws-{slot[1:]}-kubeconfig", student_ns):
        raise RuntimeError("new scoped kubeconfig has an unexpected identity")
    matches = [index for index, doc in enumerate(docs) if identity(doc) == identity(fresh_docs[0])]
    if len(matches) != 1:
        raise RuntimeError("existing generated kubeconfig inventory lacks exactly one matching slot")
    docs[matches[0]] = fresh_docs[0]
    atomic_write(path, "---\n".join(docs))


@contextlib.contextmanager
def service_forward(namespace: str, service: str, target_port: int, path: str, attempts: int = 60):
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    process = None
    detail = ""
    base = f"http://127.0.0.1:{port}"
    try:
        for _ in range(attempts):
            if process is None or process.poll() is not None:
                if process is not None and process.stderr:
                    detail = process.stderr.read().decode("utf-8", "replace").strip()
                process = subprocess.Popen(
                    ["kubectl", "-n", namespace, "port-forward", f"service/{service}",
                     f"{port}:{target_port}", "--address=127.0.0.1"],
                    stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                )
            try:
                with urllib.request.urlopen(base + path, timeout=1):
                    yield base
                    return
            except (OSError, urllib.error.URLError):
                time.sleep(0.2)
        raise RuntimeError(f"{namespace}/service/{service} did not become HTTP-ready: {detail}")
    finally:
        if process is not None:
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            if process.stderr:
                process.stderr.close()


def portal_forward(namespace: str):
    return service_forward(namespace, "join-portal", 8090, "/api/health")


def api(base: str, path: str, *, token: str = "", method: str = "GET", body: dict | None = None) -> dict:
    payload = json.dumps(body).encode("utf-8") if body is not None else None
    request = urllib.request.Request(base + path, data=payload, method=method)
    request.add_header("Content-Type", "application/json")
    if token:
        request.add_header("Authorization", token)
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"PocketBase {method} {path.split('?')[0]} returned HTTP {error.code}") from error


def admin_token(base: str, namespace: str) -> str:
    password = secret_data(namespace, "join-portal-admin", "PB_ADMIN_PASSWORD").decode("utf-8")
    email = secret_data(namespace, "join-portal-admin", "PB_ADMIN_EMAIL").decode("utf-8")
    auth = api(base, "/api/collections/_superusers/auth-with-password", method="POST", body={"identity": email, "password": password})
    return auth["token"]


def registration(base: str, token: str, number: int) -> dict:
    query = urllib.parse.urlencode({"filter": f"slot={number}", "perPage": 2})
    records = api(base, f"/api/collections/registrations/records?{query}", token=token)["items"]
    if len(records) != 1:
        raise RuntimeError(f"expected one claimed registration for s{number:02d}; found {len(records)}")
    return records[0]


def verify_reset_guard(base: str, email: str) -> None:
    request = urllib.request.Request(
        base + "/api/workshop/register",
        data=json.dumps({"name": "Reset check", "email": email}).encode("utf-8"),
        method="POST",
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=10):
            raise RuntimeError("portal still returns an assignment while the slot is resetting")
    except urllib.error.HTTPError as error:
        body = json.loads(error.read())
        if error.code != 409 or body.get("code") != "WORKSPACE_RESETTING":
            raise RuntimeError("portal reset guard is not active; slot remains blocked") from error


def apply(namespace: str | None, manifest: str) -> None:
    kube(namespace, "apply", "-f", "-", input_text=manifest)


def reset(args: argparse.Namespace) -> None:
    os.environ["KUBECONFIG"] = str(args.kubeconfig.resolve())
    generated = args.generated.resolve()
    helm_values = args.helm_values.read_text(encoding="utf-8")
    base_ns = value(helm_values, "namespace")
    count = int(value(helm_values, "student_count"))
    number = int(args.slot[1:])
    if number < 1 or number > count:
        raise RuntimeError(f"{args.slot} is outside this classroom's 1-{count} inventory")
    scoped = value(helm_values, "cluster_access") == "scoped"
    inference = value(helm_values, "inference")
    managed = value(helm_values, "object_storage") == "managed"
    student_ns = f"{base_ns}-{args.slot}" if scoped else base_ns
    csv_path = generated / "access-cards.csv"
    with csv_path.open(newline="", encoding="utf-8") as handle:
        cards = list(csv.DictReader(handle))
    card = next((row for row in cards if row["student_number"] == args.slot), None)
    if card is None:
        raise RuntimeError(f"{args.slot} is not in {csv_path}")
    for filename in ("workspace-secrets.yaml", "workspace-manifests.yaml", "student-access.yaml"):
        if not (generated / filename).is_file():
            raise RuntimeError(f"missing generated/{filename}; cannot safely restore baseline")
    if scoped and not (generated / "rendered.yaml").is_file():
        raise RuntimeError("missing generated/rendered.yaml; cannot safely rebuild student namespace")
    if scoped and not (generated / "workspace-kubeconfigs.yaml").is_file():
        raise RuntimeError("missing generated/workspace-kubeconfigs.yaml; cannot preserve regenerated scoped credentials")
    if managed and not (generated / "object-storage.csv").is_file():
        raise RuntimeError("missing generated/object-storage.csv; cannot safely clear student storage")
    storage = storage_location(generated, args.slot, student_ns) if managed else None
    context = kube(None, "config", "current-context").strip()
    print(f"Context: {context}; slot: {args.slot}; namespace: {student_ns}")
    print(f"Reset: workspace, credential, portal assignment; scoped={scoped}, inference={inference}, managed storage={managed}")
    if scoped:
        print("The entire student namespace and its PVCs will be deleted and restored from the deployed baseline.")
    if inference == "shared-vllm":
        print("Shared vLLM is not restarted; other students continue using it.")
    elif inference == "external":
        print("External inference is outside this platform and will not be reset.")
    if not args.confirm:
        print("DRY RUN: no resources changed. Pass --confirm to erase this slot's data and release it.")
        return

    with portal_forward(base_ns) as base:
        token = admin_token(base, base_ns)
        record = registration(base, token, number)
        if scoped:
            namespace = optional_resource(None, f"namespace/{student_ns}")
            if namespace is not None:
                labels = namespace.get("metadata", {}).get("labels", {})
                if labels.get("awp-student") != "true" or labels.get("awp-student-number") != str(number):
                    raise RuntimeError("student namespace lacks the expected ownership labels; refusing deletion")
        else:
            pod = optional_resource(student_ns, f"pod/ws-{args.slot[1:]}")
            if pod is not None:
                labels = pod.get("metadata", {}).get("labels", {})
                if labels.get("app") != "workspace" or labels.get("student") != str(number):
                    raise RuntimeError("workspace Pod lacks the expected ownership labels; refusing deletion")
        if not record.get("resetting"):
            live_inventory = json.loads(secret_data(base_ns, "join-portal-slots", "slots.json"))
            live = next((item for item in live_inventory if item["student_number"] == args.slot), None)
            if live is None or live["workspace_password"] != card["password"] or live["workspace_url"] != card["url"]:
                raise RuntimeError("live portal inventory differs from local CSV; refusing reset")
            live_password = secret_data(student_ns, f"ws-{args.slot[1:]}-password", "password").decode("utf-8")
            if live_password != card["password"]:
                raise RuntimeError("live workspace credential differs from local CSV; refusing reset")
        record = api(base, f"/api/collections/registrations/records/{record['id']}", token=token,
                     method="PATCH", body={"resetting": True})
        if not record.get("resetting"):
            raise RuntimeError("PocketBase reset guard is unavailable; deploy the new migration before resetting")
        verify_reset_guard(base, record["email"])
    print("Registration reserved and blocked during reset.")

    if scoped:
        kube(None, "delete", f"namespace/{student_ns}", "--ignore-not-found", "--wait=true", "--timeout=300s")
        baseline = selected(generated / "rendered.yaml", student_ns, include_namespace=True)
        namespace_docs = [doc for doc in documents(baseline) if identity(doc)[0] == "Namespace"]
        if len(namespace_docs) != 1:
            raise RuntimeError("baseline must contain exactly one student Namespace")
        apply(None, namespace_docs[0])
        apply(None, "---\n".join(doc for doc in documents(baseline) if identity(doc)[0] != "Namespace"))
        tls = json.loads(kube(base_ns, "get", "secret/workshop-tls", "-o", "json"))
        tls["metadata"] = {"name": "workshop-tls", "namespace": student_ns}
        for field in ("status",):
            tls.pop(field, None)
        apply(None, json.dumps(tls))
    else:
        kube(student_ns, "delete", f"pod/ws-{args.slot[1:]}", "--ignore-not-found", "--wait=true", "--timeout=180s")

    if managed:
        # The existing bucket is emptied and only this slot's key is rotated.
        command(str(INFRA / "scripts/provision-object-storage.sh"), "-n", str(count),
                "--region", storage[1],
                "--prefix", storage[0],
                "--namespace", base_ns, "--cluster-access", "scoped" if scoped else "none",
                "--reset-slot", args.slot, "--confirm-reset")

    new_password = secrets.token_hex(16)
    inventory = rotate_local(generated, args.slot, card["password"], new_password)
    password_manifest = selected(generated / "workspace-secrets.yaml", student_ns)
    password_doc = next(doc for doc in documents(password_manifest) if identity(doc)[1] == f"ws-{args.slot[1:]}-password")
    apply(None, password_doc)
    if scoped:
        apply(None, selected(generated / "workspace-startup-configmap.yaml", student_ns))
        with tempfile.TemporaryDirectory(prefix="awp-reset-") as directory:
            fresh_kubeconfig = Path(directory) / "kubeconfig.yaml"
            command(str(INFRA / "scripts/generate-kubeconfig.sh"), "-n", str(count),
                    "--namespace", base_ns, "--slot", args.slot, "--output", str(fresh_kubeconfig))
            fresh = fresh_kubeconfig.read_text(encoding="utf-8")
            replace_scoped_kubeconfig(generated, args.slot, student_ns, fresh)
            apply(None, fresh)
        if managed:
            apply(None, selected(generated / "workspace-object-storage.yaml", student_ns))
        apply(None, selected(generated / "workspace-manifests.yaml", student_ns))
        apply(None, selected(generated / "ingress.yaml", student_ns))
    else:
        if managed:
            apply(None, selected(generated / "workspace-object-storage.yaml", student_ns))
        manifest = selected(generated / "workspace-manifests.yaml", student_ns)
        slot_docs = [doc for doc in documents(manifest) if identity(doc)[1] == f"ws-{args.slot[1:]}"]
        if len(slot_docs) != 2:
            raise RuntimeError("expected one workspace Pod and Service in the baseline")
        apply(None, "---\n".join(slot_docs))

    kube(student_ns, "wait", "--for=condition=Ready", f"pod/ws-{args.slot[1:]}", "--timeout=300s")
    with service_forward(student_ns, f"ws-{args.slot[1:]}", 8080, "/", attempts=600):
        pass
    if scoped and inference == "dedicated-vllm":
        kube(student_ns, "rollout", "status", "deployment/vllm", "--timeout=1800s")
    if scoped and value(helm_values, "agent_deploy") == "plain":
        kube(student_ns, "rollout", "status", "deployment/agent", "--timeout=300s")

    # Updating a Secret volume can lag; a portal rollout guarantees it reads the new
    # inventory before the claimed record is released to another student.
    apply(None, json.dumps({"apiVersion": "v1", "kind": "Secret", "metadata":
                            {"name": "join-portal-slots", "namespace": base_ns},
                            "type": "Opaque", "data": {"slots.json": base64.b64encode(inventory).decode("ascii")}}))
    kube(base_ns, "rollout", "restart", "deployment/join-portal")
    kube(base_ns, "rollout", "status", "deployment/join-portal", "--timeout=180s")
    command(str(INFRA / "scripts/print-access-cards.sh"), env={**os.environ, "OUTPUT_DIR": str(generated)})
    with portal_forward(base_ns) as base:
        token = admin_token(base, base_ns)
        record = registration(base, token, number)
        if not record.get("resetting"):
            raise RuntimeError("registration reset guard was removed unexpectedly; not releasing")
        api(base, f"/api/collections/registrations/records/{record['id']}", token=token, method="DELETE")
    print(f"{args.slot} is clean, ready, and available for the next registration.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--slot", required=True, help="student slot such as s01")
    parser.add_argument("--generated", type=Path, default=INFRA / "manifests/generated")
    parser.add_argument("--helm-values", type=Path, default=INFRA / "manifests/helm-values.yaml")
    parser.add_argument("--kubeconfig", type=Path, default=INFRA / "kubeconfig.yaml")
    parser.add_argument("--confirm", action="store_true", help="erase student data and release the slot")
    args = parser.parse_args()
    if not re.fullmatch(r"s[0-9]{2}", args.slot):
        parser.error("--slot must be sNN")
    if not args.kubeconfig.is_file():
        parser.error(f"operator kubeconfig is missing: {args.kubeconfig}")
    try:
        reset(args)
    except (OSError, ValueError, KeyError, RuntimeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        print("If the registration was marked resetting, it remains unavailable. Repair the issue and rerun this command.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
