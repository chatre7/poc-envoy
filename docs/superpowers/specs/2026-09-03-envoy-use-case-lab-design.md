# Envoy Use-Case Lab Design

**Date:** 2026-09-03

## Objective

Restructure the existing single Envoy proof of concept into a Thai-language,
self-contained learning lab. Each use case must demonstrate one Envoy
capability with Docker Compose, documented commands, observable expected
results, and an executable smoke test.

## Audience

The lab targets developers and platform engineers who understand HTTP and
Docker basics but may be new to Envoy. Documentation must explain both how to
run an example and why Envoy behaves as observed.

## Chosen Approach

Use independent, intentionally duplicated examples under `use-cases/`. Each
example owns its Compose file, Envoy configuration, helper services, scripts,
and Thai README. Independence is preferred over Compose overlays because a
learner should be able to understand and copy one example without resolving a
shared configuration hierarchy.

The examples use the same host ports (`8080` for traffic and `9901` for the
Envoy admin interface) and are designed to run one at a time. Every README
must tell the learner to stop the previous example before starting another.

## Repository Layout

```text
poc-envoy/
├── README.md
├── scripts/
│   ├── validate.ps1
│   └── validate.sh
├── use-cases/
│   ├── 01-load-balancing-health-check/
│   ├── 02-retry-timeout/
│   ├── 03-circuit-breaker/
│   ├── 04-outlier-detection/
│   ├── 05-local-rate-limit/
│   ├── 06-weighted-canary-routing/
│   ├── 07-tls-mtls/
│   ├── 08-observability/
│   ├── 09-jwt-rbac/
│   └── 10-dynamic-xds/
└── docs/superpowers/
    ├── specs/
    └── plans/
```

The original root-level POC files will remain as a backward-compatible quick
start. The root README will identify them as the baseline and link to the new
learning path. This avoids silently breaking commands that existing users may
already use.

## Common Example Contract

Every use-case directory must contain:

- `docker-compose.yml`, with a project-local network and read-only config
  mounts.
- `envoy.yaml`, or a clearly documented bootstrap file plus dynamic resources.
- `README.md` in Thai with objective, architecture, file roles, start command,
  test steps, expected output, relevant Envoy stats, troubleshooting, and
  cleanup.
- `test.ps1` and `test.sh` smoke tests that exit non-zero when the demonstrated
  behavior is absent.
- Only the smallest additional fixtures or helper services needed by that
  use case.

All examples must use explicit container image versions rather than floating
major/minor `latest` tags. Test-only credentials and certificates must be
clearly labeled and must not be presented as production-safe material.

## Use Cases

### 01. Load Balancing and Active Health Checking

Demonstrate round-robin traffic across two echo backends. The smoke test must
observe responses from both backends, pause one backend while retaining its
Docker network identity, wait for active health
checking to remove it, verify uninterrupted responses from the survivor, then
unpause the backend and verify recovery. Retaining the network identity keeps
DNS removal from masking the active-health-check behavior.

### 02. Retry and Timeout

Use deterministic helper endpoints that can return HTTP 500 or delay a
response. Demonstrate retry on `5xx`, connection failures, and per-try timeout,
while keeping an overall route timeout. Tests must inspect response behavior
and retry-related Envoy counters so a successful health-check failover cannot
be mistaken for a retry.

### 03. Circuit Breaker

Configure deliberately low concurrent request and pending-request limits.
Use a slow backend to hold requests open, generate concurrent traffic, and
verify that excess work is rejected and the relevant overflow counter rises.
The guide must distinguish Envoy circuit breaking from application errors.

### 04. Outlier Detection

Run one healthy backend and one backend that fails repeatedly while both remain
reachable. Enable passive outlier detection and verify that the failing host is
temporarily ejected based on request outcomes rather than an active probe.
Document ejection and re-entry behavior and their counters.

### 05. Local Rate Limit

Apply the HTTP local-rate-limit filter with a small token bucket. Verify that a
short burst produces successful responses followed by HTTP 429, then verify
token refill. This example is process-local and must explain how it differs
from globally coordinated rate limiting.

### 06. Weighted Canary Routing

Route most requests to a stable backend and a minority to a canary backend by
weighted clusters. The test must use a sufficiently large sample and broad
tolerance so it proves that both routes are active without becoming flaky.
The guide will also show a deterministic header-based canary override.

