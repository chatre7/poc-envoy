import json
import os
import random
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

VERSION = os.getenv("VERSION", "VERSION-1")
APP_PORT = int(os.getenv("APP_PORT", "8080"))
CONTROL_PORT = int(os.getenv("CONTROL_PORT", "9000"))

# Fraction of application requests answered with HTTP 500. The control port is
# only exposed on the Compose network, so Envoy never routes client traffic to it.
fault = {"error_rate": float(os.getenv("ERROR_RATE", "0"))}
fault_lock = threading.Lock()


class Server(ThreadingHTTPServer):
    daemon_threads = True


class AppHandler(BaseHTTPRequestHandler):
    server_version = "CanaryBackend/1.0"

    def send_text(self, status, text):
        body = f"{text}\n".encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Backend-Version", VERSION)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        # The liveness probe stays green during an injected fault on purpose:
        # the lab shows that only request metrics catch a bad release.
        if urlsplit(self.path).path == "/healthz":
            self.send_text(200, "ok")
            return
        with fault_lock:
            error_rate = fault["error_rate"]
        if random.random() < error_rate:
            self.send_text(500, f"{VERSION} injected failure")
            return
        self.send_text(200, VERSION)

    def log_message(self, fmt, *args):
        pass


class ControlHandler(BaseHTTPRequestHandler):
    server_version = "CanaryBackendControl/1.0"

    def send_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        with fault_lock:
            self.send_json(200, {"version": VERSION, **fault})

    def do_POST(self):
        parts = urlsplit(self.path)
        if parts.path != "/fault":
            self.send_json(404, {"error": "Not found."})
            return
        try:
            rate = float(parse_qs(parts.query).get("rate", ["0"])[0])
        except ValueError:
            self.send_json(400, {"error": "rate must be a number."})
            return
        if not 0 <= rate <= 1:
            self.send_json(400, {"error": "rate must be between 0 and 1."})
            return
        with fault_lock:
            fault["error_rate"] = rate
        print(json.dumps({"event": "fault_updated", "version": VERSION, "error_rate": rate}), flush=True)
        self.send_json(200, {"version": VERSION, "error_rate": rate})

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    control = Server(("0.0.0.0", CONTROL_PORT), ControlHandler)
    threading.Thread(target=control.serve_forever, daemon=True).start()
    print(f"{VERSION} listening on :{APP_PORT}, fault control on :{CONTROL_PORT}", flush=True)
    Server(("0.0.0.0", APP_PORT), AppHandler).serve_forever()
