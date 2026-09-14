#!/usr/bin/env bash
# V0 Bremler — provisioning cluster GKE + install Istio 1.22.6 + Cilium OSS 1.16.3
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../terraform"
source "$SCRIPT_DIR/../../.env"

echo "==> V0 provision — cluster ${CLUSTER_NAME_V0}"

# 0. Auth pre-check : gcloud + ADC valides (évite silent fail sur quota-check et terraform)
gcloud auth print-access-token >/dev/null 2>&1 || {
  echo "❌ gcloud auth expiré. Relancer : gcloud auth login ${GCP_ACCOUNT}"
  exit 1
}
gcloud auth application-default print-access-token >/dev/null 2>&1 || {
  echo "❌ ADC expiré. Relancer : gcloud auth application-default login"
  exit 1
}
gcloud auth application-default set-quota-project "$GCP_PROJECT_ID" >/dev/null 2>&1 || true

# 1. Pré-flight quotas
"$SCRIPT_DIR/../../tools/quota-check.sh"

# 2. Terraform init
terraform init \
  -backend-config="bucket=${TF_BACKEND_BUCKET}" \
  -backend-config="prefix=${TF_BACKEND_PREFIX_V0}"

# 2a. Step 1 : cluster GKE seul (chicken-and-egg fix — kubernetes_manifest
#     pm_envoy dans module.monitoring nécessite cluster + namespace créés avant apply)
terraform plan -target=module.gke -out=v0-gke.plan
echo
read -rp "Continuer avec apply cluster ? [y/N] " ans
[[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "Annulé."; exit 1; }
terraform apply -auto-approve v0-gke.plan

# 3. kubectl context
gcloud container clusters get-credentials "$CLUSTER_NAME_V0" \
  --zone="$GCP_ZONE" --project="$GCP_PROJECT_ID"

# 4. Namespaces AVANT full apply (pm_envoy dans monitoring référence bendimu-sut)
kubectl create namespace bendimu-sut --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace bendimu-load --dry-run=client -o yaml | kubectl apply -f -

# 2b. Step 2 : full apply (PodMonitoring + alert policy + reorder cluster monitoring components)
terraform apply -auto-approve

# 5. Cilium OSS 1.16.3 (via CLI, avec kubeProxyReplacement)
kubectl -n kube-system get ds cilium >/dev/null 2>&1 || {
  # Scale kube-proxy à zéro AVANT install Cilium (évite conflit — cf docs/05 §D2)
  # GKE 1.35+ : kube-proxy DS souvent déjà 0/0 (node selector kube-proxy-ds-ready sans match)
  kubectl -n kube-system patch daemonset kube-proxy \
    -p '{"spec":{"template":{"spec":{"nodeSelector":{"non-existing-label":"true"}}}}}' \
    2>/dev/null || echo "kube-proxy déjà patché ou absent (normal GKE 1.35+)"

  # Override cluster.name : auto-détect GKE = gke-<project>-<zone>-<cluster> > 32 chars, refusé Cilium
  cilium install --version "$V0_CILIUM_VERSION" \
    --set cluster.name="$CLUSTER_NAME_V0" \
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
ISTIOCTL_122="$(command -v istioctl-1.22 || echo "$HOME/.local/bin/istioctl-1.22")"
[[ -x "$ISTIOCTL_122" ]] || { echo "istioctl-1.22 absent, voir docs/00 §2.2"; exit 1; }
"$ISTIOCTL_122" install --set profile=default --skip-confirmation --readiness-timeout=5m
kubectl -n istio-system get pod

# 7. PodMonitoring GMP (déployé via monitoring module Terraform)
kubectl get podmonitoring -A

git tag -f v0-provisioned
echo "✅ V0 provision OK. Passer à 01-baseline.sh"
