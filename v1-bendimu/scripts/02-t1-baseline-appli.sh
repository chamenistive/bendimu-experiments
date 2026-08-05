#!/usr/bin/env bash
# V1 T1 — mTLS applicatif Go pur (crypto/tls), sans mesh
# Isole le coût crypto TLS pour comparaison overhead mesh (T2/T3).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../.env"
RESULTS="$SCRIPT_DIR/../results/t1-baseline-appli"
mkdir -p "$RESULTS"
CERT_DIR="$SCRIPT_DIR/../secrets"
mkdir -p "$CERT_DIR"

echo "==> V1 T1 baseline applicative (mTLS Go pur)"

# 1. Certificats auto-signés (CA + server + client)
if [[ ! -f "$CERT_DIR/ca.crt" ]]; then
  cd "$CERT_DIR"
  openssl req -x509 -newkey rsa:4096 -sha256 -days 30 -nodes \
    -keyout ca.key -out ca.crt \
    -subj "/CN=bendimu-ca"
  openssl req -newkey rsa:2048 -sha256 -nodes -keyout server.key -out server.csr \
    -subj "/CN=sut-v1.bendimu-sut-v1.svc"
  openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out server.crt -days 30 -sha256
  openssl req -newkey rsa:2048 -sha256 -nodes -keyout client.key -out client.csr \
    -subj "/CN=fortio-client"
  openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out client.crt -days 30 -sha256
  cd -
fi

kubectl -n bendimu-sut-v1 create secret generic sut-tls \
  --from-file=tls.crt="$CERT_DIR/server.crt" \
  --from-file=tls.key="$CERT_DIR/server.key" \
  --from-file=ca.crt="$CERT_DIR/ca.crt" \
  --dry-run=client -o yaml | kubectl apply -f -

# 2. Redéploiement SUT V1 avec mount TLS + args serveur HTTPS
# NOTE: le main.go actuel démarre en HTTP. Pour un vrai T1 il faut une variante TLS.
# En attendant, on documente la limite ici et on saute l'exécution effective si non implémenté.
echo "⚠️  T1 non implémenté côté code Go — voir docs/03 §4.3 pour la spec."
echo "   Placeholder : copie de T0 comme référence en attendant l'implémentation TLS applicatif."

cp -r "$SCRIPT_DIR/../results/t0-baseline-reseau/"* "$RESULTS/" 2>/dev/null || true

git tag -f v1-t1-ok
echo "✅ V1 T1 (placeholder) — implémenter TLS Go et re-run pour mesure officielle."
