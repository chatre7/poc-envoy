import json
import os
import tempfile
import threading
import time
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlsplit
from urllib.request import Request, urlopen

APP_DIR = Path(__file__).resolve().parent
XDS_DIR = Path(os.getenv("XDS_DIR", "/etc/envoy/xds")).resolve()
CURRENT_ROUTE = XDS_DIR / "routes-current.yaml"
ENVOY_ADMIN_URL = os.getenv("ENVOY_ADMIN_URL", "http://envoy:9901").rstrip("/")
PORT = int(os.getenv("PORT", "8000"))
MAX_REQUEST_BYTES = 4096
PUBLISH_TIMEOUT_SECONDS = 12

STEPS = sorted({int(step) for step in os.getenv("CANARY_STEPS", "0,10,25,50,100").split(",")})
MAX_ERROR_RATE = float(os.getenv("MAX_ERROR_RATE", "0.05"))
MIN_SAMPLES = int(os.getenv("MIN_SAMPLES", "20"))
ANALYSIS_INTERVAL_SECONDS = float(os.getenv("ANALYSIS_INTERVAL_SECONDS", "2"))

STABLE_CLUSTER = "backend_stable"
CANARY_CLUSTER = "backend_canary"
RELEASES = {
    "stable": {
        "cluster": STABLE_CLUSTER,
        "health_url": os.getenv("STABLE_HEALTH_URL", "http://backend-stable:8080/healthz"),
        "version": "VERSION-1",
    },
    "canary": {
        "cluster": CANARY_CLUSTER,
        "health_url": os.getenv("CANARY_HEALTH_URL", "http://backend-canary:8080/healthz"),
        "version": "VERSION-2",
    },
}
STATS_FILTER = r"^cluster\.backend_(stable|canary)\.upstream_rq_(completed|5xx)$"

# One lock serialises every RDS publication, whether an operator asked for it
# or the analysis loop decided to roll back.
PUBLISH_LOCK = threading.Lock()
rollout = {
    "status": "idle",
    "reason": None,
    "baseline": None,
    "step_started_at": None,
    "revision_counter": 0,
}
events = deque(maxlen=25)


class ApiError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


def utc_now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def record(kind, message, **details):
    event = {"at": utc_now(), "kind": kind, "message": message, **details}
    events.appendleft(event)
    print(json.dumps({"event": kind, **event}), flush=True)


def fetch_json(url, timeout=2):
    request = Request(url, headers={"Accept": "application/json"})
    with urlopen(request, timeout=timeout) as response:
        return json.load(response)


def accepted_route():
    """Return (canary_weight, revision) from the route Envoy actually accepted."""
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
                    clusters = route.get("route", {}).get("weighted_clusters", {}).get("clusters", [])
                    weights = {cluster.get("name"): int(cluster.get("weight", 0)) for cluster in clusters}
                    if STABLE_CLUSTER in weights and CANARY_CLUSTER in weights:
                        total = weights[STABLE_CLUSTER] + weights[CANARY_CLUSTER]
                        percent = round(weights[CANARY_CLUSTER] * 100 / total) if total else 0
                        return percent, str(candidate.get("version_info", "unknown"))
    raise ApiError(503, "Envoy has not accepted a weighted canary route yet.")


def cluster_counters():
    data = fetch_json(f"{ENVOY_ADMIN_URL}/stats?format=json&filter={quote(STATS_FILTER)}")
    counters = {name: {"completed": 0, "errors": 0} for name in RELEASES}
    for stat in data.get("stats", []):
        name = stat.get("name", "")
        for release, details in RELEASES.items():
            prefix = f"cluster.{details['cluster']}."
            if name == prefix + "upstream_rq_completed":
                counters[release]["completed"] = int(stat.get("value", 0))
            elif name == prefix + "upstream_rq_5xx":
                counters[release]["errors"] = int(stat.get("value", 0))
    return counters


def analyse(counters):
    """Compare counters with the snapshot taken when the current step began."""
    baseline = rollout["baseline"] or counters
    result = {}
    for release in RELEASES:
        requests = max(0, counters[release]["completed"] - baseline[release]["completed"])
        errors = max(0, counters[release]["errors"] - baseline[release]["errors"])
        result[release] = {
            "requests": requests,
            "errors": errors,
            "error_rate": round(errors / requests, 4) if requests else None,
        }
    return result


def probe(release):
    started = time.monotonic()
    request = Request(RELEASES[release]["health_url"], headers={"User-Agent": "canary-console/1"})
    try:
        with urlopen(request, timeout=2) as response:
            status_code = response.status
        return {
            "healthy": 200 <= status_code < 300,
            "status_code": status_code,
            "latency_ms": round((time.monotonic() - started) * 1000),
        }
    except HTTPError as error:
        return {"healthy": False, "status_code": error.code, "latency_ms": round((time.monotonic() - started) * 1000)}
    except (URLError, TimeoutError, OSError):
        return {"healthy": False, "status_code": None, "latency_ms": round((time.monotonic() - started) * 1000)}


