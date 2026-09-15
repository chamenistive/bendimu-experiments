#!/usr/bin/env bash
# V1 Bendimu — cluster GKE + Istio 1.24.0 + Cilium OSS 1.16.5
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../terraform"
source "$SCRIPT_DIR/../../.env"

echo "==> V1 provision — cluster ${CLUSTER_NAME_V1}"

# 0. Auth pre-check (évite silent fail quota-check + terraform)
gcloud auth print-access-token >/dev/null 2>&1 || {
  echo "❌ gcloud auth expiré. Relancer : gcloud auth login ${GCP_ACCOUNT}"
  exit 1
}
gcloud auth application-default print-access-token >/dev/null 2>&1 || {
  echo "❌ ADC expiré. Relancer : gcloud auth application-default login"
  exit 1
}
gcloud auth application-default set-quota-project "$GCP_PROJECT_ID" >/dev/null 2>&1 || true

"$SCRIPT_DIR/../../tools/quota-check.sh"

terraform init \
  -backend-config="bucket=${TF_BACKEND_BUCKET}" \
  -backend-config="prefix=${TF_BACKEND_PREFIX_V1}"

# 2a. Step 1 : cluster GKE seul (chicken-and-egg fix — pm_envoy monitoring référence ns)
terraform plan -target=module.gke -out=v1-gke.plan
echo
read -rp "Continuer avec apply cluster ? [y/N] " ans
ans_trim="${ans//[$'\r\n\t ']/}"
case "${ans_trim,,}" in
  y|yes) ;;
  *) echo "Annulé (réponse reçue : '$ans')."; exit 1 ;;
esac
terraform apply -auto-approve v1-gke.plan

gcloud container clusters get-credentials "$CLUSTER_NAME_V1" \
  --zone="$GCP_ZONE" --project="$GCP_PROJECT_ID"

# Namespaces AVANT full apply (pm_envoy dans monitoring référence bendimu-sut-v1)
kubectl create namespace bendimu-sut-v1 --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace bendimu-load  --dry-run=client -o yaml | kubectl apply -f -

# 2b. Step 2 : full apply (PodMonitoring + alert policy)
terraform apply -auto-approve

# Cilium OSS 1.16.5
kubectl -n kube-system get ds cilium >/dev/null 2>&1 || {
  kubectl -n kube-system patch daemonset kube-proxy \
    -p '{"spec":{"template":{"spec":{"nodeSelector":{"non-existing-label":"true"}}}}}' \
    || echo "kube-proxy déjà patché"

  cilium install --version "$V1_CILIUM_VERSION" \
    --set cluster.name="$CLUSTER_NAME_V1" \
    --set kubeProxyReplacement=true \
    --set socketLB.hostNamespaceOnly=true \
    --set image.useDigest=false \
    --set operator.image.useDigest=false \
    --set mtu=1450 \
    --set routingMode=tunnel \
    --set tunnelProtocol=vxlan \
    --set hubble.enabled=true \
    --set hubble.metrics.enabled='{dns,drop,tcp,flow,port-distribution,icmp,http}' \
    --set prometheus.enabled=true \
    --set operator.prometheus.enabled=true

  cilium status --wait --wait-duration 5m
}

# Istio 1.24.0
which istioctl-1.24 >/dev/null || { echo "istioctl-1.24 absent, voir docs/00 §2.2"; exit 1; }
istioctl-1.24 install --set profile=default --set components.cni.enabled=false --skip-confirmation --readiness-timeout=5m

# Telemetry filter (cardinality control — docs/05 §E4)
cat <<'EOF' | kubectl apply -f -
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: reduce-cardinality
  namespace: istio-system
spec:
  metrics:
    - providers: [{ name: prometheus }]
      overrides:
        - match: { metric: ALL_METRICS }
          tagOverrides:
            source_workload_namespace:      { operation: REMOVE }
            destination_workload_namespace: { operation: REMOVE }
            request_protocol:               { operation: REMOVE }
            response_flags:                 { operation: REMOVE }
EOF

git tag -f v1-provisioned
echo "✅ V1 provision OK. Passer à 01-t0-baseline-reseau.sh"
