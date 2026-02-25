#!/usr/bin/env python3
"""Tiny HTTP server that focuses a WezTerm pane/tab when called.

Listens on localhost:17380 (configurable via WEZTERM_FOCUS_PORT env var).
Endpoints:
  GET /focus?pane=<pane_id>   — activate pane + bring WezTerm to front
  GET /health                 — health check

Used by claude-done-notify to provide clickable links in Slack messages.
"""

import http.server
import subprocess
import sys
import os
from urllib.parse import urlparse, parse_qs

PORT = int(os.environ.get("WEZTERM_FOCUS_PORT", "17380"))
WEZTERM = "/opt/homebrew/bin/wezterm"


class FocusHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)

        if parsed.path == "/health":
            self._respond(200, "ok")
            return

        if parsed.path == "/focus":
            params = parse_qs(parsed.query)
            pane_id = params.get("pane", [None])[0]
            tab_id = params.get("tab", [None])[0]

            if not pane_id and not tab_id:
                self._respond(400, "need ?pane=N or ?tab=N")
                return

            try:
                # Activate the pane (which also activates its tab)
                if pane_id:
                    subprocess.run(
                        [WEZTERM, "cli", "activate-pane", "--pane-id", pane_id],
                        timeout=5, check=True,
                    )
                elif tab_id:
                    subprocess.run(
                        [WEZTERM, "cli", "activate-tab", "--tab-id", tab_id],
                        timeout=5, check=True,
                    )

                # Bring WezTerm to front
                subprocess.run(
                    ["osascript", "-e", 'tell application "WezTerm" to activate'],
                    timeout=5,
                )

                self._respond(200, self._redirect_html())
                return
            except Exception as e:
                self._respond(500, f"error: {e}")
                return

        self._respond(404, "not found")

    def _respond(self, code, body):
        content_type = "text/html" if body.startswith("<!") else "text/plain"
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body.encode())

    def _redirect_html(self):
        return (
            "<!DOCTYPE html><html><body>"
            "<p>Focused. You can close this tab.</p>"
            "<script>window.close()</script>"
            "</body></html>"
        )

    def log_message(self, fmt, *args):
        # Suppress default access logs
        pass


def main():
    server = http.server.HTTPServer(("127.0.0.1", PORT), FocusHandler)
    print(f"wezterm-focus-server listening on http://127.0.0.1:{PORT}")
    sys.stdout.flush()
    server.serve_forever()


if __name__ == "__main__":
    main()
