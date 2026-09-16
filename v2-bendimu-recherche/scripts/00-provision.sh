#!/usr/bin/env bash
# V2 Recherche — cluster GKE principal (+ clusters cross-region si A8 activé)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../terraform"
source "$SCRIPT_DIR/../../.env"

echo "==> V2 provision — cluster ${CLUSTER_NAME_V2}"

# 0. Auth pre-check (fix V1 E10 : gcloud/ADC expire silencieusement)
gcloud auth print-access-token >/dev/null 2>&1 || {
  echo "❌ gcloud auth expiré. Relancer : gcloud auth login ${GCP_ACCOUNT}"
  exit 1
}
gcloud auth application-default print-access-token >/dev/null 2>&1 || {
  echo "❌ ADC expiré. Relancer : gcloud auth application-default login"
  exit 1
}
gcloud auth application-default set-quota-project "$GCP_PROJECT_ID" >/dev/null 2>&1 || true

"$SCRIPT_DIR/../../tools/quota-check.sh"

terraform init \
  -backend-config="bucket=${TF_BACKEND_BUCKET}" \
  -backend-config="prefix=${TF_BACKEND_PREFIX_V2}"

# 2a. Step 1 : cluster GKE seul (chicken-and-egg fix E5, cf V0/V1)
terraform plan -target=module.gke_primary -out=v2-gke.plan
echo
read -rp "Continuer avec apply cluster ? [y/N] " ans
ans_trim="${ans//[$'\r\n\t ']/}"
case "${ans_trim,,}" in
  y|yes) ;;
  *) echo "Annulé (réponse reçue : '$ans')."; exit 1 ;;
esac
terraform apply -auto-approve v2-gke.plan

gcloud container clusters get-credentials "$CLUSTER_NAME_V2" \
  --zone="$GCP_ZONE" --project="$GCP_PROJECT_ID"

# Namespaces AVANT full apply (pm_envoy monitoring référence ns)
kubectl create namespace bendimu-sut-v1 --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace bendimu-load  --dry-run=client -o yaml | kubectl apply -f -

# 2b. Step 2 : full apply (PodMonitoring + alert policy)
terraform apply -auto-approve

# Cilium + Istio 1.24 identiques V1 (avec tous fixes E4/E28/E31 portés)
kubectl -n kube-system get ds cilium >/dev/null 2>&1 || {
  kubectl -n kube-system patch daemonset kube-proxy \
    -p '{"spec":{"template":{"spec":{"nodeSelector":{"non-existing-label":"true"}}}}}' \
    2>/dev/null || echo "kube-proxy déjà patché ou absent"

  cilium install --version "$V1_CILIUM_VERSION" \
    --set cluster.name="$CLUSTER_NAME_V2" \
    --set kubeProxyReplacement=true \
    --set socketLB.hostNamespaceOnly=true \
    --set endpointRoutes.enabled=true \
    --set image.useDigest=false \
    --set operator.image.useDigest=false \
    --set mtu=1450 --set routingMode=tunnel --set tunnelProtocol=vxlan \
    --set hubble.enabled=true \
    --set hubble.metrics.enabled='{dns,drop,tcp,flow,port-distribution,icmp,http}' \
    --set prometheus.enabled=true \
    --set operator.prometheus.enabled=true \
    --set authentication.mutual.spire.enabled=true \
    --set authentication.mutual.spire.install.enabled=true

  # Attendre SPIRE DS + patcher tolérations pool load (fix V1 E18/E33)
  for i in $(seq 1 30); do
    kubectl -n cilium-spire get daemonset spire-agent >/dev/null 2>&1 && break
    sleep 5
  done
  kubectl -n cilium-spire patch daemonset spire-agent --type=json -p='[
    {"op":"add","path":"/spec/template/spec/tolerations","value":[
      {"key":"bendimu.role","operator":"Equal","value":"load","effect":"NoSchedule"}
    ]}
  ]' 2>/dev/null || true
  kubectl -n cilium-spire rollout status daemonset/spire-agent --timeout=180s 2>/dev/null || true

  cilium status --wait --wait-duration 5m
}

# Istio 1.24 : disable istio-cni (fix E29 conflit Cilium eBPF)
which istioctl-1.24 >/dev/null 2>&1 || { echo "istioctl-1.24 absent"; exit 1; }
istioctl-1.24 install --set profile=default --set components.cni.enabled=false \
  --skip-confirmation --readiness-timeout=5m

# Workloads : SUT V1 (image sut-v1:1.0.0 déjà buildée session V1) + Fortio DS + helper busybox
IMAGE="${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT_ID}/bendimu-images/sut-v1:${TLS_SERVER_IMAGE_TAG:-1.0.0}"
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: { name: sut-v1, namespace: bendimu-sut-v1 }
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
metadata: { name: sut-v1, namespace: bendimu-sut-v1 }
spec:
  selector: { app: sut-v1 }
  ports: [{ port: 8080, targetPort: 8080 }]
EOF
kubectl -n bendimu-sut-v1 rollout status deployment/sut-v1 --timeout=180s

cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata: { name: fortio, namespace: bendimu-load }
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
          volumeMounts:
            - { name: results, mountPath: /tmp }
        - name: helper
          image: busybox:1.36
          command: ["sh", "-c", "sleep infinity"]
          resources:
            requests: { cpu: "50m", memory: "32Mi" }
            limits:   { cpu: "200m", memory: "128Mi" }
          volumeMounts:
            - { name: results, mountPath: /tmp }
      volumes:
        - name: results
          emptyDir: {}
EOF
kubectl -n bendimu-load rollout status ds/fortio --timeout=120s

git tag -f v2-provisioned
echo "✅ V2 provision OK (cluster + Cilium+SPIRE + Istio + SUT + Fortio). Passer à 01-run-amendments.sh"
