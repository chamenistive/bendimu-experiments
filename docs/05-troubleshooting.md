# 05 — Troubleshooting Bendimu sur GCP

**Statut :** ce document capitalise les modes d'échec rencontrés en bench local (`local-bench/HANDOFF-vers-GCP.md`) et les transpose systématiquement au contexte cloud, complétés des erreurs propres à GKE / Cloud NAT / GMP / Cloud Logging identifiées lors de la conception du protocole GCP.

**Usage :** consulter dès qu'un script `0X-*.sh` échoue OU qu'un chiffre attendu n'est pas dans la tolérance ±15 %/20 %.

---

## Table des matières

- [A. Auth & IAM GCP](#a-auth--iam-gcp)
- [B. Terraform & bootstrap](#b-terraform--bootstrap)
- [C. Cluster GKE](#c-cluster-gke)
- [D. Cilium OSS sur GKE](#d-cilium-oss-sur-gke)
- [E. Istio sur GKE](#e-istio-sur-gke)
- [F. mTLS & Zero Trust](#f-mtls--zero-trust)
- [G. Fortio & mesure de charge](#g-fortio--mesure-de-charge)
- [H. Observabilité (GMP, Envoy metrics, Cilium metrics)](#h-observabilit-gmp-envoy-metrics-cilium-metrics)
- [I. Coûts & budget](#i-cots--budget)
- [J. Cleanup & ressources orphelines](#j-cleanup--ressources-orphelines)

---

## A. Auth & IAM GCP

### A1. `403 The caller does not have permission`

**Symptôme :**
```
ERROR: (gcloud.container.clusters.create) ResponseError: code=403, ...
The caller does not have permission
```
**Causes possibles :**
1. `gcloud auth application-default login` non exécuté
2. Compte actif ≠ compte owner projet
3. SA impersonation configurée sur SA sans le rôle nécessaire

**Diagnostic :**
```bash
gcloud config list
gcloud auth list
gcloud projects get-iam-policy $PROJECT_ID --flatten="bindings[].members" --filter="bindings.members:$(gcloud config get account)"
```
**Fix :**
- Re-login : `gcloud auth login && gcloud auth application-default login`
- Vérifier binding rôle `roles/container.admin` sur `$SA_EMAIL` (voir `docs/01-setup-gcp.md` §5)

### A2. WIF (GitHub Actions) : `Permission denied on service account`

**Cause :** binding `roles/iam.workloadIdentityUser` sur le SA absent ou attribut mismatch.

**Fix :**
```bash
gcloud iam service-accounts get-iam-policy $SA_EMAIL --format=json | jq '.bindings'
# Doit contenir :
# {
#   "role": "roles/iam.workloadIdentityUser",
#   "members": ["principalSet://.../attribute.repository/TON-USER/bendimu-experiments"]
# }
```
Sinon rejouer la commande `add-iam-policy-binding` de [01-setup-gcp.md](01-setup-gcp.md) §9.

### A3. `Metadata server 401` depuis un pod GKE

**Cause :** `workload_metadata_config.mode ≠ GKE_METADATA` sur le node pool (déjà `GKE_METADATA` dans `cluster.tf`, mais peut être écrasé par un pool node manuel).

**Fix :**
```bash
gcloud container node-pools describe <pool> --cluster=bendimu-v1 --zone=$ZONE \
  --format="value(config.workloadMetadataConfig.mode)"
# Doit retourner : GKE_METADATA
```

---

## B. Terraform & bootstrap

### B1. `Backend configuration changed`

**Cause :** `terraform.tfvars` ou `-backend-config` a changé de bucket/préfixe entre deux `init`.

**Fix :**
```bash
terraform init -migrate-state -backend-config="bucket=..." -backend-config="prefix=..."
# ou reset complet :
rm -rf .terraform/
terraform init -backend-config="bucket=$TFSTATE_BUCKET" -backend-config="prefix=v1/"
```

### B2. `Resource already exists` (create-conflict)

**Cause :** ressource GCP créée manuellement ou par un ancien state.

**Fix :** import dans le state Terraform actuel :
```bash
terraform import google_container_cluster.this projects/$PROJECT_ID/locations/$ZONE/clusters/bendimu-v1
```

### B3. `Error 400 Quota exceeded`

Voir [C1](#c1-quota-cpu-ou-ssd-insuffisant).

### B4. `terraform destroy` bloque sur cluster GKE (deletion protection)

**Cause :** `deletion_protection = true` défini (recommandé campagne).

**Fix ponctuel** avant destroy :
```bash
gcloud container clusters update bendimu-v1 --zone=$ZONE \
  --update-labels="deletion-protection=false"

# OU via terraform :
terraform apply -var="cluster_deletion_protection=false"
terraform destroy
```

---

## C. Cluster GKE

### C1. Quota CPU ou SSD insuffisant

**Symptôme :** `Error 403: Insufficient quota for CPU (or SSD_TOTAL_GB) in europe-west1`.

**Fix :**
1. `tools/quota-check.sh` pour identifier le quota précis
2. Console GCP → IAM & Admin → Quotas → filtrer par région → demande d'augmentation
3. **Délai 24-48 h**. Anticiper.

### C2. `Node pool creation failed: capacity constraint`

**Cause :** rupture de stock `n2-standard-4` dans la zone. Fréquent en heures de pointe europe-west1.

**Fix :** `location_policy = "ANY"` dans le node pool (déjà configuré) OU changer zone (`europe-west1-c` au lieu de `-b`).

### C3. `kubectl` retourne `Unable to connect to the server`

**Causes :**
1. `gke-gcloud-auth-plugin` absent
2. Contexte `kubectl` non initialisé

**Fix :**
```bash
gcloud components install gke-gcloud-auth-plugin
gcloud container clusters get-credentials bendimu-v1 --zone=$ZONE --project=$PROJECT_ID
kubectl config current-context
```

### C4. Node pool preemptible tué en pleine mesure

**Cause :** VMs préemptibles ont TTL max 24 h et peuvent être préemptées à tout moment.

**Anticipation :** dans les runbooks V0/V1, les pools SUT et Load sont **preemptible=false**. Seul le pool observabilité peut être preemptible.

**Fix si mesure impactée :** relancer le script `0X-*.sh` — les résultats précédents sont marqués `interrupted` et exclus du calcul.

---

## D. Cilium OSS sur GKE

### D1. `ImagePullBackOff` sur cilium-agent DaemonSet

**Cause locale (rencontrée) :** `image.useDigest=true` par défaut + image miroir sur Artifact Registry → digest ne matche pas.

**Fix Helm values (`shared/helm-values/cilium.yaml`) :**
```yaml
image:
  repository: europe-west1-docker.pkg.dev/${PROJECT_ID}/bendimu-images/cilium
  tag: v1.16.3
  useDigest: false
operator:
  image:
    repository: europe-west1-docker.pkg.dev/${PROJECT_ID}/bendimu-images/cilium-operator-generic
    tag: v1.16.3
    useDigest: false
```

### D2. Cilium en conflit avec `kube-proxy` GKE natif

**Cause :** GKE Standard démarre `kube-proxy` par défaut, même si Cilium veut le remplacer.

**Fix :**
1. Créer le cluster avec `--no-enable-network-policy` (Terraform : `network_policy { enabled = false }`)
2. Avant install Cilium, scale kube-proxy à 0 :
```bash
kubectl -n kube-system patch daemonset kube-proxy -p '{"spec":{"template":{"spec":{"nodeSelector":{"non-existing-label":"true"}}}}}'
```
3. Install Cilium avec `kubeProxyReplacement: true` dans values

### D3. MTU mismatch VXLAN (tunnel mode)

**Cause locale (à anticiper) :** GCP VPC MTU = 1460, tunnel Cilium par défaut = 1450 → OK, mais si on active jumbo frames MTU=8896, le tunnel ne suit pas.

**Fix values :**
```yaml
mtu: 1450  # explicite
routingMode: tunnel
tunnelProtocol: vxlan
```

### D4. Cilium mutual auth ne s'active pas

**Symptôme :** `cilium config get enable-mutual-auth` retourne `false` malgré `helm upgrade --set enable-mutual-auth=true`.

**Fix :**
```bash
cilium config set enable-mutual-auth true
kubectl rollout restart daemonset/cilium -n kube-system
kubectl rollout status daemonset/cilium -n kube-system --timeout=300s
```

### D5. `cilium-agent` post-reboot node : `Kubernetes API refused`

**Cause locale (rencontrée) :** IP contrôleur K8s figée en env var `KUBERNETES_SERVICE_HOST=172.21.0.3`.

**Anticipation GCP :** control plane GKE = endpoint stable. Utiliser DNS Kubernetes natif — **ne pas hardcoder d'IP**.

Pour cluster privé, récupérer l'endpoint :
```bash
gcloud container clusters describe bendimu-v1 --zone=$ZONE \
  --format='value(privateClusterConfig.privateEndpoint)'
```
Passer via Helm : `--set k8sServiceHost=<endpoint> --set k8sServicePort=443`.

---

## E. Istio sur GKE

### E1. `istioctl install` bloqué sur webhook admission timeout

**Cause :** cluster nouveau, RBAC pas encore propagé.

**Fix :** retry après 30 s. Sinon :
```bash
istioctl install --set profile=default --skip-confirmation --readiness-timeout=5m
```

### E2. Envoy sidecar ne s'injecte pas

**Diagnostic :**
```bash
kubectl get ns bendimu-sut-v1 --show-labels
# Doit contenir : istio-injection=enabled

kubectl get pod -n bendimu-sut-v1 -o jsonpath='{.items[*].spec.containers[*].name}'
# Doit lister : app istio-proxy
```

**Si absent :** namespace labellé APRÈS création des pods → rollout obligatoire :
```bash
kubectl rollout restart deployment -n bendimu-sut-v1
```

### E3. Google LB health checks failing sur pod injecté

**Cause locale + GCP (anticipée) :** `PeerAuth STRICT` bloque probes HTTP non-mTLS depuis `35.191.0.0/16` + `130.211.0.0/22`.

**Fix (déjà dans manifests V0/V1) :**
```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: bendimu-sut-v1
spec:
  mtls: {mode: STRICT}
  portLevelMtls:
    15021: {mode: PERMISSIVE}   # Envoy status port
```

Et `BackendConfig` :
```yaml
apiVersion: cloud.google.com/v1
kind: BackendConfig
metadata:
  name: bendimu-gateway-hc
spec:
  healthCheck:
    type: HTTP2
    port: 15021
    requestPath: /healthz/ready
```

### E4. Cardinality Prometheus explose

**Cause :** Telemetry v2 émet ~200 labels par requête × 12800 RPS × 5 nodes → explosion.

**Fix Telemetry API (déjà dans manifests V1) :**
```yaml
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: reduce-cardinality
  namespace: istio-system
spec:
  metrics:
    - providers: [{name: prometheus}]
      overrides:
        - match: {metric: ALL_METRICS}
          tagOverrides:
            source_workload_namespace: {operation: REMOVE}
            destination_workload_namespace: {operation: REMOVE}
            request_protocol: {operation: REMOVE}
            response_flags: {operation: REMOVE}
```

### E5. Envoy access logs → coût Cloud Logging explose

**Cause :** `accessLogFile: /dev/stdout` par défaut → Ops Agent scrape stdout → 5-20 USD/campagne.

**Fix values Istio :**
```yaml
meshConfig:
  accessLogFile: ""  # DÉSACTIVÉ pour campagne bench
```

Réactiver uniquement pour debug ciblé.

---

## F. mTLS & Zero Trust

### F1. `istioctl authn tls-check` retourne `AUTO`, pas `OK`

**Cause :** `PeerAuthentication STRICT` non appliquée ou mauvais namespace.

**Fix :**
```bash
kubectl get peerauthentication -A
# Doit lister default STRICT dans bendimu-sut-v1

istioctl authn tls-check <pod>.<ns> <service>.<ns>.svc.cluster.local
# STATUS: OK  attendu
```

### F2. Health check Google LB fail après activation STRICT

Voir [E3](#e3-google-lb-health-checks-failing-sur-pod-inject).

### F3. Cilium mutual auth handshake échoue silencieusement

**Symptôme :** trafic OK apparent mais `hubble observe` montre `AUTH_REQUIRED` drops.

**Diagnostic :**
```bash
cilium hubble observe --type drop --verdict AUTH_REQUIRED
```

**Fix :** vérifier que CiliumNetworkPolicy autorise l'auth requise :
```yaml
egress:
  - authentication:
      mode: "required"
    toEndpoints:
      - matchLabels: {app: sut-v1}
```

---

## G. Fortio & mesure de charge

### G1. **JAMAIS utiliser `kubectl port-forward` pour la mesure publiée**

**Cause locale (rencontrée) :** port-forward bypass sidecar Envoy → `istio_requests_total = 0`, mesure invalide.

**Anticipation GCP :** même problème. **Règle absolue :** Fortio dans un pod injecté (`bendimu-load` ns injecté) qui appelle le SUT via Service ClusterIP interne. **Aucun port-forward.**

### G2. `-no-catchup` absent → p99 gonflé artificiellement

**Cause :** Fortio par défaut rattrape les requêtes perdues, ce qui accumule un backlog qui fausse la mesure de latence.

**Fix :** tous les scripts `0X-*.sh` passent explicitement :
```bash
fortio load -no-catchup -jitter -uniform -qps=$RPS -c=$CONN -t=120s ...
```

### G3. `kubectl exec fortio load` : stdout bloqué

**Cause locale (rencontrée) :** buffer plein, pas de terminal alloué.

**Anticipation GCP :** **même problème sur GKE.** **Règle absolue :** utiliser Fortio en mode **server** + REST API pour lancer les runs :
```bash
kubectl exec -n bendimu-load fortio-load -- fortio server &
kubectl port-forward -n bendimu-load fortio-load 8080:8080  # UNIQUEMENT pour trigger REST, pas pour trafic mesuré
curl -X POST http://localhost:8080/fortio/rest/run?jsonPath=.&qps=1000&t=60s&url=http://sut-v1.bendimu-sut-v1.svc:8080/aisp/accounts
```

### G4. Loi de Little violée : impossible d'atteindre 12800 RPS

**Cause :** `RPS = connexions × 1/latence_moyenne`. À 400 ms de latence sur `/pisp/execute`, il faut **5120 connexions parallèles** pour tenir 12800 RPS.

**Fix :** distribuer sur Fortio DaemonSet 5 réplicas × 1024 connexions = 5120 connexions actives.

Le manifest `manifests/fortio-daemonset.yaml` (à générer par scripts) configure ça.

### G5. Fortio timeout après 60 s

**Cause :** `-timeout 3s` défaut Fortio, incompatible avec `/pisp/execute` 400 ms + queue.

**Fix :** `-timeout 10s` minimum sur runs PSD2.

---

## H. Observabilité (GMP, Envoy metrics, Cilium metrics)

### H1. GMP `PodMonitoring` ne scrape rien

**Diagnostic :**
```bash
kubectl get podmonitoring -A
kubectl describe podmonitoring cilium-agent -n gmp-system
# Section "Status" doit montrer "Ready: True"
```

**Fix :** vérifier label selector matche exactement les pods :
```yaml
apiVersion: monitoring.googleapis.com/v1
kind: PodMonitoring
metadata:
  name: cilium-agent
  namespace: gmp-system
spec:
  selector:
    matchLabels:
      k8s-app: cilium
  endpoints:
    - port: 9962
      interval: 15s
      path: /metrics
```

### H2. Grafana ne trouve pas la data source GMP

**Fix :** ajouter dans Grafana → Data Sources :
- Type : Prometheus
- URL : `https://monitoring.googleapis.com/v1/projects/$PROJECT_ID/location/global/prometheus`
- Auth : Google JWT (SA `monitoring.viewer`)

### H3. Sidecar Envoy `:15020` renvoie uniquement `istio_agent_*`

**Cause locale (rencontrée) :** aucun trafic mesh encore passé → merge Prom vide.

**Fix :** injecter trafic **avant** scrape (attente 30 s min entre déploiement et lancement Fortio).

---

## I. Coûts & budget

### I1. Alerte budget 50 % / 90 % / 100 % reçue

**Action immédiate :**
```bash
tools/budget-check.sh
# Affiche coût per resource, identifie le top consommateur
```

Si 90 % atteint en <24 h : **teardown immédiat** :
```bash
cd ~/Desktop/bendimu-experiments/v1-bendimu && ./scripts/99-destroy.sh
```

### I2. LB HTTP(S) facture 25 USD/mois même idle

**Fix :** utiliser NodePort + IAP pour tests, LB uniquement en campagne finale.

### I3. Cloud Logging explose (accessLogs Envoy)

Voir [E5](#e5-envoy-access-logs--cot-cloud-logging-explose).

### I4. PD SSD orphelins après `terraform destroy`

**Diagnostic + fix :**
```bash
tools/cleanup-orphans.sh
# Liste + demande confirmation avant delete
```

### I5. Artifact Registry cross-region → egress facturé

**Fix :** registry et cluster **MÊME région** (`europe-west1`). Vérifier :
```bash
gcloud artifacts repositories describe bendimu-images --location=europe-west1
```

### I6. Cluster oublié tourne pendant sommeil

**Prévention :** cron auto-shutdown à `$AUTO_SHUTDOWN_HOUR` UTC dans `tools/cleanup-orphans.sh --schedule-shutdown`.

---

## J. Cleanup & ressources orphelines

Détails complets dans [06-cleanup.md](06-cleanup.md). Résumé rapide :

```bash
tools/cleanup-orphans.sh --dry-run   # liste tout
tools/cleanup-orphans.sh              # supprime après confirmation
tools/budget-check.sh                 # coût actuel + prévision fin de mois
```

Ressources à vérifier systématiquement post-destroy :
- Clusters GKE (`gcloud container clusters list`)
- PD SSD (`gcloud compute disks list`)
- IP externes réservées (`gcloud compute addresses list`)
- LB forwarding rules (`gcloud compute forwarding-rules list`)
- Artifact Registry (garder mais purger tags vieux)
- Buckets GCS temporaires (`gcloud storage buckets list`)
