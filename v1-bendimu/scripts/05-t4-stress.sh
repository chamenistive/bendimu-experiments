#!/usr/bin/env bash
# V1 T4 — stress 3× charge nominale (~38 400 RPS) sur mesh actuel (Cilium après T3)
# OPTIONNEL, coût ~8 USD.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../.env"
RESULTS="$SCRIPT_DIR/../results/t4-stress"
mkdir -p "$RESULTS"

echo "==> V1 T4 stress convergent (optionnel)"
read -rp "Coût ~8 USD, non requis pour H1/H2. Continuer ? [y/N] " ans
[[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "Skip."; exit 0; }

FORTIO_POD=$(kubectl -n bendimu-load get pod -l app=fortio -o jsonpath='{.items[0].metadata.name}')
SUT="http://sut-v1.bendimu-sut-v1.svc.cluster.local:8080"

for total_rps in 12800 25600 38400; do
  aisp_rps=$((total_rps * 60 / 100))
  auth_rps=$((total_rps * 30 / 100))
  exec_rps=$((total_rps * 10 / 100))

  echo "→ STRESS total=${total_rps} RPS"
  kubectl -n bendimu-load exec "$FORTIO_POD" -- fortio load \
    -qps "$aisp_rps" -c 256 -t 180s -no-catchup -jitter -uniform \
    -json - "$SUT/aisp/accounts" > "$RESULTS/aisp-${total_rps}rps.json" 2>&1 &
  kubectl -n bendimu-load exec "$FORTIO_POD" -- fortio load \
    -qps "$auth_rps" -c 128 -t 180s -no-catchup -jitter -uniform \
    -method POST -json - "$SUT/pisp/authorize" > "$RESULTS/authorize-${total_rps}rps.json" 2>&1 &
  kubectl -n bendimu-load exec "$FORTIO_POD" -- fortio load \
    -qps "$exec_rps" -c 128 -t 180s -no-catchup -jitter -uniform \
    -method POST -json - "$SUT/pisp/execute" > "$RESULTS/execute-${total_rps}rps.json" 2>&1 &
  wait
  sleep 30
done

# Snapshot CPU/mémoire node + OOM events
kubectl top nodes > "$RESULTS/nodes-cpu.txt" || true
kubectl -n bendimu-sut-v1 get events --field-selector reason=OOMKilling > "$RESULTS/oom-events.txt" || true

git tag -f v1-t4-ok
echo "✅ V1 T4 stress OK. Résultats : $RESULTS"
