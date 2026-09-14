#!/usr/bin/env bash
# V0 T2 Cilium eBPF + mutual auth
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../.env"
RESULTS="$SCRIPT_DIR/../results/t2-cilium"
mkdir -p "$RESULTS"

echo "==> V0 T2 Cilium eBPF + mutual auth"

# 1. Retirer Istio (unlabel + rollout sans sidecar)
kubectl label namespace bendimu-sut  istio-injection- --overwrite || true
kubectl label namespace bendimu-load istio-injection- --overwrite || true
kubectl -n bendimu-sut  rollout restart deployment/sut-bremler
kubectl -n bendimu-load rollout restart ds/fortio
kubectl -n bendimu-sut  rollout status deployment/sut-bremler --timeout=180s
kubectl -n bendimu-load rollout status ds/fortio --timeout=120s
kubectl delete peerauthentication default -n bendimu-sut --ignore-not-found

# 2. Enable Cilium mutual auth
cilium config set enable-mutual-auth true
kubectl -n kube-system rollout restart daemonset/cilium
kubectl -n kube-system rollout status daemonset/cilium --timeout=300s

# 3. CiliumNetworkPolicy L7 + auth required
cat <<'EOF' | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: sut-bremler-l7-auth
  namespace: bendimu-sut
spec:
  endpointSelector:
    matchLabels: { app: sut-bremler }
  ingress:
    - authentication:
        mode: "required"
      fromEndpoints:
        - matchLabels:
            "k8s:io.kubernetes.pod.namespace": bendimu-load
      toPorts:
        - ports: [{ port: "8080", protocol: TCP }]
          rules:
            http:
              - method: "GET", path: "/"
              - method: "GET", path: "/data10kb"
              - method: "GET", path: "/data1mb"
EOF

# 4. Sanity check
sleep 15
cilium status --verbose | head -50
cilium hubble observe --last 20 --type l7 || true

# 5. Palier de charge
FORTIO_POD=$(kubectl -n bendimu-load get pod -l app=fortio -o jsonpath='{.items[0].metadata.name}')
SUT_URL="http://sut-bremler.bendimu-sut.svc.cluster.local:8080"

for endpoint in "" "data10kb" "data1mb"; do
  for rps in 100 500 1000 2000 4000 8000 12800; do
    echo "→ endpoint=/$endpoint rps=$rps"
    kubectl -n bendimu-load exec "$FORTIO_POD" -- rm -f /tmp/fortio-result.json 2>/dev/null || true
    kubectl -n bendimu-load exec "$FORTIO_POD" -- fortio load \
      -qps "$rps" -c 200 -t 120s \
      -nocatchup -jitter -uniform -httpbufferkb 2048 -quiet \
      -json /tmp/fortio-result.json \
      "$SUT_URL/$endpoint" >/dev/null 2>&1 || true
    kubectl -n bendimu-load exec "$FORTIO_POD" -- cat /tmp/fortio-result.json \
      > "$RESULTS/${endpoint:-root}-${rps}rps.json" 2>/dev/null || echo "  (partial)"
    sleep 15
  done
done

# 6. RSS cilium-agent
kubectl -n kube-system top pod -l k8s-app=cilium --no-headers > "$RESULTS/memory-cilium.txt" || true

git tag -f v0-t2-ok
echo "✅ V0 T2 Cilium OK. Résultats : $RESULTS"
