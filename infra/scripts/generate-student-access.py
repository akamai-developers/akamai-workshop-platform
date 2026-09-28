#!/usr/bin/env python3
"""Generate the self-service student access portal Kubernetes resources."""

from __future__ import annotations

import argparse
import base64
import csv
import hashlib
import json
import os
import re
import secrets
import subprocess
from pathlib import Path


DEFAULT_IMAGE = (
    "ghcr.io/muchobien/pocketbase:0.40.4@"
    "sha256:9390b7b63ce114dbab577be72e6ef75f718a19083866607fcbdd1b915632b943"
)


def yaml_string(value: str) -> str:
    return json.dumps(value)


def indented_block(value: str, spaces: int = 4) -> str:
    prefix = " " * spaces
    if not value.endswith("\n"):
        value += "\n"
    return "".join(prefix + line for line in value.splitlines(keepends=True))


def read_slots(csv_path: Path) -> list[dict[str, object]]:
    slots: list[dict[str, object]] = []
    with csv_path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        expected = {"student_number", "url", "password"}
        if set(reader.fieldnames or ()) != expected:
            raise ValueError(f"{csv_path} must have columns: student_number,url,password")

        for index, row in enumerate(reader, start=1):
            student_number = row["student_number"].strip()
            match = re.fullmatch(r"s([0-9]{2,})", student_number)
            if not match or int(match.group(1)) != index:
                raise ValueError(f"{csv_path}: expected sequential slot s{index:02d}")
            if not row["url"].startswith("https://") or not row["password"]:
                raise ValueError(f"{csv_path}: invalid URL or password for {student_number}")
            slots.append(
                {
                    "student_number": student_number,
                    "workspace_url": row["url"],
                    "workspace_password": row["password"],
                }
            )

    if not slots:
        raise ValueError(f"{csv_path} contains no workspace slots")
    return slots


def previous_admin_password(output_path: Path) -> str | None:
    try:
        previous = output_path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return None
    match = re.search(r"^  PB_ADMIN_PASSWORD: (.+)$", previous, re.MULTILINE)
    if not match:
        return None
    try:
        password = json.loads(match.group(1))
    except json.JSONDecodeError:
        return None
    return password if isinstance(password, str) and password else None


def cluster_admin_password(namespace: str) -> str | None:
    """Use the live Secret when deploying to a known cluster; never replace it blindly."""
    if not os.environ.get("KUBECONFIG"):
        return None
    command = ["kubectl", "-n", namespace, "get"]
    result = subprocess.run(
        command + ["secret", "join-portal-admin", "-o", "json"],
        text=True, capture_output=True, check=False,
    )
    if result.returncode == 0:
        encoded = json.loads(result.stdout).get("data", {}).get("PB_ADMIN_PASSWORD")
        if not encoded:
            raise ValueError("live join-portal-admin Secret has no PB_ADMIN_PASSWORD")
        return base64.b64decode(encoded, validate=True).decode("utf-8")
    if "NotFound" not in result.stderr:
        raise ValueError(f"cannot read live join-portal-admin Secret: {result.stderr.strip()}")
    for kind, name in (("pvc", "join-portal-data"), ("deployment", "join-portal")):
        check = subprocess.run(
            command + [kind, name, "-o", "name"],
            text=True, capture_output=True, check=False,
        )
        if check.returncode == 0:
            raise ValueError(f"live {kind}/{name} exists without join-portal-admin Secret; refusing to mint a new password")
        if "NotFound" not in check.stderr:
            raise ValueError(f"cannot check live {kind}/{name}: {check.stderr.strip()}")
    return None


def configmap(name: str, namespace: str, source_dir: Path) -> str:
    files = sorted(path for path in source_dir.iterdir() if path.is_file())
    if not files:
        raise ValueError(f"no files found in {source_dir}")

    lines = [
        "apiVersion: v1",
        "kind: ConfigMap",
        "metadata:",
        f"  name: {name}",
        f"  namespace: {namespace}",
        "data:",
    ]
    for path in files:
        lines.append(f"  {path.name}: |")
        lines.append(indented_block(path.read_text(encoding="utf-8"), 4).rstrip("\n"))
    return "\n".join(lines)


