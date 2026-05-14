#!/usr/bin/env python3
"""Tests for cmux-focus-server.py.

Covers the new permission-verification logic in read_token() that addresses
the CC-95 audit finding: the server must refuse to read a token file with
overly-permissive mode (>= 0o077 in the world/group bits) instead of silently
trusting it.

Run: python3 tests/test_focus_server.py
"""

import importlib.util
import os
import stat
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path

REPO_DIR = Path(__file__).resolve().parent.parent
SERVER_PATH = REPO_DIR / "cmux-focus-server.py"


def _load_server_module():
    """Load cmux-focus-server.py as a module without executing main()."""
    spec = importlib.util.spec_from_file_location("focus_server", SERVER_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class ReadTokenPermissionTests(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix="cdn-token-test-")
        self.token_path = Path(self.tmpdir) / "token"
        self.mod = _load_server_module()
        self._orig_token = self.mod.TOKEN_FILE
        self.mod.TOKEN_FILE = self.token_path
        self._stderr_buf = []
        self._orig_stderr_write = sys.stderr.write
        sys.stderr.write = lambda s: self._stderr_buf.append(s)

    def tearDown(self):
        self.mod.TOKEN_FILE = self._orig_token
        sys.stderr.write = self._orig_stderr_write
        if self.token_path.exists():
            self.token_path.unlink()
        os.rmdir(self.tmpdir)

    def _stderr(self):
        return "".join(self._stderr_buf)

    def test_missing_file_returns_empty_silently(self):
        # No file → empty token, no warning (expected pre-install state).
        self.assertEqual(self.mod.read_token(), "")
        self.assertEqual(self._stderr(), "")

    def test_mode_0o600_returns_token(self):
        self.token_path.write_text("hexvalue\n")
        os.chmod(self.token_path, 0o600)
        self.assertEqual(self.mod.read_token(), "hexvalue")

    def test_mode_0o644_refuses_and_warns(self):
        # Group/world readable → must refuse, log warning.
        self.token_path.write_text("hexvalue\n")
        os.chmod(self.token_path, 0o644)
        self.assertEqual(self.mod.read_token(), "")
        self.assertIn("too permissive", self._stderr())
        self.assertIn("0o644", self._stderr())

    def test_mode_0o604_refuses(self):
        # World-readable but not group → still refused.
        self.token_path.write_text("hexvalue\n")
        os.chmod(self.token_path, 0o604)
        self.assertEqual(self.mod.read_token(), "")
        self.assertIn("too permissive", self._stderr())

    def test_mode_0o660_refuses(self):
        # Group-readable but not world → still refused (defense in depth).
        self.token_path.write_text("hexvalue\n")
        os.chmod(self.token_path, 0o660)
        self.assertEqual(self.mod.read_token(), "")
        self.assertIn("too permissive", self._stderr())

    def test_token_strips_trailing_newline(self):
        self.token_path.write_text("hexvalue\n")
        os.chmod(self.token_path, 0o600)
        self.assertEqual(self.mod.read_token(), "hexvalue")


class IDRegexTests(unittest.TestCase):
    """Sanity checks on the workspace/surface ID regex used by /focus."""

    def setUp(self):
        self.mod = _load_server_module()

    def test_accepts_alnum_underscore_dash_and_cmux_refs(self):
        for ok in (
            "workspace-1",
            "surface_77",
            "ABC123",
            "workspace:10",
            "surface:34",
            "a",
            "x" * 128,
        ):
            self.assertIsNotNone(self.mod.ID_RE.fullmatch(ok), ok)

    def test_rejects_path_separators_and_injection(self):
        for bad in ("../etc", "ws/sub", "ws\x00", "ws;ls", "x" * 129, "", "ws.dot"):
            self.assertIsNone(self.mod.ID_RE.fullmatch(bad), bad)


class FocusCmuxTests(unittest.TestCase):
    def setUp(self):
        self.mod = _load_server_module()

    def test_focus_cmux_selects_panel_then_activates_app(self):
        calls = []

        def fake_run(argv, **kwargs):
            calls.append(argv)
            return subprocess_result(returncode=0, stdout="OK", stderr="")

        with mock.patch.object(self.mod, "resolve_cmux_cli", return_value="/bin/cmux"):
            with mock.patch.object(self.mod.subprocess, "run", side_effect=fake_run):
                self.mod.focus_cmux("workspace-1", "surface-2")

        self.assertEqual(
            calls,
            [
                ["/bin/cmux", "select-workspace", "--workspace", "workspace-1"],
                [
                    "/bin/cmux",
                    "focus-panel",
                    "--workspace",
                    "workspace-1",
                    "--panel",
                    "surface-2",
                ],
                [
                    "osascript",
                    "-e",
                    'tell application id "com.cmuxterm.app" to activate',
                ],
            ],
        )


def subprocess_result(returncode=0, stdout="", stderr=""):
    return type(
        "CompletedProcess",
        (),
        {"returncode": returncode, "stdout": stdout, "stderr": stderr},
    )()


if __name__ == "__main__":
    unittest.main()
