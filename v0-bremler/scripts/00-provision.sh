#!/usr/bin/env bash
# V0 Bremler — provisioning cluster GKE + install Istio 1.22.6 + Cilium OSS 1.15.10
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../terraform"
source "$SCRIPT_DIR/../../.env"

echo "==> V0 provision — cluster ${CLUSTER_NAME_V0}"

# 1. Pré-flight
"$SCRIPT_DIR/../../tools/quota-check.sh"

# 2. Terraform
terraform init \
  -backend-config="bucket=${TF_BACKEND_BUCKET}" \
  -backend-config="prefix=${TF_BACKEND_PREFIX_V0}"

terraform plan -out=v0.plan
echo
read -rp "Continuer avec apply ? [y/N] " ans
[[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "Annulé."; exit 1; }
terraform apply -auto-approve v0.plan

# 3. kubectl context
gcloud container clusters get-credentials "$CLUSTER_NAME_V0" \
  --zone="$GCP_ZONE" --project="$GCP_PROJECT_ID"

# 4. Namespace bendimu-sut
kubectl create namespace bendimu-sut --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace bendimu-load --dry-run=client -o yaml | kubectl apply -f -

# 5. Cilium OSS 1.15.10 (via CLI, avec kubeProxyReplacement)
kubectl -n kube-system get ds cilium >/dev/null 2>&1 || {
  # Scale kube-proxy à zéro AVANT install Cilium (évite conflit — cf docs/05 §D2)
  kubectl -n kube-system patch daemonset kube-proxy \
    -p '{"spec":{"template":{"spec":{"nodeSelector":{"non-existing-label":"true"}}}}}' \
    || echo "kube-proxy déjà patché ou absent"

  cilium install --version "$V0_CILIUM_VERSION" \
    --set kubeProxyReplacement=true \
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

# 6. Istio 1.22.6 (istioctl-1.22)
which istioctl-1.22 >/dev/null || { echo "istioctl-1.22 absent, voir docs/00 §2.2"; exit 1; }
istioctl-1.22 install --set profile=default --skip-confirmation --readiness-timeout=5m
kubectl -n istio-system get pod

# 7. PodMonitoring GMP (déployé via monitoring module Terraform)
kubectl get podmonitoring -A

git tag -f v0-provisioned
echo "✅ V0 provision OK. Passer à 01-baseline.sh"
