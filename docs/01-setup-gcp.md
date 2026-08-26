# 01 — Setup Google Cloud Platform

**Objectif :** préparer un projet GCP fonctionnel, sécurisé, budgété et prêt pour `terraform apply` du bootstrap. Zéro action manuelle après cette étape.

**Pré-requis :** [00-prerequis.md](00-prerequis.md) validé (`gcloud`, `terraform`, `docker` installés, compte GCP actif avec crédit).

---

## 1. Décisions cadres (à valider avant tout)

| Paramètre | Valeur retenue | Justification |
|---|---|---|
| **Région primaire** | `europe-west1` (Belgique) | Meilleur RTT depuis Cameroun (~120 ms) vs `us-central1` (~200 ms), disponibilité `n2-standard-4`, GMP supporté |
| **Zone principale** | `europe-west1-b` (mono-zone) | Élimine variance latence inter-zones sur les mesures de perf |
| **`project_id`** | `bendimu-mesh-bench` | Identifiant globalement unique, changer si déjà pris (`gcloud projects list`) |
| **Nom Terraform state bucket** | `bendimu-tfstate-<project_id>` | Bucket dédié, versioning ON, uniform bucket-level access |
| **Cilium install** | OSS 1.16.3 manuel via Helm | Fidélité stricte à l'artefact Bremler-Barr 2024, pas GKE Dataplane V2 |
| **Prometheus** | Google Managed Prometheus (GMP) | Économie ~70 USD/mois vs self-hosted, auto-scale |
| **CI/CD** | GitHub Actions (repo privé) | Free tier suffisant, tokens gérés via `GITHUB_TOKEN` + WIF |
| **Compte GCP (crédits)** | `stive.chameni@facsciences-uy1.cm` | Compte académique Université Yaoundé 1 hébergeant les crédits |
| **Contact alertes** | `stive.chameni@facsciences-uy1.cm` | Budget alerts + owner IAM |
| **Budget hard cap** | **300 USD (crédit UY1 total)** | Marge 3 campagnes × ~150 USD, alerte auto-shutdown à 90 % |

Si un paramètre change, éditer `.env` racine puis répercuter dans `bootstrap/terraform.tfvars`.

---

## 2. Création du projet GCP

### 2.1 Authentification

**Compte à utiliser : `stive.chameni@facsciences-uy1.cm`** (compte académique Université Yaoundé 1 avec les crédits GCP). Ne pas confondre avec `nazaclems@gmail.com` (compte personnel, sans crédits).

```bash
gcloud auth login stive.chameni@facsciences-uy1.cm
gcloud auth application-default login
gcloud config set account stive.chameni@facsciences-uy1.cm
```

Vérif :
```bash
gcloud auth list
# ACTIVE  ACCOUNT
# *       stive.chameni@facsciences-uy1.cm

# Vérifier les crédits disponibles
gcloud billing accounts list
# doit afficher au moins un ACCOUNT_ID lié à ce compte
```

**Attention navigateur :** lors du `gcloud auth login`, si Chrome/Firefox est déjà connecté à ton compte perso `nazaclems@gmail.com`, la fenêtre OAuth peut proposer par défaut le mauvais compte. **Cliquer explicitement « Utiliser un autre compte » et saisir `stive.chameni@facsciences-uy1.cm`.**

### 2.2 Récupérer l'ID de facturation

```bash
gcloud billing accounts list
# ACCOUNT_ID            NAME                OPEN  MASTER_ACCOUNT_ID
# 01ABCD-234567-EFGH89  Compte de facturation OUI
```

Copier `ACCOUNT_ID` → variable `BILLING_ACCOUNT_ID` dans `.env`.

### 2.3 Créer le projet

```bash
export PROJECT_ID="bendimu-mesh-bench"
export BILLING_ACCOUNT_ID="01ABCD-234567-EFGH89"

gcloud projects create "$PROJECT_ID" \
  --name="Bendimu Mesh Benchmark" \
  --set-as-default

gcloud beta billing projects link "$PROJECT_ID" \
  --billing-account="$BILLING_ACCOUNT_ID"

gcloud config set project "$PROJECT_ID"
gcloud projects describe "$PROJECT_ID"
```

Si `gcloud projects create` échoue avec `ALREADY_EXISTS` → choisir un autre `PROJECT_ID` (ex : `bendimu-mesh-bench-2026`).

---

## 3. Activation des APIs

**9 APIs requises** pour le protocole complet :

