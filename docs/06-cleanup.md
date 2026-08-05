# 06 — Cleanup & Destruction

**Objectif :** garantir zéro coût résiduel après une campagne. Chaque ressource GCP créée par ce dépôt doit être détruite ou explicitement conservée.

**Règle d'or :** un cluster GKE oublié coûte ~150 USD/mois. Un LB forwarding rule oublié = 20 USD/mois. Ces ressources **ne sont pas incluses dans le free tier**.

---

## 1. Séquence de destruction canonique

### 1.1 Destruction ordonnée par version

```bash
cd ~/Desktop/bendimu-experiments
source .env

# V2 d'abord (multi-cluster potentiellement)
cd v2-bendimu-recherche && ./scripts/99-destroy.sh
cd ..

# V1
cd v1-bendimu && ./scripts/99-destroy.sh
cd ..

# V0
cd v0-bremler && ./scripts/99-destroy.sh
cd ..

# Bootstrap (uniquement si abandon définitif du projet)
# cd bootstrap && terraform destroy
```

Chaque script `99-destroy.sh` :
1. Désinstalle Cilium + Istio (évite orphelins LB)
2. Supprime namespaces applicatifs
3. `terraform destroy` sur le module cluster correspondant
4. Log dans `results/teardown-<version>.log`

### 1.2 Vérification exhaustive post-destroy

```bash
tools/cleanup-orphans.sh --dry-run
```

Le script liste **toutes** les ressources GCP qui pourraient traîner :

| Ressource | Commande de vérif | Coût si oublié |
|---|---|---|
| Clusters GKE | `gcloud container clusters list --project=$PROJECT_ID` | ~150 USD/mois par cluster |
| Node pools | inclus ci-dessus | idem |
| PD SSD | `gcloud compute disks list --project=$PROJECT_ID` | 0.17 USD/Gi/mois |
| IP externes réservées | `gcloud compute addresses list --project=$PROJECT_ID` | 3 USD/mois par IP idle |
| LB forwarding rules | `gcloud compute forwarding-rules list --project=$PROJECT_ID` | 20 USD/mois |
| Target proxies HTTP(S) | `gcloud compute target-http-proxies list --project=$PROJECT_ID` | inclus LB |
| URL maps | `gcloud compute url-maps list --project=$PROJECT_ID` | inclus LB |
| Backend services | `gcloud compute backend-services list --project=$PROJECT_ID` | inclus LB |
| Network endpoint groups | `gcloud compute network-endpoint-groups list --project=$PROJECT_ID` | inclus LB |
| Cloud NAT gateways | `gcloud compute routers list --project=$PROJECT_ID` | 0.044 USD/h + trafic |
| Firewalls | `gcloud compute firewall-rules list --project=$PROJECT_ID` | gratuit mais nettoyer |
| VPC networks | `gcloud compute networks list --project=$PROJECT_ID` | gratuit mais nettoyer |

Après validation visuelle du dry-run :
```bash
tools/cleanup-orphans.sh   # supprime avec confirmation individuelle
```

---

## 2. Vérification budget résiduel

```bash
tools/budget-check.sh
```

Sortie type post-destroy réussi :
```
Budget mois courant : 800 USD
Consommé : 22.14 USD (2.77 %)
Prévision fin de mois : 22.14 USD (aucune ressource active)
Top 3 postes :
  1. Compute Engine (VM SUT nodes)     — 12.30 USD
  2. Cloud NAT                          —  4.85 USD
  3. Cloud Logging                      —  2.40 USD
Aucune ressource facturante active : OK
```

Si prévision fin de mois > 5 USD alors que tous les scripts destroy ont tourné : investiguer via `cleanup-orphans.sh --dry-run`.

---

## 3. Purge Artifact Registry

Les images Docker `sut-v1:*` s'accumulent. Purger les tags anciens :

