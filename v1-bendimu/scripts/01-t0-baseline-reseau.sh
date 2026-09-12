#!/usr/bin/env bash
# V1 T0 — Build image sut-v1, push AR, deploy sans mesh, mesure baseline PSD2
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../.env"
RESULTS="$SCRIPT_DIR/../results/t0-baseline-reseau"
mkdir -p "$RESULTS"

IMAGE="${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT_ID}/bendimu-images/sut-v1:${TLS_SERVER_IMAGE_TAG:-1.0.0}"

echo "==> V1 T0 baseline réseau (sans mesh)"

# 1. Build + push
gcloud auth configure-docker "${GCP_REGION}-docker.pkg.dev" --quiet
docker build -t "$IMAGE" "$SCRIPT_DIR/../tls-server/"
docker push "$IMAGE"

# 2. Deploy SUT V1 (5 replicas, 3 endpoints PSD2 + héritage Bremler)
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sut-v1
  namespace: bendimu-sut-v1
spec:
  replicas: 5
  selector: { matchLabels: { app: sut-v1 } }
  template:
    metadata: { labels: { app: sut-v1 } }
    spec:
      nodeSelector: { "bendimu.pool": "sut" }
      containers:
        - name: sut
          image: ${IMAGE}
          ports: [{ containerPort: 8080 }]
          resources:
            requests: { cpu: 500m, memory: 128Mi }
            limits:   { cpu: 2,    memory: 256Mi }
          readinessProbe:
            httpGet: { path: /healthz, port: 8080 }
            initialDelaySeconds: 2
          securityContext:
            runAsNonRoot: true
            runAsUser: 65532
            readOnlyRootFilesystem: true
            capabilities: { drop: [ALL] }
---
apiVersion: v1
kind: Service
metadata:
  name: sut-v1
  namespace: bendimu-sut-v1
spec:
  selector: { app: sut-v1 }
  ports: [{ port: 8080, targetPort: 8080 }]
EOF

kubectl -n bendimu-sut-v1 rollout status deployment/sut-v1 --timeout=180s

# 3. Fortio DaemonSet (idem V0)
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: fortio
  namespace: bendimu-load
spec:
  selector: { matchLabels: { app: fortio } }
  template:
    metadata: { labels: { app: fortio } }
    spec:
      nodeSelector: { "bendimu.pool": "load" }
      tolerations:
        - { key: "bendimu.role", operator: "Equal", value: "load", effect: "NoSchedule" }
      containers:
        - name: fortio
          image: fortio/fortio:1.68.0
          args: ["server", "-http-port", "8080"]
          resources:
            requests: { cpu: "2", memory: "1Gi" }
            limits:   { cpu: "3", memory: "2Gi" }
EOF
kubectl -n bendimu-load rollout status ds/fortio --timeout=120s

# 4. Palier PSD2 : ratio 60/30/10 sur 3 endpoints, palier RPS total
FORTIO_POD=$(kubectl -n bendimu-load get pod -l app=fortio -o jsonpath='{.items[0].metadata.name}')
SUT="http://sut-v1.bendimu-sut-v1.svc.cluster.local:8080"

for total_rps in 100 500 1000 2000 4000 8000 12800; do
  aisp_rps=$((total_rps * 60 / 100))
  auth_rps=$((total_rps * 30 / 100))
  exec_rps=$((total_rps * 10 / 100))

  echo "→ total=${total_rps} RPS (aisp=$aisp_rps, authorize=$auth_rps, execute=$exec_rps)"

  kubectl -n bendimu-load exec "$FORTIO_POD" -- fortio load \
    -qps "$aisp_rps" -c 128 -t 120s -nocatchup -jitter -uniform \
    -json - "$SUT/aisp/accounts" > "$RESULTS/aisp-${total_rps}rps.json" 2>&1 &
  PID_AISP=$!

  kubectl -n bendimu-load exec "$FORTIO_POD" -- fortio load \
    -qps "$auth_rps" -c 64 -t 120s -nocatchup -jitter -uniform \
    -method POST -json - "$SUT/pisp/authorize" > "$RESULTS/authorize-${total_rps}rps.json" 2>&1 &
  PID_AUTH=$!

  kubectl -n bendimu-load exec "$FORTIO_POD" -- fortio load \
    -qps "$exec_rps" -c 64 -t 120s -nocatchup -jitter -uniform \
    -method POST -json - "$SUT/pisp/execute" > "$RESULTS/execute-${total_rps}rps.json" 2>&1 &
  PID_EXEC=$!

  wait $PID_AISP $PID_AUTH $PID_EXEC
  sleep 20
done

git tag -f v1-t0-ok
echo "✅ V1 T0 baseline réseau OK. Résultats : $RESULTS"
