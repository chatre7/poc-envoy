# Envoy Use-Case Lab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build ten independent, Thai-documented Docker Compose labs that prove specific Envoy behaviors with executable smoke tests.

**Architecture:** Keep the existing root POC intact and add numbered, self-contained examples under `use-cases/`. Each example exposes Envoy on host ports 8080 and 9901, owns its fixtures and tests, and runs one at a time; root scripts perform cross-lab static validation and optional runtime execution.

**Tech Stack:** Envoy 1.32.13, Docker Compose v2, Python 3.12.7-alpine helper backends, HashiCorp http-echo 1.0, Prometheus 2.54.1, Jaeger all-in-one 1.62.0, PowerShell 7+, POSIX shell, curl, OpenSSL.

**Spec:** `docs/superpowers/specs/2026-09-03-envoy-use-case-lab-design.md`

## Global Constraints

- Preserve the original root `docker-compose.yml`, `envoy.yaml`, and `nginx.conf` behavior.
- Thai is the primary documentation language; commands and Envoy field names stay canonical.
- Use explicit image versions; do not use floating `latest` tags in new examples.
- Every use case contains `docker-compose.yml`, Envoy config/bootstrap, `README.md`, `test.ps1`, and `test.sh`.
- Examples use host ports 8080 and 9901 and must be run one at a time.
- Each smoke test uses bounded waits, returns non-zero on failure, and restores state it changes.
- Every lab README includes objective, architecture, file roles, start steps, test steps, concrete expected output, relevant stats, troubleshooting, and cleanup.
- Test crypto/JWT fixtures are clearly marked unsafe for production.
- The workspace is not currently a Git repository, so commit steps are omitted; create a checkpoint after each task by running its complete validation commands.

## File Map

- `README.md`: existing quick start plus prerequisites and ordered lab index.
- `scripts/validate.ps1`, `scripts/validate.sh`: enumerate all ten directories, run Compose/config validation, optionally run smoke tests.
- `use-cases/<nn-name>/docker-compose.yml`: complete isolated topology for one behavior.
- `use-cases/<nn-name>/envoy.yaml`: static config or xDS bootstrap.
- `use-cases/<nn-name>/test.ps1`, `test.sh`: equivalent Windows/POSIX behavioral assertions.
- `use-cases/<nn-name>/README.md`: Thai explanation and operator guide.
- `use-cases/02-*` through `04-*` helper backend files: deterministic status/delay behavior.
- `use-cases/07-tls-mtls/certs/`: generated local certificates only; ignored except `.gitkeep`.
- `use-cases/08-observability/prometheus.yml`: Prometheus scrape target.
- `use-cases/09-jwt-rbac/fixtures/`: fixed demo JWKS and tokens.
- `use-cases/10-dynamic-xds/xds/`: versioned route and cluster discovery resources plus reset fixtures.

---

### Task 1: Root validation contract

**Files:**
- Create: `scripts/validate.ps1`
- Create: `scripts/validate.sh`
- Create: `use-cases/.gitkeep`

**Interfaces:**
- Consumes: numbered directories under `use-cases/`, each with `docker-compose.yml` and `test.ps1`/`test.sh`.
- Produces: `./scripts/validate.ps1 [-Runtime]` and `./scripts/validate.sh [--runtime]`.

- [ ] **Step 1: Write the validation scripts before any lab exists**

PowerShell must enumerate `use-cases/[0-9][0-9]-*`, fail if the count is not 10, run both Compose and Envoy validation, and in runtime mode invoke each test from its own directory:

```powershell
param([switch]$Runtime)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$labs = @(Get-ChildItem -LiteralPath (Join-Path $root 'use-cases') -Directory |
  Where-Object Name -Match '^\d{2}-' | Sort-Object Name)
if ($labs.Count -ne 10) { throw "expected 10 labs, found $($labs.Count)" }
foreach ($lab in $labs) {
  docker compose -f (Join-Path $lab.FullName 'docker-compose.yml') config --quiet
  if ($LASTEXITCODE -ne 0) { throw "compose validation failed: $($lab.Name)" }
  if (Test-Path (Join-Path $lab.FullName 'generate-certs.ps1')) {
    & (Join-Path $lab.FullName 'generate-certs.ps1')
  }
  Push-Location $lab.FullName
  try {
    docker compose run --rm --no-deps envoy --mode validate -c /etc/envoy/envoy.yaml
    if ($LASTEXITCODE -ne 0) { throw "envoy validation failed: $($lab.Name)" }
    if ($Runtime) { & ./test.ps1 }
  } finally {
    Pop-Location
  }
}
```