```bash
# Lister tags
gcloud artifacts docker images list \
  europe-west1-docker.pkg.dev/$PROJECT_ID/bendimu-images/sut-v1 \
  --format="table(digest,tags,createTime)" \
  --sort-by=~createTime

# Garder les 3 derniers, supprimer le reste
gcloud artifacts docker images list \
  europe-west1-docker.pkg.dev/$PROJECT_ID/bendimu-images/sut-v1 \
  --format="value(digest)" \
  --sort-by=~createTime | tail -n +4 | while read digest; do
    gcloud artifacts docker images delete \
      "europe-west1-docker.pkg.dev/$PROJECT_ID/bendimu-images/sut-v1@$digest" \
      --quiet --delete-tags
  done
```

**Coût Artifact Registry :** 0.10 USD/Gi/mois. Négligeable mais purger par hygiène.

---

## 4. Purge Cloud Logging

Les logs Envoy accumulés peuvent gonfler.

```bash
gcloud logging logs list --project=$PROJECT_ID
```

Suppression sélective (attention destructif) :
```bash
gcloud logging logs delete "projects/$PROJECT_ID/logs/istio-proxy" --quiet
```

**Alternative recommandée :** créer un exclusion filter pour ne PAS ingérer les logs Envoy pendant la campagne (défini dans `bootstrap/main.tf`).

---

## 5. Purge Cloud Monitoring / GMP

GMP retention par défaut : 24 mois. Coût 0.06 USD/Mo échantillon.

Vérifier volume :
```bash
gcloud monitoring metrics-descriptors list --project=$PROJECT_ID \
  --filter="type:prometheus.googleapis.com" | wc -l
```

Pour purger, il faut supprimer les `PodMonitoring` et attendre expiration TTL (pas de delete direct des séries).

---

## 6. Purge Terraform state (uniquement si abandon projet)

**Attention destructif — état perdu.**

```bash
# Backup avant
gcloud storage cp -r "gs://$TFSTATE_BUCKET/" "gs://$TFSTATE_BUCKET-backup-$(date +%Y%m%d)/"

# Suppression
gcloud storage rm -r "gs://$TFSTATE_BUCKET/"
gcloud storage buckets delete "gs://$TFSTATE_BUCKET"
```

---

## 7. Décommissionnement complet du projet

Cas : fin définitive de la campagne, plus jamais besoin.

```bash
# 1. Cleanup toutes ressources
tools/cleanup-orphans.sh

# 2. Vérifier zéro coût projeté
tools/budget-check.sh

# 3. Backup état + résultats
gcloud storage cp -r "gs://$TFSTATE_BUCKET/" "gs://bendimu-archive-$(date +%Y%m%d)/"
gcloud storage cp -r "results/" "gs://bendimu-archive-$(date +%Y%m%d)/"

# 4. Supprimer projet (30 jours de délai avant deletion définitive)
gcloud projects delete $PROJECT_ID
```

**Le projet reste récupérable pendant 30 jours** (`gcloud projects undelete $PROJECT_ID`).

---

## 8. Checklist finale post-campagne

- [ ] Tous scripts `99-destroy.sh` exécutés (V0, V1, V2)
- [ ] `tools/cleanup-orphans.sh --dry-run` retourne 0 ressource facturante
- [ ] `tools/budget-check.sh` : prévision fin de mois < 5 USD
- [ ] Résultats JSON copiés depuis `results/` vers un stockage pérenne
- [ ] Captures Grafana archivées (PNG)
- [ ] Tag git final `campaign-<date>-completed`
- [ ] `.env` conservé localement (jamais commité) ou détruit selon politique
- [ ] Repo GitHub : dernier push effectué, résultats archivés en release tag

---

## 9. Fréquence recommandée cleanup

| Cadence | Action |
|---|---|
| **Après chaque script `0X-*.sh`** | Rien (`99-destroy.sh` se fait en fin de version) |
| **Après chaque version (V0, V1, V2)** | `99-destroy.sh` + `cleanup-orphans.sh --dry-run` |
| **Fin de journée de travail** | `budget-check.sh` — vérifier consommation |
| **Fin de campagne** | Section 8 ci-dessus |
| **Fin de projet** | Section 7 (décommissionnement) |
