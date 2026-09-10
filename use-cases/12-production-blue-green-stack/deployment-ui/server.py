from copy import deepcopy
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
MAX_ALERT_BYTES = 65536
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
TELEMETRY = {
    "prometheus": os.getenv("PROMETHEUS_HEALTH_URL", "http://prometheus:9090/-/ready"),
    "grafana": os.getenv("GRAFANA_HEALTH_URL", "http://grafana:3000/api/health"),
    "jaeger": os.getenv("JAEGER_HEALTH_URL", "http://jaeger:16686/"),
    "alertmanager": os.getenv("ALERTMANAGER_HEALTH_URL", "http://alertmanager:9093/-/ready"),
}
CLUSTER_TO_SLOT = {details["cluster"]: slot for slot, details in SLOTS.items()}
SWITCH_LOCK = threading.Lock()
METRICS_LOCK = threading.Lock()
ALERT_LOCK = threading.Lock()
OBSERVATION_LOCK = threading.Lock()
SWITCH_TOTALS = {}
LAST_SWITCH_TIMESTAMP = 0.0
ALERT_STATE = {"status": "unknown", "updated_at": None, "alerts": []}
OBSERVATION_STATE = None


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


def fetch_text(url, timeout=2):
    request = Request(url, headers={"Accept": "text/plain"})
    with urlopen(request, timeout=timeout) as response:
        return response.read().decode("utf-8", errors="replace")


def active_route(timeout=2):
    data = fetch_json(f"{ENVOY_ADMIN_URL}/config_dump?resource=dynamic_route_configs", timeout=timeout)
    for entry in data.get("configs", []):
        candidates = [entry]
        candidates.extend(entry.get("dynamic_route_configs", []))
        for candidate in candidates:
            route_config = candidate.get("route_config", {})
            if route_config.get("name") != "dynamic_route":
                continue
            for virtual_host in route_config.get("virtual_hosts", []):
                for route in virtual_host.get("routes", []):
                    slot = CLUSTER_TO_SLOT.get(route.get("route", {}).get("cluster"))
                    if slot:
                        return slot, str(candidate.get("version_info", "unknown"))
    raise ApiError(503, "Envoy has not accepted a Blue/Green route yet.")


def probe_url(url, user_agent, read_body=False, timeout=2):
    started = time.monotonic()
    request = Request(url, headers={"User-Agent": user_agent})
    try:
        with urlopen(request, timeout=timeout) as response:
            body = response.read(128).decode("utf-8", errors="replace").strip() if read_body else ""
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


def probe(slot, timeout=2):
    return probe_url(SLOTS[slot]["health_url"], "production-release-console/2", read_body=True, timeout=timeout)


def observe_release(probe_timeout=2):
    route_error = None
    try:
        active, revision = active_route(timeout=probe_timeout)
        envoy_ready = True
    except (ApiError, HTTPError, URLError, TimeoutError, OSError, ValueError, json.JSONDecodeError) as error:
        active, revision = None, None
        envoy_ready = False
        route_error = error.message if isinstance(error, ApiError) else "Envoy Admin is not reachable."

    with ThreadPoolExecutor(max_workers=2) as executor:
        futures = {slot: executor.submit(probe, slot, probe_timeout) for slot in SLOTS}
        backends = {slot: future.result() for slot, future in futures.items()}

    standby = "green" if active == "blue" else "blue" if active == "green" else None
    active_healthy = bool(active and backends[active]["healthy"])
    standby_ready = bool(standby and backends[standby]["healthy"])
    return {
        "active": active,
        "revision": revision,
        "envoy_ready": envoy_ready,
        "route_error": route_error,
        "backends": backends,
        "failover": {
            "required": bool(active and not active_healthy),
            "active_healthy": active_healthy,
            "standby": standby,
            "standby_ready": standby_ready,
        },
    }


def read_alert_state():
    with ALERT_LOCK:
        return {
            "status": ALERT_STATE["status"],
            "updated_at": ALERT_STATE["updated_at"],
            "alerts": [dict(alert) for alert in ALERT_STATE["alerts"]],
        }


