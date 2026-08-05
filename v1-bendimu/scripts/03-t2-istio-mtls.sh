#!/usr/bin/env bash
# V1 T2 — Istio sidecar + PeerAuth STRICT sur SUT V1 PSD2
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../.env"
RESULTS="$SCRIPT_DIR/../results/t2-istio-mtls"
mkdir -p "$RESULTS"

echo "==> V1 T2 Istio sidecar + mTLS STRICT (SUT V1 PSD2)"

# 1. Injection
kubectl label namespace bendimu-sut-v1 istio-injection=enabled --overwrite
kubectl label namespace bendimu-load   istio-injection=enabled --overwrite
kubectl -n bendimu-sut-v1 rollout restart deployment/sut-v1
kubectl -n bendimu-load   rollout restart ds/fortio
kubectl -n bendimu-sut-v1 rollout status deployment/sut-v1 --timeout=180s
kubectl -n bendimu-load   rollout status ds/fortio --timeout=120s

# 2. PeerAuth + BackendConfig health check
cat <<'EOF' | kubectl apply -f -
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: bendimu-sut-v1
spec:
  mtls: { mode: STRICT }
  portLevelMtls:
    "15021": { mode: PERMISSIVE }
---
apiVersion: cloud.google.com/v1
kind: BackendConfig
metadata:
  name: bendimu-gateway-hc
  namespace: bendimu-sut-v1
spec:
  healthCheck:
    type: HTTP2
    port: 15021
    requestPath: /healthz/ready
    checkIntervalSec: 10
    timeoutSec: 5
EOF

sleep 15
istioctl authn tls-check "$(kubectl -n bendimu-sut-v1 get pod -l app=sut-v1 -o jsonpath='{.items[0].metadata.name}')" \
  sut-v1.bendimu-sut-v1.svc.cluster.local || {
  echo "❌ tls-check échoué — voir docs/05 §F1"; exit 1;
}

# 3. Palier PSD2 60/30/10
FORTIO_POD=$(kubectl -n bendimu-load get pod -l app=fortio -o jsonpath='{.items[0].metadata.name}')
SUT="http://sut-v1.bendimu-sut-v1.svc.cluster.local:8080"

for total_rps in 100 500 1000 2000 4000 8000 12800; do
  aisp_rps=$((total_rps * 60 / 100))
  auth_rps=$((total_rps * 30 / 100))
  exec_rps=$((total_rps * 10 / 100))

  echo "→ total=${total_rps} RPS"
  kubectl -n bendimu-load exec "$FORTIO_POD" -- fortio load \
    -qps "$aisp_rps" -c 128 -t 120s -no-catchup -jitter -uniform \
    -json - "$SUT/aisp/accounts" > "$RESULTS/aisp-${total_rps}rps.json" 2>&1 &
  kubectl -n bendimu-load exec "$FORTIO_POD" -- fortio load \
    -qps "$auth_rps" -c 64 -t 120s -no-catchup -jitter -uniform \
    -method POST -json - "$SUT/pisp/authorize" > "$RESULTS/authorize-${total_rps}rps.json" 2>&1 &
  kubectl -n bendimu-load exec "$FORTIO_POD" -- fortio load \
    -qps "$exec_rps" -c 64 -t 120s -no-catchup -jitter -uniform \
    -method POST -json - "$SUT/pisp/execute" > "$RESULTS/execute-${total_rps}rps.json" 2>&1 &
  wait
  sleep 20
done

# 4. RSS Envoy
kubectl -n bendimu-sut-v1 top pod --containers | grep istio-proxy > "$RESULTS/memory-envoy.txt" || true

git tag -f v1-t2-ok
echo "✅ V1 T2 Istio mTLS OK. Résultats : $RESULTS"
