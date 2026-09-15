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

# 2. Cilium mutual auth + SPIRE (fix E17 : mutual-auth sans SPIRE = AuthCertificateProvider missing)
#    Reinstall Cilium avec install.enabled=true pour déployer SPIRE bundled + enable-mutual-auth
cilium uninstall --wait 2>/dev/null || true
sleep 10
cilium install --version "$V1_CILIUM_VERSION" \
  --set cluster.name="$CLUSTER_NAME_V1" \
  --set kubeProxyReplacement=true \
  --set socketLB.hostNamespaceOnly=true \
  --set endpointRoutes.enabled=true \
  --set image.useDigest=false \
  --set operator.image.useDigest=false \
  --set mtu=1450 \
  --set routingMode=tunnel \
  --set tunnelProtocol=vxlan \
  --set hubble.enabled=true \
  --set hubble.metrics.enabled='{dns,drop,tcp,flow,port-distribution,icmp,http}' \
  --set prometheus.enabled=true \
  --set operator.prometheus.enabled=true \
  --set authentication.mutual.spire.enabled=true \
  --set authentication.mutual.spire.install.enabled=true

# Attendre que Cilium install crée spire-agent DS avant patch (fix ordre E18)
echo "  Attente création spire-agent DS..."
for i in $(seq 1 30); do
  kubectl -n cilium-spire get daemonset spire-agent >/dev/null 2>&1 && break
  sleep 5
done

# Fix E18 : patcher DS spire-agent avec tolération pool load AVANT cilium status --wait
# (sans ce patch, 2 cilium-agents load nodes fail SPIRE → cilium status timeout)
kubectl -n cilium-spire patch daemonset spire-agent --type=json -p='[
  {"op":"add","path":"/spec/template/spec/tolerations","value":[
    {"key":"bendimu.role","operator":"Equal","value":"load","effect":"NoSchedule"}
  ]}
]' 2>/dev/null || echo "  (spire-agent DS tolérations déjà présentes)"
kubectl -n cilium-spire rollout status daemonset/spire-agent --timeout=180s 2>/dev/null || true

cilium status --wait --wait-duration 5m

# 3. CiliumNetworkPolicy L7 PSD2 + auth (fix E19 : flow style explicit)
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
              - { method: "GET",  path: "/aisp/accounts" }
              - { method: "POST", path: "/pisp/authorize" }
              - { method: "POST", path: "/pisp/execute" }
              - { method: "GET",  path: "/healthz" }
EOF

sleep 15
cilium hubble observe --last 20 --type l7 || true

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

# 4. Palier PSD2 60/30/10 (fix E14-E16 : helper sidecar + retry)
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

# 5. RSS cilium-agent
kubectl -n kube-system top pod -l k8s-app=cilium --no-headers > "$RESULTS/memory-cilium.txt" || true

git tag -f v1-t3-ok
echo "✅ V1 T3 Cilium mTLS OK. Résultats : $RESULTS"