def gate(weight, analysis, canary_health):
    """Decide whether the rollout may advance and whether it must roll back."""
    canary = analysis["canary"]
    breached = (
        0 < weight < 100
        and canary["requests"] >= MIN_SAMPLES
        and canary["error_rate"] is not None
        and canary["error_rate"] > MAX_ERROR_RATE
    )
    enough_samples = weight == 0 or canary["requests"] >= MIN_SAMPLES
    return {
        "canary_healthy": canary_health["healthy"],
        "enough_samples": enough_samples,
        "error_rate_ok": not breached,
        "can_advance": weight < 100 and canary_health["healthy"] and enough_samples and not breached,
        "must_rollback": 0 < weight < 100 and (breached or not canary_health["healthy"]),
    }


def next_step(weight):
    for step in STEPS:
        if step > weight:
            return step
    return None


def read_state():
    route_error = None
    weight, revision, analysis = None, None, None
    try:
        weight, revision = accepted_route()
        analysis = analyse(cluster_counters())
        envoy_ready = True
    except (ApiError, HTTPError, URLError, TimeoutError, OSError, ValueError, json.JSONDecodeError) as error:
        envoy_ready = False
        route_error = error.message if isinstance(error, ApiError) else "Envoy Admin is not reachable."

    with ThreadPoolExecutor(max_workers=2) as executor:
        futures = {release: executor.submit(probe, release) for release in RELEASES}
        backends = {release: future.result() for release, future in futures.items()}

    return {
        "weight": weight,
        "next_step": next_step(weight) if weight is not None else None,
        "steps": STEPS,
        "revision": revision,
        "status": rollout["status"],
        "reason": rollout["reason"],
        "step_started_at": rollout["step_started_at"],
        "envoy_ready": envoy_ready,
        "route_error": route_error,
        "backends": backends,
        "analysis": analysis,
        "gate": gate(weight, analysis, backends["canary"]) if envoy_ready else None,
        "policy": {"max_error_rate": MAX_ERROR_RATE, "min_samples": MIN_SAMPLES},
        "events": list(events),
        "observed_at": utc_now(),
    }


def render_route(weight, revision):
    # JSON is valid YAML, so Envoy's .yaml path source parses it unchanged.
    route = {
        "version_info": str(revision),
        "resources": [
            {
                "@type": "type.googleapis.com/envoy.config.route.v3.RouteConfiguration",
                "name": "dynamic_route",
                "virtual_hosts": [
                    {
                        "name": "backend",
                        "domains": ["*"],
                        "routes": [
                            {
                                "match": {
                                    "prefix": "/",
                                    "headers": [{"name": "x-canary", "string_match": {"exact": "always"}}],
                                },
                                "route": {"cluster": CANARY_CLUSTER, "timeout": "5s"},
                            },
                            {
                                "match": {"prefix": "/"},
                                "route": {
                                    "timeout": "5s",
                                    "weighted_clusters": {
                                        "clusters": [
                                            {"name": STABLE_CLUSTER, "weight": 100 - weight},
                                            {"name": CANARY_CLUSTER, "weight": weight},
                                        ]
                                    },
                                },
                            },
                        ],
                    }
                ],
            }
        ],
    }
    return (json.dumps(route, indent=2) + "\n").encode("utf-8")


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


def wait_for_revision(revision):
    deadline = time.monotonic() + PUBLISH_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        try:
            _, accepted = accepted_route()
            if accepted == str(revision):
                return True
        except (ApiError, HTTPError, URLError, TimeoutError, OSError, ValueError, json.JSONDecodeError):
            pass
        time.sleep(0.25)
    return False


def next_revision(current):
    try:
        numeric = int(current)
    except (TypeError, ValueError):
        numeric = 0
    rollout["revision_counter"] = max(rollout["revision_counter"], numeric) + 1
    return rollout["revision_counter"]


def publish_weight(weight, current_revision):
    """Publish a new canary weight and wait until Envoy confirms it. Caller holds PUBLISH_LOCK."""
    revision = next_revision(current_revision)
    previous = CURRENT_ROUTE.read_bytes()
    atomic_publish(render_route(weight, revision))
    if not wait_for_revision(revision):
        atomic_publish(previous)
        raise ApiError(502, "Envoy did not accept the route update; the previous route was restored.")
    rollout["baseline"] = cluster_counters()
    rollout["step_started_at"] = utc_now()
    return revision


