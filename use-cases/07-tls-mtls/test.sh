#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")"
compose='docker compose -f ./docker-compose.yml'
cleanup() { $compose down -v >/dev/null 2>&1 || true; }
tls_request() {
  cert=${1:-}
  key=${2:-}
  if [ -n "$cert" ]; then
    printf 'GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n' |
      openssl s_client -connect 127.0.0.1:8080 -CAfile certs/ca.crt -cert "$cert" -key "$key" -quiet 2>&1 || true
  else
    printf 'GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n' |
      openssl s_client -connect 127.0.0.1:8080 -CAfile certs/ca.crt -quiet 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM
./generate-certs.sh
cleanup
$compose up -d
i=0
until curl -fsS http://127.0.0.1:9901/ready >/dev/null 2>&1; do i=$((i+1)); [ "$i" -lt 60 ] || exit 1; sleep 0.5; done
if curl -fsS --max-time 3 http://127.0.0.1:8080/ >/dev/null 2>&1; then exit 1; fi
case "$(tls_request)" in *'mTLS OK'*) exit 1;; esac
case "$(tls_request certs/untrusted-client.crt certs/untrusted-client.key)" in *'mTLS OK'*) exit 1;; esac
case "$(tls_request certs/client.crt certs/client.key)" in *'mTLS OK'*) :;; *) exit 1;; esac
echo 'PASS: plaintext, missing, and untrusted clients rejected; trusted mTLS client accepted'
