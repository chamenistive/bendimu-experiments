#!/usr/bin/env bash
# V2 destroy — cleanup mesh + terraform destroy multi-cluster + orphelins
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../.env"
cd "$SCRIPT_DIR/../terraform"

echo "==> V2 destroy — cluster ${CLUSTER_NAME_V2} (+ clusters cross-region si présents)"

kubectl get ns istio-system >/dev/null 2>&1 && istioctl-1.24 uninstall --purge -y || true
kubectl delete ns istio-system --ignore-not-found

kubectl -n kube-system get ds cilium >/dev/null 2>&1 && cilium uninstall || true

kubectl delete ns bendimu-sut-v1 bendimu-load boa --ignore-not-found

terraform destroy -auto-approve

"$SCRIPT_DIR/../../tools/cleanup-orphans.sh" --dry-run | tee "$SCRIPT_DIR/../results/teardown-v2.log"

# Purge Artifact Registry tags temporaires (> 30 jours)
gcloud artifacts docker images list \
  "${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT_ID}/bendimu-images/sut-v1" \
  --format="value(digest,createTime)" 2>/dev/null | \
  awk -v cutoff="$(date -u -d '30 days ago' +%Y-%m-%d)" '$2 < cutoff {print $1}' | \
  while read digest; do
    gcloud artifacts docker images delete \
      "${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT_ID}/bendimu-images/sut-v1@${digest}" \
      --quiet --delete-tags 2>/dev/null || true
  done

git tag -f v2-destroyed
echo "✅ V2 destroy OK."
