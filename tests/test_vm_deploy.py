import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
ACTION = ROOT / ".github/actions/deploy-runner-gcp-vm"
spec = importlib.util.spec_from_file_location("wait_for_startup", ACTION / "wait_for_startup.py")
waiter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(waiter)


class StartupTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.temp = Path(self.directory.name)
        binary_dir = self.temp / "bin"
        binary_dir.mkdir()
        fake = binary_dir / "fake_vm.py"
        fake.write_text((ROOT / "tests/fake_vm.py").read_text())
        fake.chmod(0o755)
        for name in ("curl", "docker", "systemctl", "sleep"):
            (binary_dir / name).symlink_to(fake)
        self.state_file = self.temp / "state.json"
        self.reset_state()
        self.env = {
            **os.environ,
            "PATH": f"{binary_dir}:{os.environ['PATH']}",
            "VM_STATE": str(self.state_file),
            "POLYCORE_STARTUP_LOG": str(self.temp / "startup.log"),
        }

    def reset_state(self):
        self.state_file.write_text(json.dumps({
            "images": ["sha256:old", "sha256:unused-1", "sha256:unused-2"],
            "container": "sha256:old", "running": False,
            "checks_elapsed": 0, "events": [],
        }))

    def run_startup(self, scenario="success"):
        return subprocess.run(
            ["bash", str(ACTION / "vm-startup.sh")],
            env={**self.env, "SCENARIO": scenario}, capture_output=True, text=True, timeout=30,
        )

    def test_full_disk_recovers_and_only_current_image_remains(self):
        result = self.run_startup()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        state = json.loads(self.state_file.read_text())
        self.assertEqual(state["images"], ["sha256:new"])
        self.assertEqual(state["container"], "sha256:new")
        self.assertEqual(state["checks_elapsed"], 10)
        events = state["events"]
        self.assertLess(events.index("image prune"), events.index("pull"))
        self.assertGreater(len(events) - 1 - events[::-1].index("image prune"), events.index("run"))
        self.assertIn("=== startup complete; deployment=test-deployment ===", result.stdout)
        self.assertNotIn("test-only-secret", result.stdout + result.stderr)

    def test_failed_pull_preserves_old_runner_and_reports_failure(self):
        result = self.run_startup("pull-failure")
        state = json.loads(self.state_file.read_text())
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state["container"], "sha256:old")
        self.assertTrue(state["running"])
        self.assertNotIn("rm", state["events"])
        self.assertIn("=== startup failed; deployment=test-deployment; exit=1 ===", result.stdout)
        self.assertNotIn("startup complete", result.stdout)

    def test_no_success_for_failed_or_unstable_replacement(self):
        for scenario in ("run-failure", "wrong-image", "exited", "restarting", "restarted", "late-crash", "cleanup-failure"):
            with self.subTest(scenario=scenario):
                self.reset_state()
                result = self.run_startup(scenario)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("startup failed; deployment=test-deployment;", result.stdout)
                self.assertNotIn("startup complete", result.stdout)

    def test_secret_failure_is_reported_before_touching_container(self):
        result = self.run_startup("secret-failure")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("startup failed; deployment=test-deployment;", result.stdout)
        self.assertNotIn("rm", json.loads(self.state_file.read_text())["events"])


class WaitTests(unittest.TestCase):
    def check_wait(self, responses, timeout=10):
        clock = [0]

        def advance(seconds):
            clock[0] += seconds

        def serial_output(*args, **kwargs):
            self.assertLessEqual(kwargs["timeout"], timeout - clock[0])
            response = responses.pop(0) if len(responses) > 1 else responses[0]
            if isinstance(response, Exception):
                raise response
            return subprocess.CompletedProcess(args[0], 0, json.dumps({"contents": response}))

        with patch.object(waiter.time, "monotonic", side_effect=lambda: clock[0]), \
                patch.object(waiter.time, "sleep", side_effect=advance), \
                patch.object(waiter.sys, "stdout", new_callable=io.StringIO), \
                patch.object(waiter.sys, "stderr", new_callable=io.StringIO), \
                patch.object(waiter.subprocess, "run", side_effect=serial_output) as run:
            status = waiter.wait_for_startup(
                project="acme-prod", zone="europe-west1-b", vm="polycore-runner",
                deployment_id="new-deployment", timeout=timeout,
            )
        return status, run.call_count

    def test_ignores_prior_success_and_waits_for_current_deployment(self):
        old = "=== startup complete; deployment=old-deployment ==="
        current = "=== startup complete; deployment=new-deployment ==="
        self.assertEqual(self.check_wait([old, old + "\n" + current]), (0, 2))

    def test_prior_success_cannot_turn_timeout_green(self):
        self.assertEqual(self.check_wait(["=== startup complete; deployment=old-deployment ==="])[0], 1)

    def test_legacy_success_cannot_turn_timeout_green(self):
        self.assertEqual(self.check_wait(["=== startup complete; runner container launched ==="])[0], 1)

    def test_current_startup_failure_fails_immediately(self):
        self.assertEqual(self.check_wait(["=== startup failed; deployment=new-deployment; exit=1 ==="]), (1, 1))

    def test_stale_failure_does_not_fail_current_success(self):
        log = "=== startup failed; deployment=old-deployment; exit=1 ===\n"
        log += "=== startup complete; deployment=new-deployment ==="
        self.assertEqual(self.check_wait([log]), (0, 1))

    def test_serial_errors_never_pass(self):
        for error in (subprocess.CalledProcessError(1, "gcloud"), subprocess.TimeoutExpired("gcloud", 1), None):
            with self.subTest(error=error):
                self.assertEqual(self.check_wait([error])[0], 1)

    def test_transient_serial_failure_recovers(self):
        responses = [subprocess.CalledProcessError(1, "gcloud"), "=== startup complete; deployment=new-deployment ==="]
        self.assertEqual(self.check_wait(responses), (0, 2))


if __name__ == "__main__":
    unittest.main()
