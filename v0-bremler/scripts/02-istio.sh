#!/usr/bin/env bash
# V0 T1 Istio sidecar + mTLS STRICT
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../.env"
RESULTS="$SCRIPT_DIR/../results/t1-istio"
mkdir -p "$RESULTS"

echo "==> V0 T1 Istio sidecar + mTLS STRICT"

# 1. Injection Istio
kubectl label namespace bendimu-sut istio-injection=enabled --overwrite
kubectl label namespace bendimu-load istio-injection=enabled --overwrite
kubectl -n bendimu-sut  rollout restart deployment/sut-bremler
kubectl -n bendimu-load rollout restart ds/fortio
kubectl -n bendimu-sut  rollout status deployment/sut-bremler --timeout=180s
kubectl -n bendimu-load rollout status ds/fortio --timeout=120s

# 2. PeerAuthentication STRICT namespace-wide.
# Note : Istio auto-bypass des health checks GKE via localhost (rewriteAppHTTPProbers
# activé par défaut sur sidecar injection). Pas de portLevelMtls nécessaire —
# et interdit sur PA namespace-scope (validation webhook Istio 1.22+).
cat <<'EOF' | kubectl apply -f -
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: bendimu-sut
spec:
  mtls:
    mode: STRICT
EOF

# 3. Vérif mTLS état effectif via cluster state directement.
# istioctl `authn tls-check` retiré (Istio 1.23+ et déjà indisponible 1.22.6).
# istioctl `x describe pod` a un bug avec GKE 1.35 (résolution pod cassée).
# On valide via 3 signaux : (a) pods READY 2/2 = sidecar injecté,
# (b) PeerAuthentication default mode STRICT exists, (c) istiod running.
sleep 15
SUT_POD="$(kubectl -n bendimu-sut get pod -l app=sut-bremler -o jsonpath='{.items[0].metadata.name}')"
READY_RATIO="$(kubectl -n bendimu-sut get pod "$SUT_POD" -o jsonpath='{.status.containerStatuses[*].ready}')"
PA_MODE="$(kubectl -n bendimu-sut get peerauthentication default -o jsonpath='{.spec.mtls.mode}' 2>/dev/null || echo "ABSENT")"
ISTIOD_READY="$(kubectl -n istio-system get deploy istiod -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"

echo "→ SUT pod ready containers : $READY_RATIO"
echo "→ PeerAuthentication mode  : $PA_MODE"
echo "→ istiod ready replicas    : $ISTIOD_READY"

if [[ "$READY_RATIO" == "true true" && "$PA_MODE" == "STRICT" && "$ISTIOD_READY" -ge 1 ]]; then
  echo "✅ mTLS STRICT actif (sidecar 2/2 + PA STRICT + istiod up)"
else
  echo "❌ Etat mTLS incohérent. Aborter."
  exit 1
fi

# 4. Palier de charge (fortio dans pod mesh)
FORTIO_POD=$(kubectl -n bendimu-load get pod -l app=fortio -o jsonpath='{.items[0].metadata.name}')
SUT_URL="http://sut-bremler.bendimu-sut.svc.cluster.local:8080"

# Charge : Fortio écrit le JSON dans /tmp du pod, on rapatrie ensuite via cat.
# Pattern robuste : évite le flood stdout qui casse kubectl exec (SPDY/HTTP2 relay).
# Rationale : à haute RPS + mTLS, Fortio générait des warns intermédiaires (Read
# errors EOF, etc.) sur stdout → K8s API server relay droppait le stream avant
# la fin. Résultat : "partiels" 925B sans données. On sépare exécution (silent)
# et récupération (unique burst read).
for endpoint in "" "data10kb" "data1mb"; do
  for rps in 100 500 1000 2000 4000 8000 12800; do
    echo "→ endpoint=/$endpoint rps=$rps"
    # 3 exec séparés — image fortio scratch (aucun shell/tool), sidecar
    # busybox 'helper' partage volume /tmp emptyDir pour rm+cat.
    # (a) supprimer résultat précédent via helper (best-effort)
    kubectl -n bendimu-load exec "$FORTIO_POD" -c helper -- rm -f /tmp/fortio-result.json 2>/dev/null || true
    # (b) run silencieux fortio, -quiet supprime Fortio stdout, -json écrit fichier
    kubectl -n bendimu-load exec "$FORTIO_POD" -c fortio -- fortio load \
      -qps "$rps" -c 200 -t 120s \
      -nocatchup -jitter -uniform -httpbufferkb 2048 -quiet \
      -json /tmp/fortio-result.json \
      "$SUT_URL/$endpoint" >/dev/null 2>&1 || true
    # (c) récup single burst via helper — fichier terminé
    kubectl -n bendimu-load exec "$FORTIO_POD" -c helper -- cat /tmp/fortio-result.json \
      > "$RESULTS/${endpoint:-root}-${rps}rps.json" 2>/dev/null || echo "  (partial)"
    sleep 15
  done
done

# 5. RSS Envoy sidecar (kubectl top + curl API Monitoring v3)
kubectl top pods -n bendimu-sut --containers -l app=sut-bremler \
  --sort-by=memory 2>/dev/null > "$RESULTS/memory-envoy.txt" || true
TOKEN=$(gcloud auth application-default print-access-token 2>/dev/null || echo "")
if [[ -n "$TOKEN" ]]; then
  END=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  START=$(date -u -d "5 min ago" +%Y-%m-%dT%H:%M:%SZ)
  curl -s -H "Authorization: Bearer $TOKEN" \
    "https://monitoring.googleapis.com/v3/projects/${GCP_PROJECT_ID}/timeSeries?filter=metric.type%3D%22kubernetes.io%2Fcontainer%2Fmemory%2Fused_bytes%22%20AND%20resource.labels.container_name%3D%22istio-proxy%22&interval.startTime=${START}&interval.endTime=${END}" \
    > "$RESULTS/memory-envoy.json" || true
fi

git tag -f v0-t1-ok
echo "✅ V0 T1 Istio OK. Résultats : $RESULTS"
