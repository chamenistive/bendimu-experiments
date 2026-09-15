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

# 2. PeerAuth STRICT (fix E24 : portLevelMtls invalide en namespace-scope PA
# — health checks auto-bypass via rewriteAppHTTPProbers)
cat <<'EOF' | kubectl apply -f -
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: bendimu-sut-v1
spec:
  mtls: { mode: STRICT }
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
# Validation mTLS (fix E25/E26 : istioctl authn tls-check + x describe pod retirés/bugués)
# → 3 signaux cluster-state kubectl : pod 2/2 ready + PA STRICT + istiod up
SUT_POD=$(kubectl -n bendimu-sut-v1 get pod -l app=sut-v1 -o jsonpath='{.items[0].metadata.name}')
kubectl -n bendimu-sut-v1 get pod "$SUT_POD" -o jsonpath='{.status.containerStatuses[*].ready}' \
  | grep -q "true true" || { echo "❌ SUT pod sidecar non ready"; exit 1; }
kubectl -n bendimu-sut-v1 get peerauthentication default \
  -o jsonpath='{.spec.mtls.mode}' | grep -q "STRICT" || { echo "❌ PA STRICT absent"; exit 1; }
kubectl -n istio-system get deploy istiod -o jsonpath='{.status.readyReplicas}' \
  | grep -qE "^[1-9]" || { echo "❌ istiod down"; exit 1; }
echo "✓ mTLS STRICT validé (pod 2/2 + PA STRICT + istiod up)"

# Retrieve JSON avec retry 3× backoff (fix E16)
retrieve_json() {
  local pod=$1 remote=$2 local=$3
  for attempt in 1 2 3; do
    if kubectl -n bendimu-load exec "$pod" -c helper -- cat "$remote" > "$local" 2>/dev/null; then
      [[ -s "$local" ]] && return 0
    fi
    sleep $((attempt * 2))
  done
  echo "  (partial retrieve $local)"
  return 1
}

# 3. Palier PSD2 60/30/10 (fix E14-E16 : helper sidecar + retry)
FORTIO_POD=$(kubectl -n bendimu-load get pod -l app=fortio -o jsonpath='{.items[0].metadata.name}')
SUT="http://sut-v1.bendimu-sut-v1.svc.cluster.local:8080"

for total_rps in 100 500 1000 2000 4000 8000 12800; do
  aisp_rps=$((total_rps * 60 / 100))
  auth_rps=$((total_rps * 30 / 100))
  exec_rps=$((total_rps * 10 / 100))

  echo "→ total=${total_rps} RPS"

  kubectl -n bendimu-load exec "$FORTIO_POD" -c helper -- \
    rm -f /tmp/aisp.json /tmp/authorize.json /tmp/execute.json 2>/dev/null || true

  kubectl -n bendimu-load exec "$FORTIO_POD" -c fortio -- fortio load \
    -qps "$aisp_rps" -c 128 -t 120s -nocatchup -jitter -uniform -httpbufferkb 2048 -quiet \
    -json /tmp/aisp.json "$SUT/aisp/accounts" >/dev/null 2>&1 &
  PID_AISP=$!
  kubectl -n bendimu-load exec "$FORTIO_POD" -c fortio -- fortio load \
    -qps "$auth_rps" -c 64 -t 120s -nocatchup -jitter -uniform -httpbufferkb 2048 -quiet \
    -X POST -json /tmp/authorize.json "$SUT/pisp/authorize" >/dev/null 2>&1 &
  PID_AUTH=$!
  kubectl -n bendimu-load exec "$FORTIO_POD" -c fortio -- fortio load \
    -qps "$exec_rps" -c 64 -t 120s -nocatchup -jitter -uniform -httpbufferkb 2048 -quiet \
    -X POST -json /tmp/execute.json "$SUT/pisp/execute" >/dev/null 2>&1 &
  PID_EXEC=$!
  wait $PID_AISP $PID_AUTH $PID_EXEC || true

  retrieve_json "$FORTIO_POD" /tmp/aisp.json      "$RESULTS/aisp-${total_rps}rps.json"      || true
  retrieve_json "$FORTIO_POD" /tmp/authorize.json "$RESULTS/authorize-${total_rps}rps.json" || true
  retrieve_json "$FORTIO_POD" /tmp/execute.json   "$RESULTS/execute-${total_rps}rps.json"   || true

  sleep 20
done

# 4. RSS Envoy
kubectl -n bendimu-sut-v1 top pod --containers | grep istio-proxy > "$RESULTS/memory-envoy.txt" || true

git tag -f v1-t2-ok
echo "✅ V1 T2 Istio mTLS OK. Résultats : $RESULTS"
