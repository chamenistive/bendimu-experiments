#!/usr/bin/env bash
# tools/quota-check.sh — vérifie quotas critiques GCP avant terraform apply
# Exit 0 : tous quotas OK. Exit 1 : au moins un insuffisant.
set -euo pipefail

: "${GCP_PROJECT_ID:?GCP_PROJECT_ID non défini (source ../.env)}"
: "${GCP_REGION:?GCP_REGION non défini}"

REQUIRED_CPUS=40
# SSD_TOTAL_GB : besoin réel 450 GB (5×70 SUT + 2×50 load = 450). Quota 500 GB Free-Trial-upgraded suffit.
# Passer à 1000 UNIQUEMENT si campagne V2 étendue (Anthos SSD ou multi-region).
REQUIRED_SSD_GB=450
REQUIRED_ADDRESSES=5

echo "🔍 Vérification quotas GCP pour projet=${GCP_PROJECT_ID} region=${GCP_REGION}"
echo

status=0

check_region_quota() {
  local metric=$1 required=$2 label=$3
  local limit
  limit=$(gcloud compute regions describe "$GCP_REGION" \
    --project="$GCP_PROJECT_ID" \
    --format="value(quotas.filter(metric='$metric').extract(limit).flatten())" 2>/dev/null | head -1)
  if [[ -z "$limit" ]]; then
    echo "❓ $label : quota introuvable"
    return
  fi
  limit_int=${limit%.*}
  if (( limit_int < required )); then
    echo "❌ $label : $limit_int (requis ≥ $required)"
    status=1
  else
    echo "✅ $label : $limit_int"
  fi
}

check_region_quota "CPUS"             $REQUIRED_CPUS      "CPUS ($GCP_REGION)"
check_region_quota "SSD_TOTAL_GB"     $REQUIRED_SSD_GB    "SSD_TOTAL_GB ($GCP_REGION)"
check_region_quota "IN_USE_ADDRESSES" $REQUIRED_ADDRESSES "IN_USE_ADDRESSES ($GCP_REGION)"

echo
if [[ $status -ne 0 ]]; then
  echo "⚠️  Au moins un quota insuffisant. Demander augmentation :"
  echo "   Console GCP → IAM & Admin → Quotas → filtrer par région $GCP_REGION"
  echo "   Délai d'approbation : 24-48 h"
  exit 1
fi
echo "✅ Tous les quotas critiques OK. On peut lancer terraform apply."
