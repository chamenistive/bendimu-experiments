#!/usr/bin/env bash
# V0 T3 Istio Ambient (ztunnel) — OPTIONNEL, non bloquant pour verdict V0
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../.env"
RESULTS="$SCRIPT_DIR/../results/t3-ambient"
mkdir -p "$RESULTS"

echo "==> V0 T3 Istio Ambient (extension optionnelle)"
read -rp "Ce run est optionnel (Bendimu se concentre DPA-1 vs DPA-3). Continuer ? [y/N] " ans
[[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "Skip."; exit 0; }

# 1. Cleanup état T2 (retirer CiliumNetworkPolicy L7)
kubectl -n bendimu-sut delete ciliumnetworkpolicy sut-bremler-l7-auth --ignore-not-found
cilium config set enable-mutual-auth false
kubectl -n kube-system rollout restart daemonset/cilium
kubectl -n kube-system rollout status daemonset/cilium --timeout=300s

# 2. Uninstall Istio actuel + réinstall profile ambient
istioctl-1.22 uninstall --purge -y || true
kubectl delete ns istio-system --ignore-not-found

istioctl-1.22 install --set profile=ambient --skip-confirmation --readiness-timeout=5m

# 3. Label namespace en mode ambient
kubectl label namespace bendimu-sut  istio.io/dataplane-mode=ambient --overwrite
kubectl label namespace bendimu-load istio.io/dataplane-mode=ambient --overwrite

# 4. Vérif ztunnel présent sur nodes
kubectl -n istio-system get ds ztunnel

# 5. Palier de charge
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

git tag -f v0-t3-ok
echo "✅ V0 T3 Ambient OK. Résultats : $RESULTS"
