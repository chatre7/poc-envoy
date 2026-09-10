import json
import os
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen

APP_DIR = Path(__file__).resolve().parent
XDS_DIR = Path(os.getenv("XDS_DIR", "/etc/envoy/xds")).resolve()
CURRENT_ROUTE = XDS_DIR / "routes-current.yaml"
ENVOY_ADMIN_URL = os.getenv("ENVOY_ADMIN_URL", "http://envoy:9901").rstrip("/")
PORT = int(os.getenv("PORT", "8000"))
MAX_REQUEST_BYTES = 4096
SWITCH_TIMEOUT_SECONDS = 12

SLOTS = {
    "blue": {
        "cluster": "backend_v1",
        "fixture": XDS_DIR / "routes-v1.yaml",
        "health_url": os.getenv("BLUE_HEALTH_URL", "http://backend-v1:8080/"),
        "version": "VERSION-1",
    },
    "green": {
        "cluster": "backend_v2",
        "fixture": XDS_DIR / "routes-v2.yaml",
        "health_url": os.getenv("GREEN_HEALTH_URL", "http://backend-v2:8080/"),
        "version": "VERSION-2",
    },
}
CLUSTER_TO_SLOT = {details["cluster"]: slot for slot, details in SLOTS.items()}
SWITCH_LOCK = threading.Lock()


class ApiError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


def utc_now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def fetch_json(url, timeout=2):
    request = Request(url, headers={"Accept": "application/json"})
    with urlopen(request, timeout=timeout) as response:
        return json.load(response)


def active_route():
    data = fetch_json(f"{ENVOY_ADMIN_URL}/config_dump?resource=dynamic_route_configs")
    for entry in data.get("configs", []):
        candidates = [entry]
        candidates.extend(entry.get("dynamic_route_configs", []))
        for candidate in candidates:
            route_config = candidate.get("route_config", {})
            if route_config.get("name") != "dynamic_route":
                continue
            for virtual_host in route_config.get("virtual_hosts", []):
                for route in virtual_host.get("routes", []):
                    cluster = route.get("route", {}).get("cluster")
                    slot = CLUSTER_TO_SLOT.get(cluster)
                    if slot:
                        return slot, str(candidate.get("version_info", "unknown"))
    raise ApiError(503, "Envoy has not accepted a Blue/Green route yet.")


def probe(slot):
    details = SLOTS[slot]
    started = time.monotonic()
    request = Request(details["health_url"], headers={"User-Agent": "release-console/1"})
    try:
        with urlopen(request, timeout=2) as response:
            body = response.read(128).decode("utf-8", errors="replace").strip()
            status_code = response.status
        return {
            "healthy": 200 <= status_code < 300,
            "status_code": status_code,
            "latency_ms": round((time.monotonic() - started) * 1000),
            "response": body,
        }
    except HTTPError as error:
        return {
            "healthy": False,
            "status_code": error.code,
            "latency_ms": round((time.monotonic() - started) * 1000),
            "response": "HTTP error",
        }
    except (URLError, TimeoutError, OSError) as error:
        return {
            "healthy": False,
            "status_code": None,
            "latency_ms": round((time.monotonic() - started) * 1000),
            "response": str(error.reason if isinstance(error, URLError) else error),
        }


def read_state():
    route_error = None
    try:
        active, revision = active_route()
        envoy_ready = True
    except (ApiError, HTTPError, URLError, TimeoutError, OSError, ValueError, json.JSONDecodeError) as error:
        active, revision = None, None
        envoy_ready = False
        route_error = error.message if isinstance(error, ApiError) else "Envoy Admin is not reachable."

    with ThreadPoolExecutor(max_workers=2) as executor:
        futures = {slot: executor.submit(probe, slot) for slot in SLOTS}
        backends = {slot: future.result() for slot, future in futures.items()}

    return {
        "active": active,
        "revision": revision,
        "envoy_ready": envoy_ready,
        "route_error": route_error,
        "backends": backends,
        "observed_at": utc_now(),
    }


def atomic_publish(data):
    if CURRENT_ROUTE.parent != XDS_DIR:
        raise ApiError(500, "Unsafe xDS target path.")
    temporary_path = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb", prefix=".routes-current-", suffix=".yaml", dir=XDS_DIR, delete=False
        ) as temporary:
            temporary_path = Path(temporary.name)
            temporary.write(data)
            temporary.flush()
            os.fchmod(temporary.fileno(), 0o644)
            os.fsync(temporary.fileno())
        os.replace(temporary_path, CURRENT_ROUTE)
    finally:
        if temporary_path and temporary_path.exists():
            temporary_path.unlink()


