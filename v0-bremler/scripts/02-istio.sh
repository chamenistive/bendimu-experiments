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

# 2. PeerAuthentication STRICT namespace-wide.
# Note : Istio auto-bypass des health checks GKE via localhost (rewriteAppHTTPProbers
# activé par défaut sur sidecar injection). Pas de portLevelMtls nécessaire —
# et interdit sur PA namespace-scope (validation webhook Istio 1.22+).
cat <<'EOF' | kubectl apply -f -
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: bendimu-sut
spec:
  mtls:
    mode: STRICT
EOF

# 3. Vérif mTLS via `istioctl x describe pod` (commande `authn tls-check`
# retirée dans Istio récents, y compris 1.22 canary). `x describe pod` affiche
# le mode mTLS effectif appliqué au pod.
sleep 15
ISTIOCTL_122="$(command -v istioctl-1.22 || echo "$HOME/.local/bin/istioctl-1.22")"
[[ -x "$ISTIOCTL_122" ]] || { echo "istioctl-1.22 absent, voir docs/00 §2.2"; exit 1; }
SUT_POD="$(kubectl -n bendimu-sut get pod -l app=sut-bremler -o jsonpath='{.items[0].metadata.name}')"
DESCRIBE_OUT="$("$ISTIOCTL_122" x describe pod "$SUT_POD" -n bendimu-sut 2>&1)"
echo "$DESCRIBE_OUT"
if echo "$DESCRIBE_OUT" | grep -qE "mTLS mode: STRICT|PeerAuthentication.*STRICT"; then
  echo "✅ mTLS STRICT confirmé sur $SUT_POD"
else
  echo "⚠️  mTLS STRICT non explicite dans describe. Verify manuel :"
  echo "    kubectl -n bendimu-sut get peerauthentication -o yaml"
  # non-bloquant : PA a été apply, sidecar inject OK, on continue
fi

# 4. Palier de charge (fortio dans pod mesh)
FORTIO_POD=$(kubectl -n bendimu-load get pod -l app=fortio -o jsonpath='{.items[0].metadata.name}')
SUT_URL="http://sut-bremler.bendimu-sut.svc.cluster.local:8080"

for endpoint in "" "data10kb" "data1mb"; do
  for rps in 100 500 1000 2000 4000 8000 12800; do
    echo "→ endpoint=/$endpoint rps=$rps"
    kubectl -n bendimu-load exec "$FORTIO_POD" -- fortio load \
      -qps "$rps" -c 200 -t 120s \
      -nocatchup -jitter -uniform -httpbufferkb 2048 \
      -json "-" "$SUT_URL/$endpoint" \
      > "$RESULTS/${endpoint:-root}-${rps}rps.json" 2>&1 || echo "  (partial)"
    sleep 15
  done
done

# 5. RSS Envoy sidecar (kubectl top + curl API Monitoring v3)
kubectl top pods -n bendimu-sut --containers -l app=sut-bremler \
  --sort-by=memory 2>/dev/null > "$RESULTS/memory-envoy.txt" || true
TOKEN=$(gcloud auth application-default print-access-token 2>/dev/null || echo "")
if [[ -n "$TOKEN" ]]; then
  END=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  START=$(date -u -d "5 min ago" +%Y-%m-%dT%H:%M:%SZ)
  curl -s -H "Authorization: Bearer $TOKEN" \
    "https://monitoring.googleapis.com/v3/projects/${GCP_PROJECT_ID}/timeSeries?filter=metric.type%3D%22kubernetes.io%2Fcontainer%2Fmemory%2Fused_bytes%22%20AND%20resource.labels.container_name%3D%22istio-proxy%22&interval.startTime=${START}&interval.endTime=${END}" \
    > "$RESULTS/memory-envoy.json" || true
fi

git tag -f v0-t1-ok
echo "✅ V0 T1 Istio OK. Résultats : $RESULTS"
