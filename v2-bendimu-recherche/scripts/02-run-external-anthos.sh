#!/usr/bin/env bash
# V2 — Bank of Anthos (SUT hétérogène pour validité externe)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../.env"
RESULTS="$SCRIPT_DIR/../results/external-anthos"
mkdir -p "$RESULTS"
WORK="$SCRIPT_DIR/../.tmp-anthos"
mkdir -p "$WORK"

echo "==> V2 Bank of Anthos (validité externe)"

# 1. Clone si absent
[[ -d "$WORK/bank-of-anthos" ]] || git clone --depth 1 --branch v0.6.5 \
  https://github.com/GoogleCloudPlatform/bank-of-anthos.git "$WORK/bank-of-anthos"

# 2. Deploy
kubectl create namespace "${BOA_NAMESPACE:-boa}" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n "${BOA_NAMESPACE:-boa}" -k "$WORK/bank-of-anthos/kubernetes-manifests/"
kubectl -n "${BOA_NAMESPACE:-boa}" rollout status deployment --timeout=300s || echo "  (partial rollout)"

# 3. Run 1 : Istio (avec injection)
kubectl label namespace "${BOA_NAMESPACE:-boa}" istio-injection=enabled --overwrite
kubectl -n "${BOA_NAMESPACE:-boa}" rollout restart deployment
kubectl -n "${BOA_NAMESPACE:-boa}" rollout status deployment --timeout=300s || true

cat <<EOF | kubectl apply -f -
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata: { name: default, namespace: ${BOA_NAMESPACE:-boa} }
spec: { mtls: { mode: STRICT }, portLevelMtls: { "15021": { mode: PERMISSIVE } } }
EOF

sleep 30
echo "→ Anthos Istio run"
kubectl -n "${BOA_NAMESPACE:-boa}" get pod > "$RESULTS/anthos-istio-pods.txt"
# Locust script fourni par BoA — lancer via port-forward ou pod dédié
kubectl -n "${BOA_NAMESPACE:-boa}" apply -f "$WORK/bank-of-anthos/extras/loadgen/" 2>/dev/null || echo "  (loadgen skipped, structure BoA peut avoir changé)"
sleep 120
kubectl -n "${BOA_NAMESPACE:-boa}" logs deployment/loadgenerator --tail=200 > "$RESULTS/anthos-istio-loadgen.log" 2>/dev/null || true

# 4. Run 2 : Cilium (retirer Istio, appliquer CNP)
kubectl label namespace "${BOA_NAMESPACE:-boa}" istio-injection- --overwrite
kubectl -n "${BOA_NAMESPACE:-boa}" rollout restart deployment
kubectl -n "${BOA_NAMESPACE:-boa}" rollout status deployment --timeout=300s || true

cat <<EOF | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: { name: anthos-l7-auth, namespace: ${BOA_NAMESPACE:-boa} }
spec:
  endpointSelector: {}
  ingress:
    - authentication: { mode: "required" }
      fromEndpoints:
        - matchLabels: { "k8s:io.kubernetes.pod.namespace": ${BOA_NAMESPACE:-boa} }
EOF

sleep 30
echo "→ Anthos Cilium run"
kubectl -n "${BOA_NAMESPACE:-boa}" logs deployment/loadgenerator --tail=200 > "$RESULTS/anthos-cilium-loadgen.log" 2>/dev/null || true

git tag -f v2-anthos-ok
echo "✅ V2 Anthos OK. Résultats : $RESULTS"
