#!/usr/bin/env bash
# V1 T3 — Cilium eBPF + mutual auth sur SUT V1 PSD2
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../.env"
RESULTS="$SCRIPT_DIR/../results/t3-cilium-mtls"
mkdir -p "$RESULTS"

echo "==> V1 T3 Cilium eBPF + mutual auth (SUT V1 PSD2)"

# 1. Retirer Istio
kubectl label namespace bendimu-sut-v1 istio-injection- --overwrite || true
kubectl label namespace bendimu-load   istio-injection- --overwrite || true
kubectl -n bendimu-sut-v1 rollout restart deployment/sut-v1
kubectl -n bendimu-load   rollout restart ds/fortio
kubectl -n bendimu-sut-v1 rollout status deployment/sut-v1 --timeout=180s
kubectl -n bendimu-load   rollout status ds/fortio --timeout=120s
kubectl delete peerauthentication default -n bendimu-sut-v1 --ignore-not-found

# 2. Cilium mutual auth
cilium config set enable-mutual-auth true
kubectl -n kube-system rollout restart daemonset/cilium
kubectl -n kube-system rollout status daemonset/cilium --timeout=300s

# 3. CiliumNetworkPolicy L7 PSD2 + auth
cat <<'EOF' | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: sut-v1-l7-auth
  namespace: bendimu-sut-v1
spec:
  endpointSelector:
    matchLabels: { app: sut-v1 }
  ingress:
    - authentication: { mode: "required" }
      fromEndpoints:
        - matchLabels:
            "k8s:io.kubernetes.pod.namespace": bendimu-load
      toPorts:
        - ports: [{ port: "8080", protocol: TCP }]
          rules:
            http:
              - method: "GET",  path: "/aisp/accounts"
              - method: "POST", path: "/pisp/authorize"
              - method: "POST", path: "/pisp/execute"
              - method: "GET",  path: "/healthz"
EOF

sleep 15
cilium hubble observe --last 20 --type l7 || true

# 4. Palier PSD2 60/30/10
FORTIO_POD=$(kubectl -n bendimu-load get pod -l app=fortio -o jsonpath='{.items[0].metadata.name}')
SUT="http://sut-v1.bendimu-sut-v1.svc.cluster.local:8080"

for total_rps in 100 500 1000 2000 4000 8000 12800; do
  aisp_rps=$((total_rps * 60 / 100))
  auth_rps=$((total_rps * 30 / 100))
  exec_rps=$((total_rps * 10 / 100))

  echo "→ total=${total_rps} RPS"
  kubectl -n bendimu-load exec "$FORTIO_POD" -- fortio load \
    -qps "$aisp_rps" -c 128 -t 120s -nocatchup -jitter -uniform \
    -json - "$SUT/aisp/accounts" > "$RESULTS/aisp-${total_rps}rps.json" 2>&1 &
  kubectl -n bendimu-load exec "$FORTIO_POD" -- fortio load \
    -qps "$auth_rps" -c 64 -t 120s -nocatchup -jitter -uniform \
    -method POST -json - "$SUT/pisp/authorize" > "$RESULTS/authorize-${total_rps}rps.json" 2>&1 &
  kubectl -n bendimu-load exec "$FORTIO_POD" -- fortio load \
    -qps "$exec_rps" -c 64 -t 120s -nocatchup -jitter -uniform \
    -method POST -json - "$SUT/pisp/execute" > "$RESULTS/execute-${total_rps}rps.json" 2>&1 &
  wait
  sleep 20
done

# 5. RSS cilium-agent
kubectl -n kube-system top pod -l k8s-app=cilium --no-headers > "$RESULTS/memory-cilium.txt" || true

git tag -f v1-t3-ok
echo "✅ V1 T3 Cilium mTLS OK. Résultats : $RESULTS"