def advance(expected_weight):
    with PUBLISH_LOCK:
        weight, revision = accepted_route()
        if weight != expected_weight:
            raise ApiError(409, f"Traffic changed since this page loaded; canary weight is {weight}%.")
        target = next_step(weight)
        if target is None:
            raise ApiError(409, "Canary already receives 100% of traffic.")

        verdict = gate(weight, analyse(cluster_counters()), probe("canary"))
        if not verdict["canary_healthy"]:
            raise ApiError(409, "Canary health probe failed; traffic was not changed.")
        if not verdict["enough_samples"]:
            raise ApiError(409, f"Canary needs at least {MIN_SAMPLES} requests at {weight}% before advancing.")
        if not verdict["error_rate_ok"]:
            raise ApiError(409, "Canary error rate is above the policy; roll back instead of advancing.")

        new_revision = publish_weight(target, revision)
        rollout["status"] = "promoted" if target == 100 else "progressing"
        rollout["reason"] = None
        record("promoted" if target == 100 else "advanced", f"Canary weight {weight}% -> {target}%",
               weight=target, revision=str(new_revision))


def rollback(expected_weight, reason, automatic=False):
    """Send all traffic back to stable. Caller must not hold PUBLISH_LOCK."""
    with PUBLISH_LOCK:
        weight, revision = accepted_route()
        if expected_weight is not None and weight != expected_weight:
            raise ApiError(409, f"Traffic changed since this page loaded; canary weight is {weight}%.")
        if weight == 0:
            raise ApiError(409, "Canary already receives 0% of traffic.")
        new_revision = publish_weight(0, revision)
        rollout["status"] = "rolled_back"
        rollout["reason"] = reason
        record("auto_rollback" if automatic else "rollback", f"Canary weight {weight}% -> 0%: {reason}",
               weight=0, revision=str(new_revision))


def analysis_loop():
    """Watch the canary between steps and roll back without waiting for an operator."""
    while True:
        time.sleep(ANALYSIS_INTERVAL_SECONDS)
        try:
            weight, _ = accepted_route()
            if not 0 < weight < 100:
                continue
            health = probe("canary")
            analysis = analyse(cluster_counters())
            if not gate(weight, analysis, health)["must_rollback"]:
                continue
            canary = analysis["canary"]
            if not health["healthy"]:
                reason = "canary health probe failed"
            else:
                reason = (
                    f"error rate {canary['error_rate']:.1%} over {canary['requests']} requests "
                    f"exceeded {MAX_ERROR_RATE:.1%}"
                )
            rollback(weight, reason, automatic=True)
        except ApiError as error:
            if error.status != 409:
                print(f"analysis loop: {error.message}", flush=True)
        except (HTTPError, URLError, TimeoutError, OSError, ValueError, json.JSONDecodeError) as error:
            print(f"analysis loop: {error}", flush=True)


def initialise():
    """Adopt whatever Envoy is serving so a controller restart never moves traffic."""
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        try:
            weight, _ = accepted_route()
            rollout["baseline"] = cluster_counters()
            rollout["step_started_at"] = utc_now()
            rollout["status"] = "idle" if weight == 0 else "promoted" if weight == 100 else "progressing"
            record("adopted", f"Controller adopted canary weight {weight}% from Envoy", weight=weight)
            return
        except (ApiError, HTTPError, URLError, TimeoutError, OSError, ValueError, json.JSONDecodeError):
            time.sleep(1)
    print("Envoy did not report a weighted route within 60s; state will be read lazily.", flush=True)


class Handler(BaseHTTPRequestHandler):
    server_version = "CanaryConsole/1.0"

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
            self.send_json(503, {"error": "Rollout state is temporarily unavailable."})

    def do_POST(self):
        path = urlsplit(self.path).path
        if path != "/api/rollout":
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
            expected_weight = payload.get("expected_weight")
            if not isinstance(expected_weight, int) or isinstance(expected_weight, bool):
                raise ApiError(400, "expected_weight must be an integer percentage.")
            action = payload.get("action")
            if action == "advance":
                advance(expected_weight)
            elif action == "rollback":
                rollback(expected_weight, "operator requested rollback")
            else:
                raise ApiError(400, "action must be advance or rollback.")
            self.send_json(200, read_state())
        except ApiError as error:
            self.send_json(error.status, {"error": error.message})
        except (ValueError, json.JSONDecodeError):
            self.send_json(400, {"error": "Request body contains invalid JSON."})
        except (HTTPError, URLError, TimeoutError, OSError) as error:
            print(f"rollout failed: {error}", flush=True)
            self.send_json(503, {"error": "Envoy is unavailable; traffic was not changed."})
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as error:
            print(f"unexpected rollout failure: {error}", flush=True)
            self.send_json(500, {"error": "Rollout change failed unexpectedly."})

    def log_message(self, fmt, *args):
        print(f"{self.address_string()} {fmt % args}", flush=True)


class Server(ThreadingHTTPServer):
    daemon_threads = True


if __name__ == "__main__":
    if STEPS[0] != 0 or STEPS[-1] != 100 or any(not 0 <= step <= 100 for step in STEPS):
        raise SystemExit("CANARY_STEPS must start at 0, end at 100 and stay within 0-100")
    threading.Thread(target=lambda: (initialise(), analysis_loop()), daemon=True).start()
    print(f"Canary Console listening on 0.0.0.0:{PORT} steps={STEPS}", flush=True)
    Server(("0.0.0.0", PORT), Handler).serve_forever()