def render(args: argparse.Namespace) -> str:
    assets = args.assets.resolve()
    slots = read_slots(args.csv.resolve())
    slots_json = json.dumps(slots, separators=(",", ":"))
    slots_b64 = base64.b64encode(slots_json.encode()).decode()
    admin_password = cluster_admin_password(args.namespace) or previous_admin_password(args.output.resolve()) or secrets.token_hex(24)
    join_host = f"join.{args.host}"
    code_hash = hashlib.sha256()
    for path in sorted(path for path in assets.rglob("*") if path.is_file()):
        code_hash.update(str(path.relative_to(assets)).encode())
        code_hash.update(path.read_bytes())
    code_checksum = code_hash.hexdigest()

    sections = [
        configmap("join-portal-public", args.namespace, assets / "pb_public"),
        configmap("join-portal-hooks", args.namespace, assets / "pb_hooks"),
        configmap("join-portal-migrations", args.namespace, assets / "pb_migrations"),
        f"""apiVersion: v1
kind: Secret
metadata:
  name: join-portal-slots
  namespace: {args.namespace}
type: Opaque
data:
  slots.json: {slots_b64}""",
        f"""apiVersion: v1
kind: Secret
metadata:
  name: join-portal-admin
  namespace: {args.namespace}
type: Opaque
stringData:
  PB_ADMIN_EMAIL: "admin@workshop.local"
  PB_ADMIN_PASSWORD: {yaml_string(admin_password)}""",
        f"""apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: join-portal-data
  namespace: {args.namespace}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: {args.storage_class}
  resources:
    requests:
      storage: 1Gi""",
        f"""apiVersion: apps/v1
kind: Deployment
metadata:
  name: join-portal
  namespace: {args.namespace}
  labels:
    app: join-portal
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: join-portal
  template:
    metadata:
      labels:
        app: join-portal
      annotations:
        workshop.akamai.com/code-checksum: {code_checksum}
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        fsGroupChangePolicy: OnRootMismatch
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: pocketbase
          image: {yaml_string(args.image)}
          imagePullPolicy: IfNotPresent
          args:
            - --migrationsDir=/pb_migrations
            - --automigrate=false
          envFrom:
            - secretRef:
                name: join-portal-admin
          env:
            - name: GOMEMLIMIT
              value: 192MiB
            - name: WORKSHOP_SLOTS_FILE
              value: /portal-config/slots.json
          ports:
            - name: http
              containerPort: 8090
              protocol: TCP
          readinessProbe:
            httpGet:
              path: /api/health
              port: http
            initialDelaySeconds: 2
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 12
          livenessProbe:
            httpGet:
              path: /api/health
              port: http
            initialDelaySeconds: 10
            periodSeconds: 15
            timeoutSeconds: 3
          resources:
            requests:
              cpu: 25m
              memory: 64Mi
            limits:
              cpu: 500m
              memory: 256Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          volumeMounts:
            - name: data
              mountPath: /pb_data
            - name: public
              mountPath: /pb_public
              readOnly: true
            - name: hooks
              mountPath: /pb_hooks
              readOnly: true
            - name: migrations
              mountPath: /pb_migrations
              readOnly: true
            - name: slots
              mountPath: /portal-config
              readOnly: true
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: join-portal-data
        - name: public
          configMap:
            name: join-portal-public
        - name: hooks
          configMap:
            name: join-portal-hooks
        - name: migrations
          configMap:
            name: join-portal-migrations
        - name: slots
          secret:
            secretName: join-portal-slots
        - name: tmp
          emptyDir: {{}}""",
        f"""apiVersion: v1
kind: Service
metadata:
  name: join-portal
  namespace: {args.namespace}
  labels:
    app: join-portal
spec:
  type: ClusterIP
  selector:
    app: join-portal
  ports:
    - name: http
      port: 8090
      targetPort: http
      protocol: TCP""",
        f"""apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: join-portal
  namespace: {args.namespace}
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - {join_host}
      secretName: {args.tls_secret}
  rules:
    - host: {join_host}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: join-portal
                port:
                  number: 8090""",
        f"""apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-to-join-portal
  namespace: {args.namespace}
spec:
  podSelector:
    matchLabels:
      app: join-portal
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
      ports:
        - protocol: TCP
          port: 8090""",
    ]
    return "\n---\n".join(sections) + "\n"


def main() -> int:
    script_dir = Path(__file__).resolve().parent
    default_assets = script_dir.parent / "student-access"

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--csv", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--host", required=True)
    parser.add_argument("--namespace", default="workshop")
    parser.add_argument("--tls-secret", default="workshop-tls")
    parser.add_argument("--storage-class", default="linode-block-storage")
    parser.add_argument("--image", default=DEFAULT_IMAGE)
    parser.add_argument("--assets", type=Path, default=default_assets)
    args = parser.parse_args()

    for label, value, pattern in (
        ("namespace", args.namespace, r"[a-z0-9]([-a-z0-9]*[a-z0-9])?"),
        ("host", args.host, r"[A-Za-z0-9.-]+"),
        ("tls secret", args.tls_secret, r"[a-z0-9]([-a-z0-9.]*[a-z0-9])?"),
        ("storage class", args.storage_class, r"[A-Za-z0-9.-]+"),
    ):
        if not re.fullmatch(pattern, value):
            parser.error(f"invalid {label}: {value!r}")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    rendered = render(args)
    temp = args.output.with_suffix(args.output.suffix + ".tmp")
    temp.write_text(rendered, encoding="utf-8")
    temp.replace(args.output)
    print(f"Wrote student access portal resources -> {args.output}")
    print(f"  Join URL: https://join.{args.host}/")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
