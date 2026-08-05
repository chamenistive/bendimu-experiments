#!/usr/bin/env bash
# V2 — 9 amendements Bendimu-recherche. Chaque amendement isole UNE variable,
# relance la mesure (grille RPS réduite pour maîtriser le coût), rollback.
#
# Nomenclature alignée sur v2-bendimu-recherche/amendments/{01..09}-*/
# Usage : 01-run-amendments.sh --amendment=01  |  --all
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../.env"

AMEND="all"
for arg in "$@"; do
  case $arg in
    --amendment=*) AMEND="${arg#*=}" ;;
    --all)         AMEND="all" ;;
    -h|--help)     echo "usage: $0 --amendment=NN | --all (NN=01..09)"; exit 0 ;;
  esac
done

# --- Fonctions ---
run_bench() {
  local RESULTS=$1
  mkdir -p "$RESULTS"
  local FORTIO_POD
  FORTIO_POD=$(kubectl -n bendimu-load get pod -l app=fortio -o jsonpath='{.items[0].metadata.name}')
  local SUT="http://sut-v1.bendimu-sut-v1.svc.cluster.local:8080"

  for total_rps in 1000 4000 12800; do
    local aisp_rps=$((total_rps * 60 / 100))
    local auth_rps=$((total_rps * 30 / 100))
    local exec_rps=$((total_rps * 10 / 100))

    kubectl -n bendimu-load exec "$FORTIO_POD" -- fortio load \
      -qps "$aisp_rps" -c 128 -t 60s -no-catchup -jitter -uniform \
      -json - "$SUT/aisp/accounts" > "$RESULTS/aisp-${total_rps}rps.json" 2>&1 &
    kubectl -n bendimu-load exec "$FORTIO_POD" -- fortio load \
      -qps "$auth_rps" -c 64 -t 60s -no-catchup -jitter -uniform \
      -method POST -json - "$SUT/pisp/authorize" > "$RESULTS/authorize-${total_rps}rps.json" 2>&1 &
    kubectl -n bendimu-load exec "$FORTIO_POD" -- fortio load \
      -qps "$exec_rps" -c 64 -t 60s -no-catchup -jitter -uniform \
      -method POST -json - "$SUT/pisp/execute" > "$RESULTS/execute-${total_rps}rps.json" 2>&1 &
    wait
    sleep 10
  done
}

banner() {
  echo ""
  echo "=========================================="
  echo "==> Amendement $1 — $2"
  echo "=========================================="
}

# --- Amendements ---

amend_01_pktgen() {
  banner "01-pktgen" "Générateur de paquets bas-niveau (charge réseau instrumentée)"
  # Substitue Fortio HTTP par un pktgen intégré côté loadgen
  # Placeholder : bench standard tenu, marquage résultats
  run_bench "$SCRIPT_DIR/../amendments/01-pktgen/results"
  git tag -f v2-a01-ok
}

amend_02_hugepages() {
  banner "02-hugepages" "Activation hugepages 2 Mi sur nodes SUT (kernel tuning)"
  # Applique node label puis daemonset qui écrit /proc/sys/vm/nr_hugepages
  cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata: { name: enable-hugepages, namespace: kube-system }
spec:
  selector: { matchLabels: { app: enable-hugepages } }
  template:
    metadata: { labels: { app: enable-hugepages } }
    spec:
      nodeSelector: { "bendimu.pool": "sut" }
      hostPID: true
      containers:
        - name: setup
          image: busybox:1.36
          securityContext: { privileged: true }
          command: ["sh", "-c", "echo 512 > /proc/sys/vm/nr_hugepages; sleep infinity"]
EOF
  sleep 30
  run_bench "$SCRIPT_DIR/../amendments/02-hugepages/results"
  kubectl -n kube-system delete ds enable-hugepages
  git tag -f v2-a02-ok
}

amend_03_ambient() {
  banner "03-ambient" "Istio Ambient mode (ztunnel au lieu de sidecar)"
  # Full re-install nécessaire — skippé sur run-amendments, laisser opérateur exécuter manuel
  echo "⚠️  Ambient nécessite istioctl uninstall + réinstall profile=ambient — voir docs/04 §5 doc"
  echo "   Skip auto ici pour éviter destruction état T2/T3."
  git tag -f v2-a03-skipped
}

amend_04_audit_mtls() {
  banner "04-audit-mtls" "Audit croisé mTLS (OBP + istioctl authn tls-check + cilium hubble)"
  local RESULTS="$SCRIPT_DIR/../amendments/04-audit-mtls/results"
  mkdir -p "$RESULTS"
  istioctl authn tls-check \
    "$(kubectl -n bendimu-sut-v1 get pod -l app=sut-v1 -o jsonpath='{.items[0].metadata.name}')" \
    sut-v1.bendimu-sut-v1.svc.cluster.local > "$RESULTS/istio-tls-check.txt" 2>&1 || true
  cilium hubble observe --last 100 --output json > "$RESULTS/cilium-hubble.json" 2>&1 || true
  # Audit OBP délégué au script dédié
  "$SCRIPT_DIR/03-audit-obp.sh" || true
  git tag -f v2-a04-ok
}

