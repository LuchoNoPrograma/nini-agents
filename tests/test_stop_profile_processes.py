"""Process-control safety tests using only disposable child processes."""

import importlib.util
import os
from pathlib import Path
import subprocess
import unittest
from unittest import mock


spec = importlib.util.spec_from_file_location(
    "profile_stop", Path(__file__).resolve().parents[1] / "lib/stop-profile-processes.py"
)
control = importlib.util.module_from_spec(spec)
spec.loader.exec_module(control)


@unittest.skipUnless(hasattr(os, "pidfd_open"), "Linux pidfd support required")
class SafeStopTests(unittest.TestCase):
    def setUp(self):
        self.children = []
        self.marker = f"fixture-stop-{os.getpid()}"

    def tearDown(self):
        for child in self.children:
            child.kill()
            child.wait(timeout=5)

    def child(self):
        process = subprocess.Popen(
            ["sleep", "60"], env={"PATH": os.defpath, "FIXTURE_PROFILE": self.marker}
        )
        self.children.append(process)
        return {"pid": str(process.pid), "start": control.identity(process.pid)[1].decode()}

    def snapshot(self, *rows):
        return {"markers": [f"FIXTURE_PROFILE={self.marker}"], "rows": list(rows)}

    def test_recycled_identity_refuses_entire_batch_before_first_signal(self):
        first, second = self.child(), self.child()
        second["start"] = "0"
        with self.assertRaisesRegex(RuntimeError, "identity changed"):
            control.stop(self.snapshot(first, second))
        self.assertTrue(all(child.poll() is None for child in self.children))

    def test_marker_mismatch_never_signals_the_process(self):
        snapshot = self.snapshot(self.child())
        snapshot["markers"] = ["FIXTURE_PROFILE=some-other-profile"]
        with self.assertRaisesRegex(RuntimeError, "marker changed"):
            control.stop(snapshot)
        self.assertIsNone(self.children[0].poll())

    def test_disappeared_process_does_not_prevent_stopping_the_live_snapshot(self):
        first, second = self.child(), self.child()
        self.children[0].terminate()
        self.children[0].wait(timeout=5)
        control.stop(self.snapshot(first, second))
        self.assertEqual(self.children[1].wait(timeout=5), -15)

    def test_pidfd_failure_never_falls_back_to_pid_kill(self):
        row = self.child()
        with mock.patch.object(control.os, "pidfd_open", side_effect=PermissionError):
            with self.assertRaises(PermissionError):
                control.stop(self.snapshot(row))
        self.assertIsNone(self.children[0].poll())


if __name__ == "__main__":
    unittest.main()