The POSIX version must provide the same contract using `find`, `sort`, and a loop without GNU-only flags. It changes into each lab directory before running `docker compose run --rm --no-deps envoy --mode validate -c /etc/envoy/envoy.yaml` or `./test.sh`, and invokes `generate-certs.sh` first when present.

- [ ] **Step 2: Run the scripts and observe the expected failure**

Run: `pwsh -File scripts/validate.ps1`

Expected: non-zero with `expected 10 labs, found 0` because only `use-cases/.gitkeep` exists.

- [ ] **Step 3: Syntax-check both scripts**

Run: `pwsh -NoProfile -Command "[void][scriptblock]::Create((Get-Content -Raw scripts/validate.ps1))"`

Run: `bash -n scripts/validate.sh`

Expected: both exit 0; the full validation remains red until Tasks 2-11 are complete.

---

### Task 2: Load balancing and active health checking lab

**Files:**
- Create: `use-cases/01-load-balancing-health-check/docker-compose.yml`
- Create: `use-cases/01-load-balancing-health-check/envoy.yaml`
- Create: `use-cases/01-load-balancing-health-check/test.ps1`
- Create: `use-cases/01-load-balancing-health-check/test.sh`
- Create: `use-cases/01-load-balancing-health-check/README.md`

**Interfaces:**
- Consumes: Docker, curl, Envoy admin `/clusters` and `/stats`.
- Produces: `http://localhost:8080`, admin `http://localhost:9901`, responses `Hello from APP-1` and `Hello from APP-2`.

- [ ] **Step 1: Write smoke tests that assert both backends, removal, and recovery**

Use a bounded request helper and these assertions in both shell variants:

```powershell
$responses = 1..10 | ForEach-Object { (Invoke-WebRequest http://localhost:8080 -UseBasicParsing).Content.Trim() }
if ($responses -notcontains 'Hello from APP-1' -or $responses -notcontains 'Hello from APP-2') { throw 'round robin not observed' }
docker compose pause app1
# Poll /clusters for app1 health flag removal, maximum 20 seconds.
$survivors = 1..6 | ForEach-Object { (Invoke-WebRequest http://localhost:8080 -UseBasicParsing).Content.Trim() }
if ($survivors | Where-Object { $_ -ne 'Hello from APP-2' }) { throw 'unhealthy app1 still received traffic' }
docker compose unpause app1
# Poll until APP-1 appears in responses again, maximum 20 seconds.
```

Wrap startup and state changes in `try/finally`; `finally` runs `docker compose down -v`.

- [ ] **Step 2: Verify the test fails because the lab is absent**

Run: `pwsh -File use-cases/01-load-balancing-health-check/test.ps1`

Expected: non-zero because the Compose file/config does not exist.

- [ ] **Step 3: Implement the isolated topology and Envoy policy**

Create services `envoy`, `app1`, and `app2`. Pin images to `envoyproxy/envoy:v1.32.13` and `hashicorp/http-echo:1.0`. Configure a listener on 10000, `STRICT_DNS` cluster, `ROUND_ROBIN`, and:

```yaml
health_checks:
  - timeout: 1s
    interval: 2s
    unhealthy_threshold: 2
    healthy_threshold: 1
    http_health_check: { path: "/" }
```

Map Envoy `8080:10000` and `9901:9901`; mount `envoy.yaml` read-only.

- [ ] **Step 4: Write the Thai guide**

Document architecture, active versus passive health checks, start/test/manual failure/recovery commands, expected response alternation, `cluster.backend_cluster.health_check.*` stats, port-conflict troubleshooting, and `docker compose down -v`.

- [ ] **Step 5: Validate and run the complete smoke test**

Run: `docker compose -f use-cases/01-load-balancing-health-check/docker-compose.yml config --quiet`

Run: `pwsh -File use-cases/01-load-balancing-health-check/test.ps1`

Expected: both exit 0 and containers are removed afterward.

---

### Task 3: Retry and timeout lab