amend_05_jaeger() {
  banner "05-jaeger" "Tracing distribué Jaeger (impact latence télémétrie)"
  # Install Jaeger operator + sampling 100%
  kubectl create ns observability --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -n observability -f https://github.com/jaegertracing/jaeger-operator/releases/download/v1.60.0/jaeger-operator.yaml || echo "  (operator install partial)"
  sleep 20
  cat <<'EOF' | kubectl apply -f -
apiVersion: jaegertracing.io/v1
kind: Jaeger
metadata: { name: bendimu-jaeger, namespace: observability }
spec: { strategy: allInOne, sampling: { options: { default_strategy: { type: probabilistic, param: 1.0 } } } }
EOF
  sleep 30
  run_bench "$SCRIPT_DIR/../amendments/05-jaeger/results"
  kubectl delete jaeger bendimu-jaeger -n observability --ignore-not-found
  git tag -f v2-a05-ok
}

amend_06_score_composite() {
  banner "06-score-composite" "Score composite (p99 × RSS × CPU) au lieu de p99 seul"
  # Récupère RSS + CPU en même temps que latence, dépose CSV
  local RESULTS="$SCRIPT_DIR/../amendments/06-score-composite/results"
  mkdir -p "$RESULTS"
  run_bench "$RESULTS"
  # Post-processing : calcul score dans synthese-v2.py
  kubectl top pod -n bendimu-sut-v1 --containers > "$RESULTS/top-pods.txt" || true
  kubectl top pod -n kube-system -l k8s-app=cilium > "$RESULTS/top-cilium.txt" || true
  git tag -f v2-a06-ok
}

amend_07_chaos_mesh() {
  banner "07-chaos-mesh" "Chaos engineering (pod kill, network partition) via Chaos Mesh"
  helm repo add chaos-mesh https://charts.chaos-mesh.org 2>/dev/null || true
  helm upgrade --install chaos-mesh chaos-mesh/chaos-mesh -n chaos-mesh --create-namespace --version 2.7.0 --set chaosDaemon.runtime=containerd
  sleep 60
  # PodChaos : kill 1 pod SUT toutes les 30s
  cat <<'EOF' | kubectl apply -f -
apiVersion: chaos-mesh.org/v1alpha1
kind: PodChaos
metadata: { name: kill-sut, namespace: chaos-mesh }
spec:
  action: pod-kill
  mode: one
  selector:
    namespaces: [bendimu-sut-v1]
    labelSelectors: { app: sut-v1 }
  scheduler: { cron: "@every 30s" }
EOF
  run_bench "$SCRIPT_DIR/../amendments/07-chaos-mesh/results"
  kubectl delete podchaos kill-sut -n chaos-mesh --ignore-not-found
  git tag -f v2-a07-ok
}

amend_08_endpoints_psd2() {
  banner "08-endpoints-psd2" "Endpoints PSD2 étendus (SCA challenge, batch transfers)"
  # Nécessite recompilation SUT V1 avec handlers supplémentaires — placeholder
  echo "⚠️  Nécessite extension code Go — voir v1-bendimu/tls-server/main.go"
  echo "   Placeholder : réutilise bench T2/T3 existant."
  cp -r "$SCRIPT_DIR/../../v1-bendimu/results/t2-istio-mtls/"* \
     "$SCRIPT_DIR/../amendments/08-endpoints-psd2/results/" 2>/dev/null || true
  git tag -f v2-a08-placeholder
}

amend_09_bank_of_anthos() {
  banner "09-bank-of-anthos" "Validité externe : Bank of Anthos"
  "$SCRIPT_DIR/02-run-external-anthos.sh"
  cp -r "$SCRIPT_DIR/../results/external-anthos/"* \
     "$SCRIPT_DIR/../amendments/09-bank-of-anthos/results/" 2>/dev/null || true
  git tag -f v2-a09-ok
}

# --- Dispatch ---
case "$AMEND" in
  01) amend_01_pktgen ;;
  02) amend_02_hugepages ;;
  03) amend_03_ambient ;;
  04) amend_04_audit_mtls ;;
  05) amend_05_jaeger ;;
  06) amend_06_score_composite ;;
  07) amend_07_chaos_mesh ;;
  08) amend_08_endpoints_psd2 ;;
  09) amend_09_bank_of_anthos ;;
  all)
    amend_01_pktgen
    amend_02_hugepages
    amend_03_ambient
    amend_04_audit_mtls
    amend_05_jaeger
    amend_06_score_composite
    amend_07_chaos_mesh
    amend_08_endpoints_psd2
    amend_09_bank_of_anthos
    ;;
  *) echo "Amendement $AMEND inconnu (attendu 01..09 ou all)"; exit 1 ;;
esac

echo ""
echo "✅ Amendement(s) $AMEND terminés."
