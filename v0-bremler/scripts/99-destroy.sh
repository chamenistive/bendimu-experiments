#!/usr/bin/env bash
# V0 destroy — uninstall mesh + terraform destroy + vérif orphelins
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../.env"
cd "$SCRIPT_DIR/../terraform"

echo "==> V0 destroy — cluster ${CLUSTER_NAME_V0}"

# 1. Uninstall mesh (évite orphelins LB Google)
kubectl get ns istio-system >/dev/null 2>&1 && istioctl-1.22 uninstall --purge -y || true
kubectl get ns istio-system --ignore-not-found | grep -q istio-system && kubectl delete ns istio-system --ignore-not-found

kubectl -n kube-system get ds cilium >/dev/null 2>&1 && cilium uninstall || true

# 2. Namespaces applicatifs
kubectl delete ns bendimu-sut bendimu-load --ignore-not-found

# 3. Terraform destroy
terraform destroy -auto-approve

# 4. Vérif orphelins
"$SCRIPT_DIR/../../tools/cleanup-orphans.sh" --dry-run | tee "$SCRIPT_DIR/../results/teardown-v0.log"

git tag -f v0-destroyed
echo "✅ V0 destroy OK. Consulter results/teardown-v0.log."