**Files:**
- Create: `use-cases/02-retry-timeout/docker-compose.yml`
- Create: `use-cases/02-retry-timeout/envoy.yaml`
- Create: `use-cases/02-retry-timeout/backend.py`
- Create: `use-cases/02-retry-timeout/test.ps1`
- Create: `use-cases/02-retry-timeout/test.sh`
- Create: `use-cases/02-retry-timeout/README.md`

**Interfaces:**
- Backend endpoints: `GET /ok`, `GET /fail-once`, `GET /slow-once`, `GET /always-slow`, `GET /health`.
- Envoy responses expose `X-Backend-Attempt` so tests can distinguish retries from health failover.

- [ ] **Step 1: Write red smoke assertions**

Assert `/fail-once` returns 200 with attempt header `2`, `/slow-once` returns 200 after a per-try timeout retry, `/always-slow` returns 504 within six seconds, and `cluster.backend_cluster.upstream_rq_retry` increases.

```bash
code=$(curl -sS -D headers.txt -o body.txt -w '%{http_code}' http://localhost:8080/fail-once)
test "$code" = 200
grep -qi '^x-backend-attempt: 2' headers.txt
curl -fsS http://localhost:9901/stats?filter=upstream_rq_retry | grep -Eq 'upstream_rq_retry: [1-9]'
```

- [ ] **Step 2: Run and confirm missing-feature failure**

Run: `bash use-cases/02-retry-timeout/test.sh`

Expected: non-zero because the directory/topology is absent.

- [ ] **Step 3: Implement deterministic backend behavior**

Use `http.server.ThreadingHTTPServer`; keep counters keyed by path. `/fail-once` returns 503 on odd attempts and 200 on even attempts, `/slow-once` sleeps three seconds on odd attempts, `/always-slow` always sleeps six seconds, `/health` always returns 200, and every response includes the attempt header.

- [ ] **Step 4: Configure retries and bounded timeouts**

```yaml
route:
  cluster: backend_cluster
  timeout: 5s
  retry_policy:
    retry_on: "5xx,connect-failure,reset,retriable-status-codes"
    num_retries: 1
    per_try_timeout: 2s
    retriable_status_codes: [503]
```

Disable active health checking in this lab so test evidence comes from retry counters and attempt headers.

- [ ] **Step 5: Document and verify**

Explain overall versus per-try timeout, idempotency risk, retry storms, counters, and expected status/header values. Run Compose validation and both platform smoke-test syntax checks, then execute the PowerShell smoke test to exit 0.

---

### Task 4: Circuit breaker lab

**Files:**
- Create: `use-cases/03-circuit-breaker/docker-compose.yml`
- Create: `use-cases/03-circuit-breaker/envoy.yaml`
- Create: `use-cases/03-circuit-breaker/backend.py`
- Create: `use-cases/03-circuit-breaker/test.ps1`
- Create: `use-cases/03-circuit-breaker/test.sh`
- Create: `use-cases/03-circuit-breaker/README.md`

**Interfaces:**
- Backend `GET /hold` sleeps four seconds; `GET /health` responds immediately.
- Test observes `cluster.backend_cluster.upstream_rq_pending_overflow` or `upstream_rq_active_overflow`.

- [ ] **Step 1: Write concurrent red test**

Start eight `/hold` requests concurrently, collect status codes, require at least one 200 and at least one 503, then query overflow stats and require a positive value. PowerShell uses `Start-Job` with a ten-second receive timeout; shell uses background curl PIDs and a trap.

- [ ] **Step 2: Observe failure before configuration exists**

Run: `pwsh -File use-cases/03-circuit-breaker/test.ps1`

Expected: non-zero due to missing Compose file.

- [ ] **Step 3: Implement slow backend and low breaker thresholds**

```yaml
circuit_breakers:
  thresholds:
    - priority: DEFAULT
      max_connections: 1
      max_pending_requests: 1
      max_requests: 2
      max_retries: 1
```

Use the Python helper service and configure health checking against `/health`, not `/hold`.

- [ ] **Step 4: Document and verify**

Explain backpressure, why limits are intentionally tiny, 503 with `x-envoy-overloaded`, and overflow counters. Validate Compose and run the PowerShell test to exit 0 with cleanup.

---

### Task 5: Outlier detection lab

