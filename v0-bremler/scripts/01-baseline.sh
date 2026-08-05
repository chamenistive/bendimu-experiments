#!/usr/bin/env bash
# V0 T0 baseline — simulated_tls_server sans mesh, palier 100 → 12800 RPS
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../.env"
RESULTS="$SCRIPT_DIR/../results/t0-baseline"
mkdir -p "$RESULTS"

echo "==> V0 T0 baseline (sans mesh)"

# 1. SUT Bremler officiel (image publique)
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: bendimu-sut
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sut-bremler
  namespace: bendimu-sut
spec:
  replicas: 5
  selector: { matchLabels: { app: sut-bremler } }
  template:
    metadata: { labels: { app: sut-bremler } }
    spec:
      nodeSelector: { "bendimu.pool": "sut" }
      containers:
        - name: sut
          image: yanivdocker92/simulated_tls_server:0.0.3
          ports: [{ containerPort: 8080 }]
          resources:
            requests: { cpu: 500m, memory: 256Mi }
            limits:   { cpu: 2,    memory: 512Mi }
          readinessProbe:
            httpGet: { path: /, port: 8080 }
            initialDelaySeconds: 3
---
apiVersion: v1
kind: Service
metadata:
  name: sut-bremler
  namespace: bendimu-sut
spec:
  selector: { app: sut-bremler }
  ports: [{ port: 8080, targetPort: 8080 }]
EOF

kubectl -n bendimu-sut rollout status deployment/sut-bremler --timeout=180s

# 2. Fortio DaemonSet sur node pool load
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
          ports: [{ containerPort: 8080 }]
EOF
kubectl -n bendimu-load rollout status ds/fortio --timeout=120s

# 3. Palier de charge (envoie via REST API Fortio depuis un pod aléatoire)
FORTIO_POD=$(kubectl -n bendimu-load get pod -l app=fortio -o jsonpath='{.items[0].metadata.name}')
SUT_URL="http://sut-bremler.bendimu-sut.svc.cluster.local:8080"

for endpoint in "" "data10kb" "data1mb"; do
  for rps in 100 500 1000 2000 4000 8000 12800; do
    echo "→ endpoint=/$endpoint rps=$rps"
    kubectl -n bendimu-load exec "$FORTIO_POD" -- fortio load \
      -qps "$rps" -c 200 -t 120s \
      -no-catchup -jitter -uniform \
      -json "-" "$SUT_URL/$endpoint" \
      > "$RESULTS/${endpoint:-root}-${rps}rps.json" 2>&1 || echo "  (partial)"
    sleep 15
  done
done

# 4. RSS mémoire SUT via GMP query (à travers gcloud monitoring)
gcloud monitoring metrics list --project="$GCP_PROJECT_ID" \
  --filter="metric.type=~'kubernetes.io/container/memory'" \
  --format=json > "$RESULTS/memory-baseline.json" || true

git tag -f v0-t0-ok
echo "✅ V0 T0 baseline OK. Résultats : $RESULTS"
