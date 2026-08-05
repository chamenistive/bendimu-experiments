# 04 — Runbook V2 : Bendimu-Recherche (9 amendements + validité externe)

**Objectif :** durcir le protocole Bendimu par 9 amendements méthodologiques et confronter les résultats à deux SUT externes (Bank of Anthos, OBP-API) pour établir la validité externe des conclusions H1/H2.

**Pré-requis :** [03-v1-bendimu.md](03-v1-bendimu.md) validé (tag git `v1-validated`).

**Durée estimée :** **18-22 h répartis sur 2-3 jours** (baseline T2/T3 rechargée + 9 amendements + Anthos + OBP + synthèse + re-runs).

**Coût estimé :** **65-100 USD** sans multi-region cross-cluster (poste dominant : GMP ingestion sur 22 h avec cardinality élevée).

**Décomposition** :
- Compute (cluster principal, 22 h) : 22 × 1.71 = **38 USD**
- Node pool Anthos additionnel (3 h) : **~5 USD**
- **GMP ingestion (cardinality × 9 amendements) : 15-25 USD** ← poste critique
- Cloud Logging (Jaeger sampling 100 % + Chaos events) : **~5 USD**
- Cross-region éventuel (si extension amendement 08 ou variante multi-cluster) : **+30-50 USD** → **à éviter sur budget 300 USD**

**Détail par amendement** (durée × 1.71 USD/h idle + GMP) :

| # | Amendement | Durée typique | Coût compute |
|---|---|---|---|
| 01-pktgen | install trex + run | 1 h | 1.7 USD |
| 02-hugepages | daemonset + run | 45 min | 1.3 USD |
| 03-ambient | uninstall/reinstall Istio | 2 h | 3.4 USD |
| 04-audit-mtls | audit seul, léger | 30 min | 0.9 USD |
| 05-jaeger | operator + sampling 100 % | 1 h 30 | 2.6 USD |
| 06-score-composite | bench standard + collect | 1 h | 1.7 USD |
| 07-chaos-mesh | install + PodChaos | 1 h 30 | 2.6 USD |
| 08-endpoints-psd2 | rebuild image + redeploy | 1 h 30 | 2.6 USD |
| 09-bank-of-anthos | deploy + Locust | 3 h | 5 USD (+ 3 USD pool) |

**Sommes hors GMP** : ~26 USD compute pur pour les 9 amendements + baseline T2/T3 (4 h à 6.8 USD) + audit OBP.

**Critère GO/NO-GO :** au moins 7/9 amendements convergent avec V1, triangulation Anthos + OBP concordante.

---

## 1. Les 9 amendements

Chaque amendement isole **une** variable méthodologique et re-lance la mesure Cilium vs Istio. La comparaison avec V1 identifie si le résultat V1 est robuste ou artefact. **Nomenclature alignée sur le dossier `amendments/{01..09}-*/`** :

| # | Amendement | Variable isolée | Attendu |
|---|---|---|---|
| **01-pktgen** | Générateur de paquets bas-niveau | Charge réseau instrumentée hors HTTP | Signal dataplane isolé du bruit applicatif |
| **02-hugepages** | Hugepages 2 Mi côté nodes SUT | TLB pressure kernel | Latence p99 baisse pour Cilium (eBPF sensible TLB) |
| **03-ambient** | Istio Ambient mode | Coût sidecar per-pod isolé | Ambient p99 intermédiaire entre Istio classique et Cilium |
| **04-audit-mtls** | Audit croisé mTLS (OBP + istioctl + hubble) | Vérification effective STRICT + auth required | Zéro trafic clair détecté |
| **05-jaeger** | Tracing distribué Jaeger, sampling 100 % | Impact télémétrie sur latence | Overhead ≈ 5-15 ms, plus fort côté Envoy sidecar |
| **06-score-composite** | Métrique agrégée (p99 × RSS × CPU) | Compromis triple au lieu de p99 seul | Ordre relatif peut basculer selon pondération |
| **07-chaos-mesh** | Chaos engineering (pod-kill toutes les 30 s) | Résilience dataplane sous perturbation | Cilium récupère plus vite, moins d'erreurs 5xx |
| **08-endpoints-psd2** | Endpoints PSD2 étendus (SCA challenge, batch) | Diversification charge applicative | Rang inchangé si vraiment robuste |
| **09-bank-of-anthos** | SUT hétérogène Bank of Anthos | Validité externe (généralisation) | Même hiérarchie de perf malgré changement de SUT |

Chaque amendement = 1 fonction dans `01-run-amendments.sh`, résultats dans `amendments/NN-*/results/`.
Lancer un seul : `./scripts/01-run-amendments.sh --amendment=05` — tout : `--all`.

---

## 2. Séquence complète

### 2.1 Provision cluster V2

```bash
cd ~/Desktop/bendimu-experiments/v2-bendimu-recherche
source ../.env
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# éditer terraform.tfvars : multi_zone=true (pour A1), extra_clusters=["us-central1","asia-east1"] (pour A8)

./scripts/00-provision.sh
```

Le script provisionne :
- Cluster principal `bendimu-v2` europe-west1 avec **3 zones** (b, c, d)
- (Sur demande, si `A8=true`) Clusters secondaires `bendimu-v2-us` et `bendimu-v2-asia`
- Istio 1.24 + Cilium OSS 1.16.3 (identique V1)
- Ambient mode installable via feature flag (pour A6)

**Coût provision :** ~2 USD/h × 1 cluster. **Multi-cluster (A8) : ×3.**

---

### 2.2 Exécution des 9 amendements