**Files:**
- Create: `use-cases/04-outlier-detection/docker-compose.yml`
- Create: `use-cases/04-outlier-detection/envoy.yaml`
- Create: `use-cases/04-outlier-detection/backend.py`
- Create: `use-cases/04-outlier-detection/test.ps1`
- Create: `use-cases/04-outlier-detection/test.sh`
- Create: `use-cases/04-outlier-detection/README.md`

**Interfaces:**
- `good` backend always returns 200; `bad` backend returns 503 while remaining reachable.
- Test observes `cluster.backend_cluster.outlier_detection.ejections_total` and subsequent good-only traffic.

- [ ] **Step 1: Write red assertions**

Send requests until at least three 503 responses have been observed, poll the ejection counter for up to 15 seconds, then require ten consecutive `GOOD` responses.

- [ ] **Step 2: Confirm pre-implementation failure**

Run: `bash use-cases/04-outlier-detection/test.sh`

Expected: non-zero because no topology exists.

- [ ] **Step 3: Configure passive ejection without active health checks**

```yaml
outlier_detection:
  consecutive_5xx: 2
  interval: 1s
  base_ejection_time: 10s
  max_ejection_percent: 50
```

Use one Python image twice with `BACKEND_MODE=good|bad`; both `/health` endpoints remain 200, but do not configure Envoy active checking.

- [ ] **Step 4: Document and verify**

Explain passive observation, ejection duration, `max_ejection_percent`, and re-entry. Validate Compose and run the smoke test to exit 0.

---

### Task 6: Local rate-limit lab

**Files:**
- Create: `use-cases/05-local-rate-limit/docker-compose.yml`
- Create: `use-cases/05-local-rate-limit/envoy.yaml`
- Create: `use-cases/05-local-rate-limit/test.ps1`
- Create: `use-cases/05-local-rate-limit/test.sh`
- Create: `use-cases/05-local-rate-limit/README.md`

**Interfaces:**
- Successful response is `OK`; limited response is 429 with `x-local-rate-limit: true`.
- Test observes `http_local_rate_limit.enabled` and `rate_limited` counters.

- [ ] **Step 1: Write burst/refill tests**

Issue five immediate requests, require exactly two 200 responses and at least three 429 responses, sleep six seconds, then require the next request to be 200.

- [ ] **Step 2: Observe missing filter failure**

Run: `pwsh -File use-cases/05-local-rate-limit/test.ps1`

Expected: non-zero because the lab is absent.

- [ ] **Step 3: Add the HTTP local rate-limit filter before router**

```yaml
- name: envoy.filters.http.local_ratelimit
  typed_config:
    "@type": type.googleapis.com/envoy.extensions.filters.http.local_ratelimit.v3.LocalRateLimit
    stat_prefix: http_local_rate_limit
    token_bucket: { max_tokens: 2, tokens_per_fill: 2, fill_interval: 5s }
    filter_enabled: { default_value: { numerator: 100, denominator: HUNDRED } }
    filter_enforced: { default_value: { numerator: 100, denominator: HUNDRED } }
    response_headers_to_add:
      - append_action: OVERWRITE_IF_EXISTS_OR_ADD
        header: { key: x-local-rate-limit, value: "true" }
```

- [ ] **Step 4: Document and verify**

Explain token buckets and per-process versus global coordination. Validate Compose and run smoke tests with deterministic cleanup.

---

### Task 7: Weighted canary-routing lab

**Files:**
- Create: `use-cases/06-weighted-canary-routing/docker-compose.yml`
- Create: `use-cases/06-weighted-canary-routing/envoy.yaml`
- Create: `use-cases/06-weighted-canary-routing/test.ps1`
- Create: `use-cases/06-weighted-canary-routing/test.sh`
- Create: `use-cases/06-weighted-canary-routing/README.md`

**Interfaces:**
- Default traffic is weighted 80 stable / 20 canary.
- Header `x-canary: always` deterministically routes to canary.

- [ ] **Step 1: Write statistical and deterministic red tests**

Send 100 default requests, require stable count 55-95 and canary count 5-45, then send five header overrides and require all five responses to equal `CANARY`.

- [ ] **Step 2: Confirm absence failure**

Run: `bash use-cases/06-weighted-canary-routing/test.sh`

Expected: non-zero because no route exists.

- [ ] **Step 3: Configure ordered header route and weighted fallback**

