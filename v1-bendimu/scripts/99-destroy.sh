#!/usr/bin/env bash
# V1 destroy — cleanup mesh + terraform destroy + orphelins
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../.env"
cd "$SCRIPT_DIR/../terraform"

echo "==> V1 destroy — cluster ${CLUSTER_NAME_V1}"

kubectl get ns istio-system >/dev/null 2>&1 && istioctl-1.24 uninstall --purge -y || true
kubectl delete ns istio-system --ignore-not-found

kubectl -n kube-system get ds cilium >/dev/null 2>&1 && cilium uninstall || true

kubectl delete ns bendimu-sut-v1 bendimu-load --ignore-not-found

terraform destroy -auto-approve

"$SCRIPT_DIR/../../tools/cleanup-orphans.sh" --dry-run | tee "$SCRIPT_DIR/../results/teardown-v1.log"

git tag -f v1-destroyed
echo "✅ V1 destroy OK."
