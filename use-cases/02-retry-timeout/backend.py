import os
import threading
import time
from collections import defaultdict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    counters = defaultdict(int)
    lock = threading.Lock()

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        with self.lock:
            self.counters[path] += 1
            attempt = self.counters[path]

        status = 200
        body = "OK"
        if path == "/fail-once" and attempt % 2 == 1:
            status, body = 503, "fail once"
        elif path == "/slow-once" and attempt % 2 == 1:
            time.sleep(3)
            body = "late first attempt"
        elif path == "/always-slow":
            time.sleep(6)
            body = "too late"
        elif path == "/health":
            body = "healthy"

        try:
            self.send_response(status)
            self.send_header("Content-Type", "text/plain")
            self.send_header("X-Backend-Attempt", str(attempt))
            self.end_headers()
            self.wfile.write(body.encode())
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, fmt, *args):
        print(f"{self.address_string()} {fmt % args}", flush=True)


ThreadingHTTPServer(("0.0.0.0", int(os.getenv("PORT", "8080"))), Handler).serve_forever()