```yaml
routes:
  - match: { prefix: "/", headers: [{ name: x-canary, exact_match: always }] }
    route: { cluster: canary }
  - match: { prefix: "/" }
    route:
      weighted_clusters:
        clusters:
          - { name: stable, weight: 80 }
          - { name: canary, weight: 20 }
```

Create explicit `stable` and `canary` clusters backed by pinned http-echo images.

- [ ] **Step 4: Document and verify**

Explain route order, sample variance, progressive delivery, and deterministic override. Validate and run the test; repeat it three times to catch flaky tolerance.

---

### Task 8: TLS and mutual-TLS lab

**Files:**
- Create: `use-cases/07-tls-mtls/docker-compose.yml`
- Create: `use-cases/07-tls-mtls/envoy.yaml`
- Create: `use-cases/07-tls-mtls/generate-certs.ps1`
- Create: `use-cases/07-tls-mtls/generate-certs.sh`
- Create: `use-cases/07-tls-mtls/certs/.gitkeep`
- Create: `use-cases/07-tls-mtls/.gitignore`
- Create: `use-cases/07-tls-mtls/test.ps1`
- Create: `use-cases/07-tls-mtls/test.sh`
- Create: `use-cases/07-tls-mtls/README.md`

**Interfaces:**
- HTTPS listener: `https://localhost:8080`.
- Generated files: `ca.crt`, `server.crt/key`, `client.crt/key`, `untrusted-ca.crt`, `untrusted-client.crt/key`.

- [ ] **Step 1: Write certificate and handshake assertions**

The tests generate fixtures, start the lab, require TLS without a client cert to fail, require an untrusted client to fail, and require this request to return `mTLS OK`:

```bash
curl --fail --cacert certs/ca.crt --cert certs/client.crt --key certs/client.key https://localhost:8080/
```

- [ ] **Step 2: Confirm the red state**

Run: `bash use-cases/07-tls-mtls/test.sh`

Expected: non-zero because certificate scripts and listener are absent.

- [ ] **Step 3: Implement reproducible certificate generation**

Use OpenSSL with RSA 2048, SHA-256, one-day validity, SAN `DNS:localhost,IP:127.0.0.1`, server EKU for the listener, and client EKU for both client certificates. Generate files only inside `certs/`; ignore `certs/*` except `.gitkeep`.

- [ ] **Step 4: Configure downstream TLS validation**

```yaml
transport_socket:
  name: envoy.transport_sockets.tls
  typed_config:
    "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.DownstreamTlsContext
    require_client_certificate: true
    common_tls_context:
      tls_certificates:
        - certificate_chain: { filename: /etc/envoy/certs/server.crt }
          private_key: { filename: /etc/envoy/certs/server.key }
      validation_context:
        trusted_ca: { filename: /etc/envoy/certs/ca.crt }
```

- [ ] **Step 5: Document and verify**

Explain CA trust, server identity, client identity, failure modes, and local-only keys. Run both generation scripts' syntax checks, Compose validation after generation, and the PowerShell runtime smoke test.

---

### Task 9: Observability lab

**Files:**
- Create: `use-cases/08-observability/docker-compose.yml`
- Create: `use-cases/08-observability/envoy.yaml`
- Create: `use-cases/08-observability/prometheus.yml`
- Create: `use-cases/08-observability/test.ps1`
- Create: `use-cases/08-observability/test.sh`
- Create: `use-cases/08-observability/README.md`

**Interfaces:**
- Traffic `:8080`, Envoy admin `:9901`, Prometheus `:9090`, Jaeger UI `:16686`.
- Envoy writes one-line JSON access logs to stdout and sends Zipkin spans to Jaeger port 9411.

- [ ] **Step 1: Write correlation smoke assertions**

Send `x-request-id: 11111111-1111-4111-8111-111111111111`, then require the Envoy logs to contain that ID and valid JSON fields `method`, `path`, `response_code`, and `duration_ms`. Query Prometheus until `envoy_http_downstream_rq_total` is present. Query Jaeger API `/api/traces?service=envoy` until at least one trace is returned.

- [ ] **Step 2: Verify tests fail without telemetry services**

Run: `pwsh -File use-cases/08-observability/test.ps1`

Expected: non-zero because the lab is absent.

- [ ] **Step 3: Configure JSON logs, tracing, and metrics**