def wait_for_active(target):
    deadline = time.monotonic() + SWITCH_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        try:
            active, revision = active_route()
            if active == target:
                return revision
        except (ApiError, HTTPError, URLError, TimeoutError, OSError, ValueError, json.JSONDecodeError):
            pass
        time.sleep(0.25)
    return None


def switch_route(target, expected_active):
    if target not in SLOTS or expected_active not in SLOTS:
        raise ApiError(400, "target and expected_active must be blue or green.")
    if target == expected_active:
        raise ApiError(400, "Target must differ from the active deployment.")

    with SWITCH_LOCK:
        current, _ = active_route()
        if current != expected_active:
            raise ApiError(409, f"Traffic changed since this page loaded; active deployment is {current}.")

        candidate = probe(target)
        if not candidate["healthy"]:
            raise ApiError(409, f"{target.title()} is unhealthy; traffic was not changed.")

        fixture = SLOTS[target]["fixture"]
        if fixture.parent != XDS_DIR or not fixture.is_file():
            raise ApiError(500, f"Route fixture for {target} is unavailable.")

        previous = CURRENT_ROUTE.read_bytes()
        atomic_publish(fixture.read_bytes())
        revision = wait_for_active(target)
        if revision is None:
            atomic_publish(previous)
            wait_for_active(current)
            raise ApiError(502, "Envoy did not accept the route update; the previous route was restored.")

        print(
            json.dumps(
                {
                    "event": "traffic_switched",
                    "from": current,
                    "to": target,
                    "revision": revision,
                    "at": utc_now(),
                }
            ),
            flush=True,
        )
        return read_state()


class Handler(BaseHTTPRequestHandler):
    server_version = "ReleaseConsole/1.0"

    def send_bytes(self, status, body, content_type, cache_control="no-store"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache_control)
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, status, payload):
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_bytes(status, body, "application/json; charset=utf-8")

    def serve_asset(self, filename, content_type):
        path = APP_DIR / filename
        if path.parent != APP_DIR or not path.is_file():
            self.send_json(404, {"error": "Not found."})
            return
        cache_control = "no-cache" if filename == "index.html" else "public, max-age=300"
        self.send_bytes(200, path.read_bytes(), content_type, cache_control)

    def do_GET(self):
        path = urlsplit(self.path).path
        try:
            if path in ("/", "/index.html"):
                self.serve_asset("index.html", "text/html; charset=utf-8")
            elif path == "/styles.css":
                self.serve_asset("styles.css", "text/css; charset=utf-8")
            elif path == "/app.js":
                self.serve_asset("app.js", "text/javascript; charset=utf-8")
            elif path == "/api/state":
                self.send_json(200, read_state())
            elif path == "/health":
                self.send_json(200, {"status": "ready"})
            else:
                self.send_json(404, {"error": "Not found."})
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as error:
            print(f"state request failed: {error}", flush=True)
            self.send_json(503, {"error": "Deployment state is temporarily unavailable."})

    def do_POST(self):
        path = urlsplit(self.path).path
        if path != "/api/switch":
            self.send_json(404, {"error": "Not found."})
            return
        try:
            content_type = self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
            if content_type != "application/json":
                raise ApiError(415, "Content-Type must be application/json.")
            content_length = int(self.headers.get("Content-Length", "0"))
            if content_length <= 0 or content_length > MAX_REQUEST_BYTES:
                raise ApiError(413, "Request body must be between 1 and 4096 bytes.")
            payload = json.loads(self.rfile.read(content_length))
            if not isinstance(payload, dict):
                raise ApiError(400, "Request body must be a JSON object.")
            state = switch_route(payload.get("target"), payload.get("expected_active"))
            self.send_json(200, state)
        except ApiError as error:
            self.send_json(error.status, {"error": error.message})
        except (ValueError, json.JSONDecodeError):
            self.send_json(400, {"error": "Request body contains invalid JSON."})
        except (HTTPError, URLError, TimeoutError, OSError) as error:
            print(f"switch failed: {error}", flush=True)
            self.send_json(503, {"error": "Envoy is unavailable; traffic was not changed."})
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as error:
            print(f"unexpected switch failure: {error}", flush=True)
            self.send_json(500, {"error": "Traffic change failed unexpectedly."})

    def log_message(self, fmt, *args):
        print(f"{self.address_string()} {fmt % args}", flush=True)


class Server(ThreadingHTTPServer):
    daemon_threads = True


if __name__ == "__main__":
    for slot, details in SLOTS.items():
        if details["fixture"].parent != XDS_DIR:
            raise SystemExit(f"unsafe route fixture path for {slot}")
    print(f"Release Console listening on 0.0.0.0:{PORT}", flush=True)
    Server(("0.0.0.0", PORT), Handler).serve_forever()