### 07. TLS and Mutual TLS

Provide scripts that generate a local certificate authority, server
certificate, valid client certificate, and untrusted client certificate.
Envoy terminates TLS and requires a trusted client certificate. Tests must
verify that plaintext, missing-certificate, and untrusted-certificate requests
fail while a trusted client succeeds. Generated private material is ignored
from version control and explicitly limited to local learning.

### 08. Observability

Emit structured JSON access logs, expose Envoy Prometheus metrics, and send
traces to a Jaeger-compatible collector using a supported Envoy tracer. The
test verifies a request ID in access logs, a request metric in Prometheus, and
the configured tracing path. The README gives UI URLs and explains correlation
across request, log, metric, and trace.

### 09. JWT Authentication and RBAC

Validate a fixed, non-expiring demonstration RS256 token against local JWKS,
then apply RBAC using claims propagated to dynamic metadata. Include an
authorized token, a valid but unauthorized token, and malformed/missing token
cases. Tests must distinguish authentication failure (401) from authorization
failure (403). Demo keys are fixtures only and must be labeled unsafe for real
credentials.

### 10. Dynamic xDS

Use Envoy's filesystem-backed discovery subscriptions for route and cluster
resources. The initial route targets backend v1; the test replaces the dynamic
resource atomically, waits for an accepted update, and verifies traffic moves
to backend v2 without restarting Envoy. It must also apply an invalid update,
verify rejection/NACK-related state, and restore the valid resource during
cleanup. The guide must state that a production control plane commonly serves
xDS over gRPC and is outside this lab's scope.

## Data Flow

For examples 01-06 and 09, requests flow directly from the host to Envoy and
then to one or more helper backends. Example 07 adds TLS/mTLS at the downstream
listener. Example 08 additionally exports telemetry to Prometheus and Jaeger.
Example 10 separates a static bootstrap from watched discovery-resource files.

Nginx is retained only in the original root baseline. The focused examples
address Envoy directly so another proxy does not hide headers, status codes,
timeouts, retries, or TLS behavior being taught.

## Failure Handling and Cleanup

- Smoke tests must use bounded waits with clear timeout messages.
- Tests that stop services or replace dynamic files must restore the initial
  state in a finally/trap cleanup path.
- README troubleshooting sections must include port conflicts, container
  readiness, image availability, and the most relevant `docker compose logs`
  command.
- `docker compose down -v` is the standard cleanup command for each example.
- No script may delete paths outside its own generated fixture directory.

## Validation Strategy

Validation has two layers:

1. Static validation runs `docker compose config` for every example and Envoy's
   configuration validation mode for every static/bootstrap configuration.
2. Runtime smoke tests start one example, wait for readiness, demonstrate its
   defining behavior, assert expected responses/counters, and tear it down.

The root validation scripts provide static validation for the entire lab and
an opt-in runtime mode. Individual smoke tests remain runnable from their own
directories for teaching and diagnosis.

Because this work primarily creates configuration and instructional fixtures,
the red/green cycle is expressed as behavior-first smoke tests: each test is
written to describe and fail on the absent use case before the corresponding
Envoy configuration is added.

## Documentation Rules

- Thai is the primary explanatory language; commands, file names, protocol
  names, and Envoy field names remain in their canonical form.
- Expected results must be concrete: status codes, response text, counters, or
  UI locations.
- Each guide includes a warning where the example intentionally weakens limits,
  uses demo cryptographic material, or exposes the admin interface.
- The root README provides prerequisites, the one-at-a-time port rule, a table
  of use cases, estimated difficulty, and links in recommended learning order.

## Non-Goals

- A production-ready service mesh or Kubernetes deployment.
- A custom gRPC xDS control plane.
- Globally coordinated rate limiting backed by Redis.
- Production identity-provider integration or certificate lifecycle
  automation.
- Performance benchmarking or capacity recommendations.

## Acceptance Criteria

- Ten numbered use-case directories exist and satisfy the common contract.
- Every Compose file and Envoy bootstrap validates successfully.
- Every smoke test has an explicit observable assertion for its named feature.
- Runtime tests clean up their containers and temporary changes.
- Root documentation links all examples and explains how to run them safely.
- The original root quick start continues to work unchanged.
