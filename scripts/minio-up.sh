#!/usr/bin/env bash
# Stand up MinIO and create the bucket pgBackRest will use as repo2.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

log "deploying MinIO into ${MINIO_NS}"
k get ns "$MINIO_NS" >/dev/null 2>&1 || k create ns "$MINIO_NS"

# pgBackRest talks to S3 over HTTPS only — there is no plain-HTTP mode — so
# MinIO needs a certificate. Generate a self-signed one on the fly rather than
# committing a private key to the repository.
if k -n "$MINIO_NS" get secret minio-tls >/dev/null 2>&1; then
  ok "reusing existing minio-tls certificate"
else
  log "generating a self-signed certificate for minio.${MINIO_NS}.svc"
  need openssl
  certdir="$(mktemp -d)"
  trap 'rm -rf "$certdir"' RETURN
  cat > "${certdir}/san.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = minio.${MINIO_NS}.svc
[v3]
subjectAltName   = @alt
basicConstraints = critical,CA:FALSE
keyUsage         = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
[alt]
DNS.1 = minio
DNS.2 = minio.${MINIO_NS}
DNS.3 = minio.${MINIO_NS}.svc
DNS.4 = minio.${MINIO_NS}.svc.cluster.local
CNF
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout "${certdir}/tls.key" -out "${certdir}/tls.crt" \
    -config "${certdir}/san.cnf" >/dev/null 2>&1
  k -n "$MINIO_NS" create secret tls minio-tls \
    --cert="${certdir}/tls.crt" --key="${certdir}/tls.key"
  ok "certificate created"
fi

k -n "$MINIO_NS" apply -f "${REPO_ROOT}/backup/minio.yaml"
k -n "$MINIO_NS" rollout status deploy/minio --timeout=5m

log "creating the pgbackrest bucket"
# `mc` ships inside the MinIO image, so no extra tooling is needed.
# --insecure because the certificate is self-signed.
# shellcheck disable=SC2016  # $MINIO_ROOT_* must expand inside the pod, not here
k -n "$MINIO_NS" exec deploy/minio -- sh -c '
  mc --insecure alias set local https://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null &&
  mc --insecure mb --ignore-existing local/pgbackrest >/dev/null &&
  mc --insecure ls local/'

ok "MinIO ready at https://minio.${MINIO_NS}.svc:9000  (console: https://localhost:30901)"
dim "    user: pglabaccess  password: pglabsecretkey123"
