#!/usr/bin/env bash
# V2 Recherche — cluster GKE principal (+ clusters cross-region si A8 activé)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../terraform"
source "$SCRIPT_DIR/../../.env"

echo "==> V2 provision — cluster ${CLUSTER_NAME_V2}"

"$SCRIPT_DIR/../../tools/quota-check.sh"

terraform init \
  -backend-config="bucket=${TF_BACKEND_BUCKET}" \
  -backend-config="prefix=${TF_BACKEND_PREFIX_V2}"

terraform plan -out=v2.plan
read -rp "Continuer avec apply ? [y/N] " ans
[[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "Annulé."; exit 1; }
terraform apply -auto-approve v2.plan

gcloud container clusters get-credentials "$CLUSTER_NAME_V2" \
  --zone="$GCP_ZONE" --project="$GCP_PROJECT_ID"

kubectl create namespace bendimu-sut-v1 --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace bendimu-load  --dry-run=client -o yaml | kubectl apply -f -

# Cilium + Istio 1.24 identiques V1
kubectl -n kube-system get ds cilium >/dev/null 2>&1 || {
  kubectl -n kube-system patch daemonset kube-proxy \
    -p '{"spec":{"template":{"spec":{"nodeSelector":{"non-existing-label":"true"}}}}}' \
    || echo "kube-proxy déjà patché"

  cilium install --version "$V1_CILIUM_VERSION" \
    --set kubeProxyReplacement=true \
    --set image.useDigest=false \
    --set operator.image.useDigest=false \
    --set mtu=1450 --set routingMode=tunnel --set tunnelProtocol=vxlan \
    --set hubble.enabled=true --set prometheus.enabled=true

  cilium status --wait --wait-duration 5m
}

istioctl-1.24 install --set profile=default --skip-confirmation --readiness-timeout=5m

git tag -f v2-provisioned
echo "✅ V2 provision OK. Passer à 01-run-amendments.sh"