def read_state():
    state = observation_snapshot()
    with ThreadPoolExecutor(max_workers=len(TELEMETRY)) as executor:
        futures = {
            name: executor.submit(probe_url, url, "production-release-console/2")
            for name, url in TELEMETRY.items()
        }
        state["telemetry"] = {name: future.result() for name, future in futures.items()}
    state["alertmanager"] = read_alert_state()
    state["observed_at"] = utc_now()
    return state


def envoy_rejected_total(timeout=2):
    try:
        stats = fetch_text(f"{ENVOY_ADMIN_URL}/stats?filter=update_rejected", timeout=timeout)
        return sum(int(line.rsplit(":", 1)[1].strip()) for line in stats.splitlines() if ":" in line)
    except (HTTPError, URLError, TimeoutError, OSError, ValueError):
        return 0

def refresh_observation():
    global OBSERVATION_STATE
    state = observe_release()
    state["rds_rejected_total"] = envoy_rejected_total()
    with OBSERVATION_LOCK:
        OBSERVATION_STATE = state
    return state


def observation_snapshot():
    with OBSERVATION_LOCK:
        return deepcopy(OBSERVATION_STATE)


def update_active_observation(target, revision):
    global OBSERVATION_STATE
    standby = "green" if target == "blue" else "blue"
    with OBSERVATION_LOCK:
        state = deepcopy(OBSERVATION_STATE)
        state["active"] = target
        state["revision"] = revision
        state["envoy_ready"] = True
        state["route_error"] = None
        state["failover"] = {
            "required": not state["backends"][target]["healthy"],
            "active_healthy": state["backends"][target]["healthy"],
            "standby": standby,
            "standby_ready": state["backends"][standby]["healthy"],
        }
        OBSERVATION_STATE = state


def observation_loop():
    while True:
        refresh_observation()
        time.sleep(1)


def prometheus_metrics():
    state = observation_snapshot()
    active = state["active"]
    lines = [
        "# HELP release_active Whether a release slot currently receives production traffic.",
        "# TYPE release_active gauge",
    ]
    for slot in SLOTS:
        lines.append(f'release_active{{slot="{slot}"}} {1 if active == slot else 0}')
    lines.extend([
        "# HELP release_backend_healthy Whether the release backend health probe succeeds.",
        "# TYPE release_backend_healthy gauge",
    ])
    for slot, backend in state["backends"].items():
        lines.append(f'release_backend_healthy{{slot="{slot}"}} {1 if backend["healthy"] else 0}')
    lines.extend([
        "# HELP release_failover_required Whether the active release is unhealthy.",
        "# TYPE release_failover_required gauge",
        f'release_failover_required {1 if state["failover"]["required"] else 0}',
        "# HELP release_standby_ready Whether the inactive release is healthy and available for failover.",
        "# TYPE release_standby_ready gauge",
        f'release_standby_ready {1 if state["failover"]["standby_ready"] else 0}',
        "# HELP release_rds_update_rejected_total Total rejected Envoy configuration updates.",
        "# TYPE release_rds_update_rejected_total counter",
        f'release_rds_update_rejected_total {state["rds_rejected_total"]}',
        "# HELP release_switch_total Traffic switch attempts by source, target, and result.",
        "# TYPE release_switch_total counter",
    ])
    with METRICS_LOCK:
        totals = dict(SWITCH_TOTALS)
        last_switch = LAST_SWITCH_TIMESTAMP
    for (source, target, result), value in sorted(totals.items()):
        lines.append(f'release_switch_total{{from_slot="{source}",to_slot="{target}",result="{result}"}} {value}')
    lines.extend([
        "# HELP release_last_switch_timestamp_seconds Unix timestamp of the last successful traffic switch.",
        "# TYPE release_last_switch_timestamp_seconds gauge",
        f"release_last_switch_timestamp_seconds {last_switch}",
        "",
    ])
    return "\n".join(lines).encode("utf-8")


def record_switch(source, target, result):
    global LAST_SWITCH_TIMESTAMP
    with METRICS_LOCK:
        key = (source, target, result)
        SWITCH_TOTALS[key] = SWITCH_TOTALS.get(key, 0) + 1
        if result == "success":
            LAST_SWITCH_TIMESTAMP = time.time()


