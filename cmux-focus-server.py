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
    try:
        return TOKEN_FILE.read_text(encoding="utf-8").strip()
    except OSError:
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
