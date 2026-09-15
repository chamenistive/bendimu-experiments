#!/usr/bin/env bash
# V1 T4 — stress convergent SÉQUENTIEL sur cluster unique.
# T4a: DPA-1 Istio stress 3× charge (~38 400 RPS)
# → uninstall Istio complet → idle 5 min →
# T4b: DPA-3 Cilium stress 3× charge (~38 400 RPS)
#
# Justification séquentiel (vs 2 clusters simultanés):
# - Fidélité méthodologique Bremler-Barr 2024 §4 (uninstall/reinstall même cluster)
# - Élimine variance hardware/zone GCP inter-cluster
# - Réduit quota SSD requis (450 GB au lieu de 900 GB)
# - Coût divisé par 2 (~4 USD au lieu de ~8 USD)
#
# OPTIONNEL, non requis pour H1/H2 (T2 + T3 suffisent).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../.env"

RESULTS_A="$SCRIPT_DIR/../results/t4a-stress-istio"
RESULTS_B="$SCRIPT_DIR/../results/t4b-stress-cilium"
mkdir -p "$RESULTS_A" "$RESULTS_B"

echo "==> V1 T4 stress convergent SÉQUENTIEL (Istio → Cilium, même cluster)"
read -rp "Coût ~4 USD, durée ~90 min, non requis pour H1/H2. Continuer ? [y/N] " ans
[[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "Skip."; exit 0; }

# --- Retrieve JSON avec retry 3× backoff (fix E16) ---
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

# --- Fonction bench (fix E14-E16 : helper sidecar + retry) ---
run_stress_bench() {
  local RESULTS=$1
  local LABEL=$2
  local FORTIO_POD
  FORTIO_POD=$(kubectl -n bendimu-load get pod -l app=fortio -o jsonpath='{.items[0].metadata.name}')
  local SUT="http://sut-v1.bendimu-sut-v1.svc.cluster.local:8080"

  echo ""
  echo "==> Bench stress ${LABEL}"
  for total_rps in 12800 25600 38400; do
    local aisp_rps=$((total_rps * 60 / 100))
    local auth_rps=$((total_rps * 30 / 100))
    local exec_rps=$((total_rps * 10 / 100))

    echo "  → total=${total_rps} RPS (aisp=${aisp_rps}, auth=${auth_rps}, exec=${exec_rps})"

    kubectl -n bendimu-load exec "$FORTIO_POD" -c helper -- \
      rm -f /tmp/aisp.json /tmp/authorize.json /tmp/execute.json 2>/dev/null || true

    kubectl -n bendimu-load exec "$FORTIO_POD" -c fortio -- fortio load \
      -qps "$aisp_rps" -c 256 -t 180s -nocatchup -jitter -uniform -httpbufferkb 2048 -quiet \
      -json /tmp/aisp.json "$SUT/aisp/accounts" >/dev/null 2>&1 &
    local PID_AISP=$!
    kubectl -n bendimu-load exec "$FORTIO_POD" -c fortio -- fortio load \
      -qps "$auth_rps" -c 128 -t 180s -nocatchup -jitter -uniform -httpbufferkb 2048 -quiet \
      -X POST -json /tmp/authorize.json "$SUT/pisp/authorize" >/dev/null 2>&1 &
    local PID_AUTH=$!
    kubectl -n bendimu-load exec "$FORTIO_POD" -c fortio -- fortio load \
      -qps "$exec_rps" -c 128 -t 180s -nocatchup -jitter -uniform -httpbufferkb 2048 -quiet \
      -X POST -json /tmp/execute.json "$SUT/pisp/execute" >/dev/null 2>&1 &
    local PID_EXEC=$!
    wait $PID_AISP $PID_AUTH $PID_EXEC || true

    retrieve_json "$FORTIO_POD" /tmp/aisp.json      "$RESULTS/aisp-${total_rps}rps.json"      || true
    retrieve_json "$FORTIO_POD" /tmp/authorize.json "$RESULTS/authorize-${total_rps}rps.json" || true
    retrieve_json "$FORTIO_POD" /tmp/execute.json   "$RESULTS/execute-${total_rps}rps.json"   || true

    sleep 30
  done

  kubectl top nodes > "$RESULTS/nodes-cpu.txt" || true
  kubectl -n bendimu-sut-v1 get events --field-selector reason=OOMKilling > "$RESULTS/oom-events.txt" || true
  kubectl top pod -n bendimu-sut-v1 --containers > "$RESULTS/pods-mem.txt" || true
}

# --- Vérif préalable: cluster en état T2 (Istio installé, mTLS STRICT) ---
if ! istioctl-1.24 version 2>/dev/null | grep -q "control plane"; then
  echo "❌ Istio absent. Lance d'abord ./03-t2-istio-mtls.sh (état T2 requis en entrée)."
  exit 1
fi

# --- T4a: STRESS DPA-1 (Istio) ---
echo ""
echo "=========================================="
echo "==> T4a — Stress DPA-1 (Istio sidecar)"
echo "=========================================="
run_stress_bench "$RESULTS_A" "T4a Istio"
git tag -f v1-t4a-ok
echo "✅ T4a Istio terminé. Résultats : $RESULTS_A"

# --- Transition: uninstall complet Istio ---
echo ""
echo "==> Uninstall Istio complet + rollout SUT..."
istioctl-1.24 uninstall --purge -y
kubectl delete namespace istio-system --wait=true --ignore-not-found
kubectl label namespace bendimu-sut-v1 istio-injection- --overwrite || true
kubectl -n bendimu-sut-v1 rollout restart deployment/sut-v1
kubectl -n bendimu-sut-v1 rollout status deployment/sut-v1 --timeout=180s

# Vérif zéro sidecar restant
REMAINING=$(kubectl get pods -A -o json | jq -r '.items[] | select(.spec.containers[]?.name == "istio-proxy") | .metadata.name' | wc -l)
if [ "$REMAINING" -gt 0 ]; then
  echo "❌ Sidecars Envoy résiduels ($REMAINING). Abort avant contamination T4b."
  exit 1
fi
echo "✅ Uninstall Istio propre (0 sidecar restant)."

# --- Idle 5 min (clear cache kernel + eBPF prep) ---
echo ""
echo "==> Idle 5 min avant install Cilium (clear caches, stabilisation)..."
sleep 300

# --- Install Cilium sur MÊME cluster ---
echo ""
echo "==> Install Cilium ${V1_CILIUM_VERSION} + mutual auth..."
cilium install --version "${V1_CILIUM_VERSION}" \
  --set cluster.name="$CLUSTER_NAME_V1" \
  --set kubeProxyReplacement=true \
  --set socketLB.hostNamespaceOnly=true \
  --set endpointRoutes.enabled=true \
  --set authentication.mutual.spire.enabled=true \
  --set authentication.mutual.spire.install.enabled=true \
  --set encryption.enabled=false
cilium status --wait --wait-duration=300s

# Fix E18 : patcher DS spire-agent avec tolération pool load
kubectl -n cilium-spire patch daemonset spire-agent --type=json -p='[
  {"op":"add","path":"/spec/template/spec/tolerations","value":[
    {"key":"bendimu.role","operator":"Equal","value":"load","effect":"NoSchedule"}
  ]}
]' 2>/dev/null || true
kubectl -n cilium-spire rollout status daemonset/spire-agent --timeout=180s 2>/dev/null || true