```bash
gcloud services enable \
  compute.googleapis.com \
  container.googleapis.com \
  artifactregistry.googleapis.com \
  cloudresourcemanager.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  monitoring.googleapis.com \
  logging.googleapis.com \
  cloudbilling.googleapis.com \
  --project="$PROJECT_ID"
```

Vérif :
```bash
gcloud services list --enabled --project="$PROJECT_ID" | wc -l
# Doit retourner 10+ (9 activées + header)
```

**Coût d'activation :** 0 USD. La facturation démarre uniquement à l'usage.

---

## 4. Quotas critiques (à vérifier AVANT `terraform apply`)

Le protocole Bendimu exige :

| Quota | Valeur minimum | Défaut GCP | Action si insuffisant |
|---|---|---|---|
| `CPUS` (region europe-west1) | 40 | 24 | Demande via Console → IAM & Admin → Quotas |
| `SSD_TOTAL_GB` (region) | 500 | 500 | OK Free-Trial-upgraded (450 GB requis, marge 50) |
| `IN_USE_ADDRESSES` (region) | 5 | 8 | OK par défaut |
| `NETWORKS` (global) | 5 | 5 | OK |
| `FIREWALLS` (global) | 100 | 100 | OK |

Vérification automatique :
```bash
gcloud compute project-info describe \
  --project="$PROJECT_ID" \
  --format="value(quotas)" | grep -E "CPUS|SSD_TOTAL_GB|IN_USE_ADDRESSES"
```

Le script [`tools/quota-check.sh`](../tools/quota-check.sh) automatise cette vérification et retourne un exit code non-zéro si un quota est insuffisant.

**Délai upgrade quota :** 24-48 h. **Faire la demande maintenant** si première fois sur ce compte.

---

## 5. Service Account Terraform (dédié)

Le bootstrap crée un SA `terraform-bendimu` avec les rôles minimum nécessaires. Création manuelle pour bootstrap-le-bootstrap :

```bash
export SA_NAME="terraform-bendimu"
export SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud iam service-accounts create "$SA_NAME" \
  --display-name="Terraform Bendimu Ops" \
  --project="$PROJECT_ID"

for role in \
  roles/compute.admin \
  roles/container.admin \
  roles/iam.serviceAccountAdmin \
  roles/iam.serviceAccountUser \
  roles/resourcemanager.projectIamAdmin \
  roles/storage.admin \
  roles/artifactregistry.admin \
  roles/monitoring.admin \
  roles/logging.admin \
  roles/billing.viewer; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="$role" \
    --condition=None
done
```

**Pas de clé JSON téléchargée en local.** On utilise `gcloud auth application-default login` (impersonation) ou Workload Identity Federation depuis GitHub Actions.

Impersonation pour Terraform local :
```bash
gcloud config set auth/impersonate_service_account "$SA_EMAIL"
gcloud storage buckets list
```

---

## 6. Bucket Terraform state

Backend GCS pour l'état Terraform (multi-user, verrouillage natif via GCS conditional updates) :

```bash
export TFSTATE_BUCKET="bendimu-tfstate-${PROJECT_ID}"

gcloud storage buckets create "gs://${TFSTATE_BUCKET}" \
  --project="$PROJECT_ID" \
  --location="europe-west1" \
  --uniform-bucket-level-access \
  --public-access-prevention

gcloud storage buckets update "gs://${TFSTATE_BUCKET}" --versioning

cat > /tmp/lifecycle.json <<EOF
{
  "lifecycle": {
    "rule": [
      {
        "action": {"type": "Delete"},
        "condition": {"numNewerVersions": 5, "daysSinceNoncurrentTime": 30}
      }
    ]
  }
}
EOF
gcloud storage buckets update "gs://${TFSTATE_BUCKET}" \
  --lifecycle-file=/tmp/lifecycle.json
```

---

## 7. Budget + alertes

**Objectif :** aucune facture surprise. Alertes email à 50 %, 90 %, 100 %.

Le module Terraform `shared/modules/budget-alerts/` créera ces alertes automatiquement, mais on peut aussi les créer maintenant via `gcloud` pour être protégé dès la première commande :

```bash
export BUDGET_AMOUNT=300

gcloud billing budgets create \
  --billing-account="$BILLING_ACCOUNT_ID" \
  --display-name="Bendimu 300 USD (crédit UY1)" \
  --budget-amount="${BUDGET_AMOUNT}USD" \
  --threshold-rule=percent=0.5 \
  --threshold-rule=percent=0.9 \
  --threshold-rule=percent=1.0 \
  --filter-projects="projects/$(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')"
```

