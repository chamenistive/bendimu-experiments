#!/usr/bin/env bash
# tools/budget-check.sh — coût actuel du mois + prévision + top postes
set -euo pipefail

: "${GCP_PROJECT_ID:?GCP_PROJECT_ID non défini}"
: "${GCP_BILLING_ACCOUNT:?GCP_BILLING_ACCOUNT non défini}"

MONTH_START=$(date -u +"%Y-%m-01T00:00:00Z")
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "📊 Bilan facturation Bendimu — projet=${GCP_PROJECT_ID}"
echo "   Période : $MONTH_START → $NOW"
echo

# Requiert Cloud Billing BigQuery export (recommandé) — fallback si absent :
BQ_DATASET="${BQ_BILLING_DATASET:-billing_export}"
BQ_TABLE="${BQ_BILLING_TABLE:-gcp_billing_export_v1_${GCP_BILLING_ACCOUNT//-/_}}"

if command -v bq >/dev/null 2>&1 && bq ls "$BQ_DATASET" >/dev/null 2>&1; then
  echo "→ Source : BigQuery export ($BQ_DATASET.$BQ_TABLE)"
  bq query --nouse_legacy_sql --format=pretty "
    SELECT
      service.description AS service,
      ROUND(SUM(cost), 2) AS cost_usd,
      currency
    FROM \`${GCP_PROJECT_ID}.${BQ_DATASET}.${BQ_TABLE}\`
    WHERE usage_start_time >= TIMESTAMP('$MONTH_START')
      AND project.id = '$GCP_PROJECT_ID'
    GROUP BY service, currency
    ORDER BY cost_usd DESC
    LIMIT 10
  "
  TOTAL=$(bq query --nouse_legacy_sql --format=csv --quiet "
    SELECT ROUND(SUM(cost), 2) FROM \`${GCP_PROJECT_ID}.${BQ_DATASET}.${BQ_TABLE}\`
    WHERE usage_start_time >= TIMESTAMP('$MONTH_START')
      AND project.id = '$GCP_PROJECT_ID'
  " | tail -1)
  echo
  echo "💰 Total mois : ${TOTAL} USD"
else
  echo "⚠️  BigQuery billing export non configuré."
  echo "   Consulter Console → Billing → Cost table pour bilan détaillé."
  echo
  echo "→ Fallback : liste ressources potentiellement facturantes"
  echo
  echo "Clusters GKE actifs :"
  gcloud container clusters list --project="$GCP_PROJECT_ID" --format="table(name,zone,status,currentNodeCount)"
  echo
  echo "PD SSD en cours :"
  gcloud compute disks list --project="$GCP_PROJECT_ID" --format="table(name,sizeGb,type,zone)"
  echo
  echo "IP externes réservées :"
  gcloud compute addresses list --project="$GCP_PROJECT_ID" --format="table(name,region,status)"
  echo
  echo "LB forwarding rules :"
  gcloud compute forwarding-rules list --project="$GCP_PROJECT_ID" --format="table(name,region,target)"
fi
