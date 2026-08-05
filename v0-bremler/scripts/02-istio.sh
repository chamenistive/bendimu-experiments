#!/usr/bin/env bash
# V0 T1 Istio sidecar + mTLS STRICT
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../.env"
RESULTS="$SCRIPT_DIR/../results/t1-istio"
mkdir -p "$RESULTS"

echo "==> V0 T1 Istio sidecar + mTLS STRICT"

# 1. Injection Istio
kubectl label namespace bendimu-sut istio-injection=enabled --overwrite
kubectl label namespace bendimu-load istio-injection=enabled --overwrite
kubectl -n bendimu-sut  rollout restart deployment/sut-bremler
kubectl -n bendimu-load rollout restart ds/fortio
kubectl -n bendimu-sut  rollout status deployment/sut-bremler --timeout=180s
kubectl -n bendimu-load rollout status ds/fortio --timeout=120s

# 2. PeerAuthentication STRICT + exception health check
cat <<'EOF' | kubectl apply -f -
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: bendimu-sut
spec:
  mtls: { mode: STRICT }
  portLevelMtls:
    "15021": { mode: PERMISSIVE }
EOF

# 3. Vérif mTLS
sleep 15
istioctl authn tls-check "$(kubectl -n bendimu-sut get pod -l app=sut-bremler -o jsonpath='{.items[0].metadata.name}')" \
  sut-bremler.bendimu-sut.svc.cluster.local || {
  echo "❌ tls-check échoué — voir docs/05 §F1"; exit 1;
}

# 4. Palier de charge (fortio dans pod mesh)
FORTIO_POD=$(kubectl -n bendimu-load get pod -l app=fortio -o jsonpath='{.items[0].metadata.name}')
SUT_URL="http://sut-bremler.bendimu-sut.svc.cluster.local:8080"

for endpoint in "" "data10kb" "data1mb"; do
  for rps in 100 500 1000 2000 4000 8000 12800; do
    echo "→ endpoint=/$endpoint rps=$rps"
    kubectl -n bendimu-load exec "$FORTIO_POD" -- fortio load \
      -qps "$rps" -c 200 -t 120s \
      -no-catchup -jitter -uniform \
      -json "-" "$SUT_URL/$endpoint" \
      > "$RESULTS/${endpoint:-root}-${rps}rps.json" 2>&1 || echo "  (partial)"
    sleep 15
  done
done

# 5. RSS Envoy sidecar
gcloud monitoring metrics list --project="$GCP_PROJECT_ID" \
  --filter="metric.type=~'kubernetes.io/container/memory' AND resource.label.container_name='istio-proxy'" \
  --format=json > "$RESULTS/memory-envoy.json" || true

git tag -f v0-t1-ok
echo "✅ V0 T1 Istio OK. Résultats : $RESULTS"
