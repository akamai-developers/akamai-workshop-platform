"""Offline tests for preserving the live portal administrator credential."""

import base64
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("student_access_generator", ROOT / "infra/scripts/generate-student-access.py")
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


class AdminPasswordTest(unittest.TestCase):
    def test_preserves_password_from_previous_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "portal.yaml"
            path.write_text('  PB_ADMIN_PASSWORD: "old-admin-password"\n')
            self.assertEqual(generator.previous_admin_password(path), "old-admin-password")

    @mock.patch.dict(os.environ, {"KUBECONFIG": "/tmp/test-kubeconfig"})
    @mock.patch.object(subprocess, "run")
    def test_uses_live_secret(self, run):
        encoded = base64.b64encode(b"live-admin-password").decode()
        run.return_value = subprocess.CompletedProcess([], 0, json.dumps({"data": {"PB_ADMIN_PASSWORD": encoded}}), "")
        self.assertEqual(generator.cluster_admin_password("workshop"), "live-admin-password")
        self.assertEqual(run.call_count, 1)

    @mock.patch.dict(os.environ, {"KUBECONFIG": "/tmp/test-kubeconfig"})
    @mock.patch.object(subprocess, "run")
    def test_refuses_live_pvc_without_admin_secret(self, run):
        run.side_effect = [
            subprocess.CompletedProcess([], 1, "", "Error from server (NotFound): secret not found"),
            subprocess.CompletedProcess([], 0, "pvc/join-portal-data", ""),
        ]
        with self.assertRaisesRegex(ValueError, "refusing to mint"):
            generator.cluster_admin_password("workshop")

    @mock.patch.dict(os.environ, {"KUBECONFIG": "/tmp/test-kubeconfig"})
    @mock.patch.object(subprocess, "run")
    def test_refuses_unreachable_cluster(self, run):
        run.return_value = subprocess.CompletedProcess([], 1, "", "connection refused")
        with self.assertRaisesRegex(ValueError, "cannot read live"):
            generator.cluster_admin_password("workshop")


if __name__ == "__main__":
    unittest.main()
