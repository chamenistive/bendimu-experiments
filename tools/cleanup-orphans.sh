#!/usr/bin/env bash
# tools/cleanup-orphans.sh — détecte + supprime ressources orphelines Bendimu
# --dry-run : liste seulement
# --yes     : supprime sans confirmation individuelle (dangereux)
set -euo pipefail

: "${GCP_PROJECT_ID:?GCP_PROJECT_ID non défini}"
: "${GCP_REGION:?GCP_REGION non défini}"

DRY_RUN=false
AUTO_YES=false
for arg in "$@"; do
  case $arg in
    --dry-run) DRY_RUN=true ;;
    --yes)     AUTO_YES=true ;;
    -h|--help) echo "usage: $0 [--dry-run] [--yes]"; exit 0 ;;
  esac
done

echo "🧹 Cleanup orphans — projet=${GCP_PROJECT_ID}"
$DRY_RUN && echo "   (mode dry-run, aucune suppression)"
echo

confirm() {
  local msg=$1
  $AUTO_YES && return 0
  read -rp "$msg [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

# 1. Clusters GKE avec label bendimu
echo "1. Clusters GKE Bendimu :"
mapfile -t clusters < <(gcloud container clusters list --project="$GCP_PROJECT_ID" \
  --filter="resourceLabels.bendimu=true" --format="value(name,zone)")
if [[ ${#clusters[@]} -eq 0 ]]; then
  echo "   ✅ Aucun cluster orphelin"
else
  for row in "${clusters[@]}"; do
    name=$(awk '{print $1}' <<<"$row")
    zone=$(awk '{print $2}' <<<"$row")
    echo "   ⚠️  $name ($zone)"
    if ! $DRY_RUN && confirm "     Delete cluster $name ?"; then
      gcloud container clusters delete "$name" --zone="$zone" --project="$GCP_PROJECT_ID" --quiet
    fi
  done
fi
echo

# 2. Node pools orphelins (déjà supprimés avec le cluster normalement)

# 3. Disques PD non attachés
echo "2. Disques PD non attachés (tag bendimu ou nom bendimu-*) :"
mapfile -t disks < <(gcloud compute disks list --project="$GCP_PROJECT_ID" \
  --filter="-users:* AND (name~'bendimu' OR labels.bendimu=true)" \
  --format="value(name,zone)")
if [[ ${#disks[@]} -eq 0 ]]; then
  echo "   ✅ Aucun disque orphelin"
else
  for row in "${disks[@]}"; do
    name=$(awk '{print $1}' <<<"$row")
    zone=$(awk '{print $2}' <<<"$row")
    echo "   ⚠️  $name ($zone)"
    if ! $DRY_RUN && confirm "     Delete disk $name ?"; then
      gcloud compute disks delete "$name" --zone="$zone" --project="$GCP_PROJECT_ID" --quiet
    fi
  done
fi
echo

# 4. IP externes réservées non utilisées
echo "3. IP externes réservées Bendimu, non utilisées :"
mapfile -t addrs < <(gcloud compute addresses list --project="$GCP_PROJECT_ID" \
  --filter="status=RESERVED AND (name~'bendimu' OR labels.bendimu=true)" \
  --format="value(name,region)")
if [[ ${#addrs[@]} -eq 0 ]]; then
  echo "   ✅ Aucune IP orpheline"
else
  for row in "${addrs[@]}"; do
    name=$(awk '{print $1}' <<<"$row")
    region=$(awk '{print $2}' <<<"$row")
    echo "   ⚠️  $name ($region)"
    if ! $DRY_RUN && confirm "     Delete address $name ?"; then
      gcloud compute addresses delete "$name" --region="$region" --project="$GCP_PROJECT_ID" --quiet
    fi
  done
fi
echo

# 5. LB forwarding rules
echo "4. LB forwarding rules Bendimu :"
mapfile -t fwds < <(gcloud compute forwarding-rules list --project="$GCP_PROJECT_ID" \
  --filter="name~'bendimu'" --format="value(name,region)")
if [[ ${#fwds[@]} -eq 0 ]]; then
  echo "   ✅ Aucune règle de forwarding orpheline"
else
  for row in "${fwds[@]}"; do
    name=$(awk '{print $1}' <<<"$row")
    region=$(awk '{print $2}' <<<"$row")
    echo "   ⚠️  $name ($region)"
    if ! $DRY_RUN && confirm "     Delete forwarding-rule $name ?"; then
      gcloud compute forwarding-rules delete "$name" --region="$region" --project="$GCP_PROJECT_ID" --quiet
    fi
  done
fi
echo

# 6. Ephemeral firewalls
echo "5. Firewalls Bendimu :"
gcloud compute firewall-rules list --project="$GCP_PROJECT_ID" \
  --filter="name~'bendimu' AND creationTimestamp<'-P1D'" \
  --format="table(name,direction,sourceRanges.list())"
echo

echo "✅ Scan terminé."
$DRY_RUN && echo "   Relancer sans --dry-run pour supprimer."