Set HCM `generate_request_id: true`, `tracing: { provider: { name: envoy.tracers.zipkin, typed_config: ... } }`, `random_sampling: 100`, and a stdout access logger with typed JSON fields. Add a `jaeger` cluster targeting `jaeger:9411`. Configure Prometheus to scrape `envoy:9901` at `/stats/prometheus`.

- [ ] **Step 4: Compose pinned telemetry services**

Use `prom/prometheus:v2.54.1` and `jaegertracing/all-in-one:1.62.0`; enable Jaeger's Zipkin HTTP receiver with `COLLECTOR_ZIPKIN_HOST_PORT=:9411`. Add health-aware bounded polling in tests because both UIs start asynchronously.

- [ ] **Step 5: Document and verify**

Explain logs versus metrics versus traces, correlation by request ID/trace, query URLs, and that admin/UI ports require protection in real deployments. Validate Compose and run the smoke test to exit 0.

---

### Task 10: JWT authentication and RBAC lab

**Files:**
- Create: `use-cases/09-jwt-rbac/docker-compose.yml`
- Create: `use-cases/09-jwt-rbac/envoy.yaml`
- Create: `use-cases/09-jwt-rbac/fixtures/jwks.json`
- Create: `use-cases/09-jwt-rbac/fixtures/authorized.token`
- Create: `use-cases/09-jwt-rbac/fixtures/unauthorized.token`
- Create: `use-cases/09-jwt-rbac/fixtures/README.md`
- Create: `use-cases/09-jwt-rbac/test.ps1`
- Create: `use-cases/09-jwt-rbac/test.sh`
- Create: `use-cases/09-jwt-rbac/README.md`

**Interfaces:**
- Missing/malformed token returns 401; valid token with role `viewer` returns 403; valid token with role `admin` returns `AUTHORIZED`.
- JWT metadata namespace is `envoy.filters.http.jwt_authn`, provider name `demo`.

- [ ] **Step 1: Write the 401/403/200 matrix first**

```bash
test "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/)" = 401
test "$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer broken' http://localhost:8080/)" = 401
viewer=$(cat fixtures/unauthorized.token)
test "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $viewer" http://localhost:8080/)" = 403
admin=$(cat fixtures/authorized.token)
test "$(curl -s -o body.txt -w '%{http_code}' -H "Authorization: Bearer $admin" http://localhost:8080/)" = 200
grep -q AUTHORIZED body.txt
```

- [ ] **Step 2: Verify red state**

Run: `bash use-cases/09-jwt-rbac/test.sh`

Expected: non-zero because fixtures/config are absent.

- [ ] **Step 3: Create deterministic demo JWT fixtures**

Generate one RSA keypair offline during implementation, store only the public JWK and two signed, non-expiring tokens. Claims are identical except `role`: `admin` versus `viewer`; both use issuer `https://demo.envoy.local`, audience `envoy-lab`, subject `student`, algorithm `RS256`, and key ID `envoy-lab-key`. Document that the private key is discarded and tokens are non-production fixtures.

- [ ] **Step 4: Chain JWT then RBAC then router filters**

Configure `envoy.filters.http.jwt_authn` with inline `local_jwks`, issuer/audience validation, payload metadata `demo`, and an all-route requirement. Configure `envoy.filters.http.rbac` to allow only metadata claim path `demo.payload.role` equal to `admin`; ensure filter order is JWT, RBAC, router.

- [ ] **Step 5: Document and verify**

Explain authentication versus authorization, filter order, 401 versus 403, fixture risk, and production IdP/JWKS rotation. Validate Envoy/Compose and run both platform smoke-test syntax checks plus one runtime test.

---

### Task 11: Filesystem-backed dynamic xDS lab

**Files:**
- Create: `use-cases/10-dynamic-xds/docker-compose.yml`
- Create: `use-cases/10-dynamic-xds/envoy.yaml`
- Create: `use-cases/10-dynamic-xds/xds/routes-v1.yaml`
- Create: `use-cases/10-dynamic-xds/xds/routes-v2.yaml`
- Create: `use-cases/10-dynamic-xds/xds/routes-invalid.yaml`
- Create: `use-cases/10-dynamic-xds/xds/routes-current.yaml`
- Create: `use-cases/10-dynamic-xds/xds/clusters.yaml`
- Create: `use-cases/10-dynamic-xds/reset.ps1`
- Create: `use-cases/10-dynamic-xds/reset.sh`
- Create: `use-cases/10-dynamic-xds/test.ps1`
- Create: `use-cases/10-dynamic-xds/test.sh`
- Create: `use-cases/10-dynamic-xds/README.md`