**Fallback Console** si CLI échoue : Console → Billing → Budgets & alerts → Create budget → 300 USD → 50/90/100 % → email destinataire = `stive.chameni@facsciences-uy1.cm`.

---

## 8. Fichier `.env` local

```bash
cd ~/Desktop/bendimu-experiments
cp .env.example .env
```

Éditer `.env` (variables clés à remplir — voir [.env.example](../.env.example) pour la liste complète) :

```bash
export GCP_PROJECT_ID="bendimu-mesh-bench"
export GCP_PROJECT_NUMBER="<gcloud projects describe … --format='value(projectNumber)'>"
export GCP_BILLING_ACCOUNT="<gcloud billing accounts list>"
export GCP_REGION="europe-west1"
export GCP_ZONE="europe-west1-b"
export GCP_ACCOUNT="stive.chameni@facsciences-uy1.cm"
export GCP_SERVICE_ACCOUNT_EMAIL="terraform-bendimu@bendimu-mesh-bench.iam.gserviceaccount.com"
export TF_BACKEND_BUCKET="bendimu-tfstate-bendimu-mesh-bench"
export BUDGET_TOTAL_USD="300"
export BUDGET_ALERT_EMAIL="stive.chameni@facsciences-uy1.cm"
export GITHUB_ORG="chamenistive"
export GITHUB_REPO="bendimu-experiments"
```

`.env` est dans `.gitignore` — **jamais commité**.

---

## 9. Workload Identity Federation (GitHub Actions ↔ GCP)

**Objectif :** GitHub Actions déploie sans stocker de clé JSON. Auth via OIDC.

Setup (une seule fois) :

```bash
gcloud iam workload-identity-pools create "github-pool" \
  --project="$PROJECT_ID" \
  --location="global" \
  --display-name="GitHub Actions Pool"

gcloud iam workload-identity-pools providers create-oidc "github-provider" \
  --project="$PROJECT_ID" \
  --location="global" \
  --workload-identity-pool="github-pool" \
  --display-name="GitHub OIDC Provider" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
  --attribute-condition="assertion.repository=='${GITHUB_ORG}/${GITHUB_REPO}'" \
  --issuer-uri="https://token.actions.githubusercontent.com"

export POOL_ID=$(gcloud iam workload-identity-pools describe github-pool \
  --project="$PROJECT_ID" --location="global" --format="value(name)")

gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --project="$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/${POOL_ID}/attribute.repository/${GITHUB_ORG}/${GITHUB_REPO}"
```

Ajouter dans GitHub → Settings → Secrets :
- `WIF_PROVIDER` = `projects/<num>/locations/global/workloadIdentityPools/github-pool/providers/github-provider`
- `GCP_SA_EMAIL` = `terraform-bendimu@bendimu-mesh-bench.iam.gserviceaccount.com`
- `GCP_PROJECT_ID` = `bendimu-mesh-bench`

---

## 10. Vérification finale avant bootstrap

- [ ] `gcloud config get project` retourne `bendimu-mesh-bench`
- [ ] `gcloud services list --enabled | wc -l` ≥ 10
- [ ] `gcloud iam service-accounts list | grep terraform-bendimu` retourne 1 ligne
- [ ] `gcloud storage buckets list | grep bendimu-tfstate` retourne 1 ligne
- [ ] Budget visible dans Console → Billing → Budgets
- [ ] `.env` créé et sourcé (`echo $PROJECT_ID` répond)
- [ ] Quotas CPUS ≥ 40, SSD_TOTAL_GB ≥ 500 (ou demande envoyée)
- [ ] WIF configuré + secrets GitHub renseignés

---

## 11. Bootstrap Terraform (racine)

```bash
cd ~/Desktop/bendimu-experiments/bootstrap
cp terraform.tfvars.example terraform.tfvars
# éditer terraform.tfvars avec les valeurs de .env

terraform init \
  -backend-config="bucket=${TFSTATE_BUCKET}" \
  -backend-config="prefix=bootstrap"

terraform plan -out=bootstrap.plan
terraform apply bootstrap.plan
```

Le bootstrap crée :
- Artifact Registry `bendimu-images` (region europe-west1)
- Réseau VPC `bendimu-vpc` + subnet `bendimu-subnet-eu-w1`
- Cloud NAT + Router
- Firewalls IAP + health checks Google (35.191.0.0/16, 130.211.0.0/22)
- Alertes budget (50/90/100 %)

Durée : ~3 min. Coût : ~0.10 USD (juste le NAT idle).

**Une fois OK → passer à [02-v0-bremler.md](02-v0-bremler.md).**