# Applique CiliumNetworkPolicy L7 + mTLS required
kubectl apply -f - <<'EOF'
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: sut-v1-mtls
  namespace: bendimu-sut-v1
spec:
  endpointSelector:
    matchLabels:
      app: sut-v1
  ingress:
    - fromEndpoints:
        - matchLabels:
            "k8s:io.kubernetes.pod.namespace": bendimu-load
      authentication:
        mode: required
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
EOF

kubectl -n bendimu-sut-v1 rollout restart deployment/sut-v1
kubectl -n bendimu-sut-v1 rollout status deployment/sut-v1 --timeout=180s

# Vérif eBPF programs chargés (fix E20 : --verbose retiré CLI 0.16.x)
cilium status > "$RESULTS_B/cilium-status.txt" || true
kubectl -n kube-system get ds cilium -o jsonpath='{.status}' >> "$RESULTS_B/cilium-status.txt" 2>/dev/null || true

# --- Idle 5 min (warmup post-install) ---
echo ""
echo "==> Idle 5 min post-install Cilium (warmup eBPF maps, stabilisation)..."
sleep 300

# --- T4b: STRESS DPA-3 (Cilium) ---
echo ""
echo "=========================================="
echo "==> T4b — Stress DPA-3 (Cilium eBPF)"
echo "=========================================="
run_stress_bench "$RESULTS_B" "T4b Cilium"
git tag -f v1-t4b-ok
echo "✅ T4b Cilium terminé. Résultats : $RESULTS_B"

# --- Tag global ---
git tag -f v1-t4-ok
echo ""
echo "=========================================="
echo "✅ V1 T4 séquentiel complet."
echo "  - T4a Istio  : $RESULTS_A"
echo "  - T4b Cilium : $RESULTS_B"
echo "  - Comparaison p99 sous stress → 06-synthese-h1-h2.py"
echo "=========================================="
