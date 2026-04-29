#!/usr/bin/env python3
"""Tiny HTTP server that focuses a Ghostty terminal tab when called.

Listens on localhost:17381 (configurable via GHOSTTY_FOCUS_PORT env var).
Endpoints:
  GET /focus?pane=<terminal_id>  — select tab containing terminal + bring Ghostty to front
  GET /health                    — health check

Used by claude-done-notify to provide clickable links in Slack messages.
"""

import http.server
import subprocess
import sys
import os
from urllib.parse import urlparse, parse_qs

PORT = int(os.environ.get("GHOSTTY_FOCUS_PORT", "17381"))


def focus_ghostty(terminal_id):
    script = f'''
        tell application "Ghostty"
            repeat with w in every window
                set tabList to every tab of w
                repeat with t in tabList
                    repeat with trm in every terminal of t
                        if id of trm is "{terminal_id}" then
                            tell w to select tab t
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
            return "not_found"
        end tell
    '''
    result = subprocess.run(
        ["osascript", "-e", script],
        timeout=5, capture_output=True, text=True,
    )
    if result.stdout.strip() == "not_found":
        raise RuntimeError(f"terminal {terminal_id} not found in any Ghostty tab")


class FocusHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)

        if parsed.path == "/health":
            self._respond(200, "ok")
            return

        if parsed.path == "/focus":
            params = parse_qs(parsed.query)
            pane_id = params.get("pane", [None])[0]

            if not pane_id:
                self._respond(400, "need ?pane=<terminal_id>")
                return

            try:
                focus_ghostty(pane_id)
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
        pass


def main():
    server = http.server.HTTPServer(("127.0.0.1", PORT), FocusHandler)
    print(f"ghostty-focus-server listening on http://127.0.0.1:{PORT}")
    sys.stdout.flush()
    server.serve_forever()


if __name__ == "__main__":
    main()