**Interfaces:**
- Static bootstrap subscribes to filesystem RDS and CDS resources under `/etc/envoy/xds/`.
- Reset scripts copy v1 atomically to `routes-current.yaml`; tests always restore v1.

- [ ] **Step 1: Write no-restart and rejection assertions**

Record Envoy container ID, require initial `VERSION-1`, atomically replace current route with v2, poll for `VERSION-2`, and assert the container ID is unchanged. Apply invalid route data, require the last valid v2 route to continue serving, and require `config_reload` failure stats or `/config_dump` evidence of the retained accepted version. Restore v1 in a trap/finally block.

- [ ] **Step 2: Confirm missing xDS failure**

Run: `pwsh -File use-cases/10-dynamic-xds/test.ps1`

Expected: non-zero because discovery resources do not exist.

- [ ] **Step 3: Implement bootstrap and discovery resources**

Use `dynamic_resources.cds_config.path: /etc/envoy/xds/clusters.yaml`; configure the listener HCM with `rds.config_source.path: /etc/envoy/xds/routes-current.yaml`. Resource files use `DiscoveryResponse` envelopes with v3 type URLs and monotonically distinct `version_info` values. Define clusters `backend_v1` and `backend_v2`; only RDS changes during the demonstration.

- [ ] **Step 4: Implement atomic reset/update operations**

PowerShell copies to `routes-current.yaml.tmp` then uses `Move-Item -Force`; POSIX copies to a sibling temp file then calls `mv`. Scripts resolve their own directory and reject any target outside `xds/` before replacement.

- [ ] **Step 5: Document and verify**

Explain LDS/RDS/CDS/EDS/SDS, filesystem subscriptions versus a gRPC control plane, atomic updates, accepted versions, rejected updates, and rollback. Validate Compose/bootstrap and run the full smoke test twice to prove reset idempotence.

---

### Task 12: Root learning path and whole-lab acceptance

**Files:**
- Modify: `README.md`
- Modify: `scripts/validate.ps1`
- Modify: `scripts/validate.sh`

**Interfaces:**
- Consumes: all ten completed lab contracts.
- Produces: a discoverable Thai learning path and one static-validation entry point.

- [ ] **Step 1: Run the root validation to expose integration gaps**

Run: `pwsh -File scripts/validate.ps1`

Expected before integration fixes: any missing Compose file, invalid YAML, wrong directory count, or missing test entry point is reported with the lab name.

- [ ] **Step 2: Expand the root README without removing the original quick start**

Add prerequisites, version table, one-at-a-time port warning, original Nginx-to-Envoy quick start, and a table linking all ten labs with columns `ลำดับ`, `Use case`, `สิ่งที่พิสูจน์`, and `ระดับ`. Add standard commands:

```powershell
Set-Location use-cases/01-load-balancing-health-check
docker compose up -d
./test.ps1
docker compose down -v
```

```bash
cd use-cases/01-load-balancing-health-check
docker compose up -d
./test.sh
docker compose down -v
```

- [ ] **Step 3: Harden root validation messages and runtime cleanup**

Ensure each lab name is printed before validation, collect all static failures before exiting, stop runtime execution on the first behavioral failure, and in a final cleanup loop run `docker compose down -v` for every numbered directory.

- [ ] **Step 4: Run static acceptance**

Run: `pwsh -File scripts/validate.ps1`

Run: `bash scripts/validate.sh`

Expected: both report 10 validated labs and exit 0.

- [ ] **Step 5: Run runtime acceptance**

Run: `pwsh -File scripts/validate.ps1 -Runtime`

Expected: all ten smoke tests pass, every Compose project is down afterward, and ports 8080/9901 are free.

- [ ] **Step 6: Re-check the original root baseline**

Run: `docker compose config --quiet`

Run: `docker compose up -d`

Run ten requests to `http://localhost:8080` and require both `Hello from APP-1` and `Hello from APP-2`, then run `docker compose down -v`.

Expected: original Nginx-to-Envoy behavior remains unchanged.
