"""Offline checks for the per-slot reset's generated-state handling."""

import base64
import csv
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("reset_student", ROOT / "infra/scripts/reset-student.py")
reset = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reset)


class ResetStudentTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.generated = Path(self.temporary.name)
        subprocess.run(
            [str(ROOT / "infra/scripts/generate-pods.sh"), "-n", "2", "--host", "class.example.test"],
            env={**os.environ, "OUTPUT_DIR": str(self.generated), "KUBECONFIG": ""},
            check=True, capture_output=True, text=True,
        )

    def test_only_target_password_changes(self):
        with (self.generated / "access-cards.csv").open(newline="") as handle:
            before = list(csv.DictReader(handle))
        inventory = reset.rotate_local(self.generated, "s01", before[0]["password"], "new-secret")
        with (self.generated / "access-cards.csv").open(newline="") as handle:
            after = list(csv.DictReader(handle))
        self.assertEqual(after[0]["password"], "new-secret")
        self.assertEqual(after[1], before[1])
        self.assertEqual(json.loads(inventory)[0]["workspace_password"], "new-secret")
        portal = (self.generated / "student-access.yaml").read_text()
        encoded = portal.split("  slots.json: ", 1)[1].splitlines()[0]
        self.assertEqual(json.loads(base64.b64decode(encoded))[1]["workspace_password"], before[1]["password"])
        self.assertIn('password: "new-secret"', (self.generated / "workspace-secrets.yaml").read_text())
        self.assertIn(f'password: "{before[1]["password"]}"', (self.generated / "workspace-secrets.yaml").read_text())
        subprocess.run(
            [str(ROOT / "infra/scripts/generate-pods.sh"), "-n", "2", "--host", "class.example.test"],
            env={**os.environ, "OUTPUT_DIR": str(self.generated), "KUBECONFIG": ""},
            check=True, capture_output=True, text=True,
        )
        with (self.generated / "access-cards.csv").open(newline="") as handle:
            regenerated = list(csv.DictReader(handle))
        self.assertEqual(regenerated[0]["password"], "new-secret")
        self.assertEqual(regenerated[1], before[1])

    def test_refuses_mismatched_local_state(self):
        with self.assertRaisesRegex(RuntimeError, "does not match"):
            reset.rotate_local(self.generated, "s01", "wrong", "new-secret")

    def test_selects_only_target_namespace(self):
        rendered = subprocess.run(
            ["helm", "template", "awp", str(ROOT / "infra/helm"),
             "--set", "student_count=2", "--set", "cluster_access=scoped",
             "--set", "inference=dedicated-vllm"],
            check=True, capture_output=True, text=True,
        ).stdout
        path = self.generated / "rendered.yaml"
        path.write_text(rendered)
        target = reset.selected(path, "workshop-s01", include_namespace=True)
        resources = [reset.identity(doc) for doc in reset.documents(target)]
        self.assertIn(("Namespace", "workshop-s01", ""), resources)
        self.assertIn(("Deployment", "vllm", "workshop-s01"), resources)
        self.assertNotIn(("Deployment", "vllm", "workshop-s02"), resources)
        self.assertTrue(all(namespace in ("", "workshop-s01") for _, _, namespace in resources))

    def test_replaces_only_target_scoped_kubeconfig(self):
        path = self.generated / "workspace-kubeconfigs.yaml"
        path.write_text("""apiVersion: v1
kind: Secret
metadata:
  name: ws-01-kubeconfig
  namespace: workshop-s01
stringData:
  config: old-one
---
apiVersion: v1
kind: Secret
metadata:
  name: ws-02-kubeconfig
  namespace: workshop-s02
stringData:
  config: old-two
""")
        fresh = """apiVersion: v1
kind: Secret
metadata:
  name: ws-01-kubeconfig
  namespace: workshop-s01
stringData:
  config: new-one
"""
        reset.replace_scoped_kubeconfig(self.generated, "s01", "workshop-s01", fresh)
        changed = path.read_text()
        self.assertIn("config: new-one", changed)
        self.assertNotIn("config: old-one", changed)
        self.assertIn("config: old-two", changed)

    def test_scoped_baseline_includes_only_target_agent(self):
        subprocess.run(
            [str(ROOT / "infra/scripts/generate-pods.sh"), "-n", "2", "--host", "class.example.test",
             "--cluster-access", "scoped", "--agent-deploy", "plain"],
            env={**os.environ, "OUTPUT_DIR": str(self.generated), "KUBECONFIG": ""},
            check=True, capture_output=True, text=True,
        )
        target = reset.selected(self.generated / "workspace-manifests.yaml", "workshop-s01")
        resources = [reset.identity(doc) for doc in reset.documents(target)]
        self.assertIn(("Deployment", "agent", "workshop-s01"), resources)
        self.assertIn(("Service", "agent", "workshop-s01"), resources)
        self.assertNotIn(("Deployment", "agent", "workshop-s02"), resources)


if __name__ == "__main__":
    unittest.main()
