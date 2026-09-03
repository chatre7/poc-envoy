import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODE = os.getenv("BACKEND_MODE", "good")


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/health"):
            status, body = 200, b"HEALTHY"
        elif MODE == "bad":
            status, body = 503, b"BAD"
        else:
            status, body = 200, b"GOOD"
        self.send_response(status)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        print(f"{MODE}: {fmt % args}", flush=True)


ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