```bash
./scripts/01-run-amendments.sh --all
# ou individuellement :
./scripts/01-run-amendments.sh --amendment=01
./scripts/01-run-amendments.sh --amendment=05
# ... (NN=01..09)
```

Chaque amendement :
1. Applique le changement de configuration (helm upgrade, kubectl patch, cilium config)
2. Attend stabilité 60 s post-changement
3. Palier de charge V1 identique (100 → 12800 RPS)
4. Ratio 60/30/10
5. Écrit `results/amendment-Ax/*.json`
6. Rollback à la config baseline pour amendement suivant
7. Tag git `v2-Ax-ok`

**Ordre recommandé :** A1 → A9 dans l'ordre (isolation croissante). **A8 en dernier** (coût élevé multi-region).

---

### 2.3 Validité externe — Bank of Anthos

```bash
./scripts/02-run-external-anthos.sh
```

Bank of Anthos = 6 microservices banking (Java, Python, Go) publiés par Google Cloud sous Apache 2.0. SUT hétérogène qui teste la généralisation Bendimu au-delà du `simulated_tls_server`.

Étapes :
1. Clone `https://github.com/GoogleCloudPlatform/bank-of-anthos`
2. Deploy dans namespace `boa`
3. Applique Istio injection + PeerAuth STRICT sur `boa` → **run mesh Istio**
4. Applique CiliumNetworkPolicy L7 + mutual auth → **run mesh Cilium**
5. Charge : Locust script fourni par Google (transactions bancaires réalistes)
6. Résultats : `results/external-anthos/`
7. Compare rang Istio/Cilium avec V1 → doit être **concordant**

**Attendu :** même hiérarchie de performance qu'en V1 malgré SUT complètement différent. Si non → V1 dépend du SUT (menace validité externe).

---

### 2.4 Audit sémantique — OBP-API

```bash
./scripts/03-audit-obp.sh
```

OBP = Open Bank Project API, monolithe Scala, 500+ endpoints PSD2 réels. **Trop lourd pour bench charge**, sert uniquement à valider :
- Nos 3 endpoints synthétiques V1 (`/aisp/accounts`, `/pisp/authorize`, `/pisp/execute`) sont **représentatifs** de la surface PSD2 réelle
- Payload sizes et méthodes HTTP alignés

Étapes :
1. Deploy OBP sandbox en pod K8s (non instrumenté)
2. Compare via `openapi-diff` la spec OBP vs nos handlers V1
3. Écrit `results/audit-obp.md` :
   - Taux de couverture surface PSD2 par nos endpoints (attendu ≥ 40 %)
   - Écarts identifiés (méthodes, payload sizes, codes retour)
   - Verdict : représentativité **validée / invalidée**

---

### 2.5 Synthèse V2

```bash
python scripts/04-synthese-v2.py
```

Le script :
1. Charge results/amendment-A{1..9}/*.json
2. Charge results/external-anthos/*.json
3. Charge results/audit-obp.md
4. Pour chaque amendement, teste convergence avec V1 :
   - Rang Istio/Cilium préservé ?
   - Δ latence dans ±30 % de V1 ?
5. Triangulation SUT : V1 (synthétique) + Anthos (réel hétérogène) + OBP (spec) convergents ?
6. Score global de validité (0-100)
7. Écrit `results/synthese-v2.md` :
   - Tableau récapitulatif 9 amendements (Convergent / Divergent / Ambigu)
   - Analyse triangulation
   - Verdict final Bendimu : **robuste / partiel / fragile**
8. Graphiques : radar 9 amendements, comparaison croisée SUT

---

### 2.6 Destruction

```bash
./scripts/99-destroy.sh
```

Destroy multi-cluster : script détruit `bendimu-v2` + `bendimu-v2-us` + `bendimu-v2-asia` (si présents) + purge Artifact Registry des tags temporaires.

---

## 3. Checklist V2

- [ ] `00-provision.sh` → cluster(s) + mesh Ready
- [ ] 9 amendements exécutés, `amendments/NN-*/results/` complets
- [ ] Bank of Anthos deployé et mesuré
- [ ] Audit OBP produit (spec comparison)
- [ ] `04-synthese-v2.py` → score global ≥ 70/100
- [ ] `99-destroy.sh` → tous clusters détruits, `tools/cleanup-orphans.sh` clean
- [ ] Tag git `v2-validated`

Si toutes cases OK → **campagne Bendimu complète**. Passer à [06-cleanup.md](06-cleanup.md) pour vérification finale.

---

## 4. Modes d'échec V2 spécifiques

| # | Symptôme | Cause | Action |
|---|---|---|---|
| V2-E1 | Amendement A1 multi-zone → latence énorme (+50 ms) | Pods SUT et Fortio dans zones différentes | Utiliser `podAntiAffinity` + `topologySpreadConstraints` |
| V2-E2 | A4 CPU limit → sidecar OOM en boucle | Limit trop basse | Vérifier `500m` = 0.5 CPU, pas 500 CPU |
| V2-E3 | A8 multi-region → coût explose (>20 USD/h) | 3 clusters × LB × egress | Réduire durée A8 à 30 min max |
| V2-E4 | Anthos Locust script fail | Version Anthos incompatible cluster GKE 1.31 | Fixer version `git checkout release/v0.6.5` |
| V2-E5 | OBP pod OOM au démarrage | JVM mal dimensionnée | `-Xmx4g` + node `n2-standard-4` obligatoire |
| V2-E6 | Synthèse convergence divergente (rang inversé) | Bien vérifier baseline V1 rechargée correctement | Regarder logs `04-synthese-v2.py` |

Détail complet dans [05-troubleshooting.md](05-troubleshooting.md).
