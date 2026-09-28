"""Tiny local HTTP endpoint so the noVNC landing page can force a fresh
BMC login + applet relaunch before connecting. Killing appletviewer is
enough -- entrypoint.sh's loop treats that as a normal exit and cycles
back to a fresh login_and_launch.py run + a new appletviewer process.
Xvfb/fluxbox/x11vnc/websockify are untouched, so this only fixes a
stale BMC session or a wedged applet, not a wedged X11 stack.
"""
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 6079


class Handler(BaseHTTPRequestHandler):
    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_POST(self):
        if self.path != "/reset":
            self.send_response(404)
            self._cors()
            self.end_headers()
            return
        subprocess.run(["pkill", "-f", "appletviewer"])
        self.send_response(200)
        self._cors()
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, fmt, *args):
        print(f"[reset_server] {fmt % args}", flush=True)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
