#!/usr/bin/env sh
set -eu
# Git Bash otherwise rewrites OpenSSL subjects such as /CN=... as Windows paths.
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"
mkdir -p certs
find certs -type f ! -name .gitkeep -delete
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 -subj '/CN=Envoy Lab CA' -keyout certs/ca.key -out certs/ca.crt -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign'
openssl req -newkey rsa:2048 -nodes -sha256 -subj '/CN=localhost' -keyout certs/server.key -out certs/server.csr
printf '%s\n' 'subjectAltName=DNS:localhost,IP:127.0.0.1' 'extendedKeyUsage=serverAuth' 'keyUsage=digitalSignature,keyEncipherment' > certs/server.ext
openssl x509 -req -in certs/server.csr -CA certs/ca.crt -CAkey certs/ca.key -CAcreateserial -days 1 -sha256 -extfile certs/server.ext -out certs/server.crt
openssl req -newkey rsa:2048 -nodes -sha256 -subj '/CN=trusted-client' -keyout certs/client.key -out certs/client.csr
printf '%s\n' 'extendedKeyUsage=clientAuth' 'keyUsage=digitalSignature' > certs/client.ext
openssl x509 -req -in certs/client.csr -CA certs/ca.crt -CAkey certs/ca.key -CAcreateserial -days 1 -sha256 -extfile certs/client.ext -out certs/client.crt
openssl pkcs12 -export -passout pass: -inkey certs/client.key -in certs/client.crt -certfile certs/ca.crt -out certs/client.p12
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 -subj '/CN=Untrusted Lab CA' -keyout certs/untrusted-ca.key -out certs/untrusted-ca.crt -addext 'basicConstraints=critical,CA:TRUE'
openssl req -newkey rsa:2048 -nodes -sha256 -subj '/CN=untrusted-client' -keyout certs/untrusted-client.key -out certs/untrusted-client.csr
openssl x509 -req -in certs/untrusted-client.csr -CA certs/untrusted-ca.crt -CAkey certs/untrusted-ca.key -CAcreateserial -days 1 -sha256 -extfile certs/client.ext -out certs/untrusted-client.crt
openssl pkcs12 -export -passout pass: -inkey certs/untrusted-client.key -in certs/untrusted-client.crt -certfile certs/untrusted-ca.crt -out certs/untrusted-client.p12
# Envoy runs as a non-root user in the container; these throwaway lab keys must be readable through the bind mount.
chmod 644 certs/*.key
rm -f certs/*.csr certs/*.ext certs/*.srl
echo 'Generated local-only certificates in certs/'