def record_alerts(payload):
    alerts = []
    for alert in payload.get("alerts", [])[:20]:
        labels = alert.get("labels", {})
        annotations = alert.get("annotations", {})
        alerts.append({
            "status": alert.get("status", "unknown"),
            "alertname": labels.get("alertname", "UnknownAlert"),
            "severity": labels.get("severity", "unknown"),
            "slot": labels.get("slot"),
            "summary": annotations.get("summary", ""),
            "starts_at": alert.get("startsAt"),
            "ends_at": alert.get("endsAt"),
        })
    event_status = payload.get("status", "unknown")
    with ALERT_LOCK:
        current = {(alert["alertname"], alert.get("slot")): alert for alert in ALERT_STATE["alerts"]}
        for alert in alerts:
            current[(alert["alertname"], alert.get("slot"))] = alert
        ALERT_STATE["status"] = event_status
        ALERT_STATE["updated_at"] = utc_now()
        ALERT_STATE["alerts"] = list(current.values())[-20:]
    print(json.dumps({"event": "alertmanager_notification", "status": event_status, "alerts": alerts}), flush=True)


def atomic_publish(data):
    if CURRENT_ROUTE.parent != XDS_DIR:
        raise ApiError(500, "Unsafe xDS target path.")
    temporary_path = None
    try:
        with tempfile.NamedTemporaryFile(mode="wb", prefix=".routes-current-", suffix=".yaml", dir=XDS_DIR, delete=False) as temporary:
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
            record_switch(current, target, "failed")
            raise ApiError(409, f"Traffic changed since this page loaded; active deployment is {current}.")
        try:
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
        except Exception:
            record_switch(current, target, "failed")
            raise

        record_switch(current, target, "success")
        print(json.dumps({"event": "traffic_switched", "from": current, "to": target, "revision": revision, "at": utc_now()}), flush=True)
        update_active_observation(target, revision)
        return read_state()


class Handler(BaseHTTPRequestHandler):
    server_version = "ProductionReleaseConsole/2.0"

    def send_bytes(self, status, body, content_type, cache_control="no-store"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache_control)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, status, payload):
        self.send_bytes(status, json.dumps(payload, separators=(",", ":")).encode("utf-8"), "application/json; charset=utf-8")

    def read_json(self, maximum_bytes):
        content_type = self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
        if content_type != "application/json":
            raise ApiError(415, "Content-Type must be application/json.")
        content_length = int(self.headers.get("Content-Length", "0"))
        if content_length <= 0 or content_length > maximum_bytes:
            raise ApiError(413, f"Request body must be between 1 and {maximum_bytes} bytes.")
        payload = json.loads(self.rfile.read(content_length))
        if not isinstance(payload, dict):
            raise ApiError(400, "Request body must be a JSON object.")
        return payload

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
            elif path == "/metrics":
                self.send_bytes(200, prometheus_metrics(), "text/plain; version=0.0.4; charset=utf-8")
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
        try:
            if path == "/api/alerts":
                record_alerts(self.read_json(MAX_ALERT_BYTES))
                self.send_json(202, {"status": "accepted"})
                return
            if path != "/api/switch":
                self.send_json(404, {"error": "Not found."})
                return
            payload = self.read_json(MAX_REQUEST_BYTES)
            self.send_json(200, switch_route(payload.get("target"), payload.get("expected_active")))
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
            print(f"unexpected request failure: {error}", flush=True)
            self.send_json(500, {"error": "Request failed unexpectedly."})

    def log_message(self, fmt, *args):
        print(f"{self.address_string()} {fmt % args}", flush=True)


class Server(ThreadingHTTPServer):
    daemon_threads = True


if __name__ == "__main__":
    for slot, details in SLOTS.items():
        if details["fixture"].parent != XDS_DIR:
            raise SystemExit(f"unsafe route fixture path for {slot}")
    refresh_observation()
    threading.Thread(target=observation_loop, name="release-observer", daemon=True).start()
    print(f"Production Release Console listening on 0.0.0.0:{PORT}", flush=True)
    Server(("0.0.0.0", PORT), Handler).serve_forever()
