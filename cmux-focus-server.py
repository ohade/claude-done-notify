#!/usr/bin/env python3
"""Tiny HTTP server that focuses a cmux workspace/surface when called.

Listens on localhost:17382 (configurable via CMUX_FOCUS_PORT env var).
Endpoints:
  GET /focus?token=<t>&workspace=<ws>&surface=<sf>  — focus cmux surface
  GET /health                                       — health check

Used by claude-done-notify to provide clickable links in Slack messages.
"""

import http.server
import os
import re
import secrets
import stat
import subprocess
import sys
from pathlib import Path
from urllib.parse import parse_qs, urlparse

PORT = int(os.environ.get("CMUX_FOCUS_PORT", "17382"))
TOKEN_FILE = Path.home() / ".cmux-focus-token"
ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,128}$")
CMUX_PATHS = (
    os.environ.get("CMUX_BUNDLED_CLI_PATH", ""),
    "/opt/homebrew/bin/cmux",
    "/usr/local/bin/cmux",
    "/Applications/cmux.app/Contents/Resources/bin/cmux",
)


def read_token():
    """Read the focus token, refusing to use it if file permissions are too open.

    Defense-in-depth against the audit finding that a chmod 644 (whether from
    operator error, dotfile sync, or backup restore) would silently expose the
    token to other local users. We refuse rather than auto-fix, so the operator
    sees the failure in cmux-focus.err.log.
    """
    try:
        st = TOKEN_FILE.stat()
    except FileNotFoundError:
        return ""
    except OSError as exc:
        sys.stderr.write(f"WARN: cannot stat {TOKEN_FILE}: {exc}\n")
        sys.stderr.flush()
        return ""
    if st.st_uid != os.getuid():
        sys.stderr.write(
            f"WARN: refusing to read {TOKEN_FILE}: not owned by uid {os.getuid()} "
            f"(owner uid={st.st_uid})\n"
        )
        sys.stderr.flush()
        return ""
    perm_bits = stat.S_IMODE(st.st_mode)
    if perm_bits & 0o077:
        sys.stderr.write(
            f"WARN: refusing to read {TOKEN_FILE}: mode {oct(perm_bits)} too "
            f"permissive (must be 0o600). Run `chmod 600 {TOKEN_FILE}`.\n"
        )
        sys.stderr.flush()
        return ""
    try:
        return TOKEN_FILE.read_text(encoding="utf-8").strip()
    except OSError as exc:
        sys.stderr.write(f"WARN: read {TOKEN_FILE} failed: {exc}\n")
        sys.stderr.flush()
        return ""


def resolve_cmux_cli():
    for path in CMUX_PATHS:
        if path and os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return None


def stderr_tail(result):
    text = (result.stderr or result.stdout or "").strip()
    return text[-500:] if text else f"exit {result.returncode}"


def run_cmux(cmux, args):
    result = subprocess.run(
        [cmux, *args],
        timeout=5,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(stderr_tail(result))


def focus_cmux(workspace_id, surface_id):
    cmux = resolve_cmux_cli()
    if not cmux:
        raise FileNotFoundError("cmux CLI not found")

    run_cmux(cmux, ["select-workspace", "--workspace", workspace_id])
    run_cmux(cmux, ["focus-panel", "--workspace", workspace_id, "--panel", surface_id])


class FocusHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)

        if parsed.path == "/health":
            self._respond(200, "ok")
            return

        if parsed.path == "/focus":
            params = parse_qs(parsed.query, keep_blank_values=True)
            token = params.get("token", [""])[0]
            workspace_id = params.get("workspace", [""])[0]
            surface_id = params.get("surface", [""])[0]

            if not token:
                self._respond(403, "missing token")
                return
            if not workspace_id or not surface_id:
                self._respond(400, "need ?workspace=&surface=")
                return

            expected_token = read_token()
            if not expected_token or not secrets.compare_digest(token, expected_token):
                self._respond(403, "invalid token")
                return

            if not ID_RE.fullmatch(workspace_id) or not ID_RE.fullmatch(surface_id):
                self._respond(400, "invalid id format")
                return

            try:
                focus_cmux(workspace_id, surface_id)
                self._respond(200, self._redirect_html())
                return
            except FileNotFoundError:
                self._respond(500, "cmux CLI not found")
                return
            except Exception as e:
                self._respond(500, f"cmux focus failed: {e}")
                return

        self._respond(404, "not found")

    def _respond(self, code, body):
        content_type = "text/html" if body.startswith("<!") else "text/plain"
        body_bytes = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body_bytes)))
        self.end_headers()
        self.wfile.write(body_bytes)

    def _redirect_html(self):
        return (
            "<!DOCTYPE html><html><body>"
            "<p>Focused. You can close this tab.</p>"
            "<script>window.close()</script>"
            "</body></html>"
        )

    def log_message(self, fmt, *args):
        pass


def main():
    server = http.server.HTTPServer(("127.0.0.1", PORT), FocusHandler)
    print(f"cmux-focus-server listening on http://127.0.0.1:{PORT}")
    sys.stdout.flush()
    server.serve_forever()


if __name__ == "__main__":
    main()
