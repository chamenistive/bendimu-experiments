# Bendimu Experiments — Service Mesh DPA-1 vs DPA-3 sous mTLS Open Banking

Dépôt d'expérimentation du protocole **Bendimu** pour le mémoire M2 « Évaluer la performance des Service Mesh à Sidecar et caractériser l'apport d'une architecture eBPF, aux niveaux réseau et applicatif, pour des microservices Open Banking sécurisés par mTLS ».

**Auteur :** CHAMENI LEUDJIEU MIDREL STIVE — Master 2 Génie Logiciel.

**Superviseurs :** Pr. DJAM XAVERIA YOUH KIMBI · Dr. MESSI NGUELE THOMAS.

---

## Architecture du dépôt

```
bendimu-experiments/
├── bootstrap/              # Setup initial GCP (SA + bucket state + APIs)
├── shared/                 # Modules Terraform réutilisables
│   └── modules/
│       ├── gke-cluster/
│       ├── monitoring/
│       └── budget-alerts/
├── v0-bremler/             # Reproduction Bremler-Barr 2024 (base ancrage)
├── v1-bendimu/             # Bendimu-présentation (adaptations Open Banking)
├── v2-bendimu-recherche/   # Bendimu + 9 amendements analyse croisée
├── docs/                   # Guides étape par étape
├── tools/                  # Utilitaires (budget, quota, cleanup)
└── .github/workflows/      # CI (lint + validate)
```

---

## Chaîne causale V0 → V1 → V2

| Version | Objectif | SUT | Critère GO/NO-GO |
|---|---|---|---|
| **V0** | Reproduire Bremler-Barr 2024 | `simulated_tls_server` intact | Écart p99 ≤ 15 %, mémoire ≤ 20 %, saturation ≈ 12 800 RPS |
| **V1** | Bendimu adapté Open Banking | `simulated_tls_server` + handlers PSD2 | H1 (réseau) et H2 (applicatif) testés |
| **V2** | 9 amendements + validité externe | V1 primaire + Bank of Anthos + OBP audit | Chaque amendement attribué causalement + triangulation |

---

## Prérequis

Consulter [docs/00-prerequis.md](docs/00-prerequis.md).

**Outils minimum :** `gcloud` ≥ 470, `kubectl` ≥ 1.30, `helm` ≥ 3.14, `terraform` ≥ 1.7, `istioctl` ≥ 1.24, `cilium` CLI ≥ 0.16, `docker`, `jq`, `yq`, `go` ≥ 1.22, `python` ≥ 3.10.

---

## Démarrage rapide (Quick Start)

```bash
# 1. Cloner ce dépôt
git clone https://github.com/<TON-USER>/bendimu-experiments.git
cd bendimu-experiments

# 2. Copier template environnement
cp .env.example .env
# → Éditer .env avec tes valeurs GCP

# 3. Bootstrap (une seule fois — crée SA + bucket state + active APIs)
cd bootstrap
terraform init
terraform apply

# 4. Lancer V0 (reproduction Bremler)
cd ../v0-bremler
./scripts/00-provision.sh
./scripts/01-baseline.sh
./scripts/02-istio.sh
./scripts/03-cilium.sh
./scripts/04-ambient.sh
python scripts/05-cross-check.py
# → Si GO : passer à V1
./scripts/99-destroy.sh

# 5. Lancer V1 (Bendimu-présentation)
cd ../v1-bendimu
./scripts/00-provision.sh
# ... séquence T0 → T4 ...
./scripts/99-destroy.sh

# 6. Lancer V2 (Bendimu-recherche)
cd ../v2-bendimu-recherche
./scripts/00-provision.sh
# ... amendements + Bank of Anthos ...
./scripts/99-destroy.sh
```

Détails complets : [docs/](docs/).

---

## Documentation par phase

| Guide | Description |
|---|---|
| [00-prerequis.md](docs/00-prerequis.md) | Installation outils locaux |
| [01-setup-gcp.md](docs/01-setup-gcp.md) | Configuration compte GCP + facturation + APIs + Service Account |
| [02-v0-bremler.md](docs/02-v0-bremler.md) | Runbook V0 pas-à-pas |
| [03-v1-bendimu.md](docs/03-v1-bendimu.md) | Runbook V1 pas-à-pas |
| [04-v2-recherche.md](docs/04-v2-recherche.md) | Runbook V2 pas-à-pas + 9 amendements |
| [05-troubleshooting.md](docs/05-troubleshooting.md) | Problèmes fréquents + solutions |
| [06-cleanup.md](docs/06-cleanup.md) | Destruction ressources + vérification zéro coût résiduel |

---

## Budget GCP

Crédit prévu : **300 USD** (compte académique UY1 `stive.chameni@facsciences-uy1.cm`).

**Estimation honnête campagne complète (avec 3 runs par mesh, re-runs sur échecs 30 %)** :

| Version | Compute | GMP | Autres | **Total** |
|---|---|---|---|---|
| V0 (avec Ambient, 11 h) | 18.5 | 4 | 1 | **25-30 USD** |
| V1 (avec T4, 15-16 h) | 26-28 | 8-12 | 1-5 | **40-55 USD** |
| V2 (22 h, 9 amendements + Anthos) | 38-43 | 15-25 | 5-10 | **65-100 USD** |
| Bootstrap + idle inter-campagnes | | | | 5-10 USD |
| **Total 1ère pass** | | | | **135-195 USD** |
| **+ Re-run intégral si échec méthodo** | | | | **+40-60 USD** |
| **Total prudent (à budgétiser)** | | | | **175-255 USD** |

Marge sur les 300 USD : **~50-125 USD**. Confortable pour la campagne standard, **insuffisant** si on active :
- Multi-region cross-cluster (V2 étendu) : +30-50 USD
- Runs statistiques > 3 par mesh (n=5 recommandé articles) : +30 % sur V0/V1
- Sauvegardes GMP long terme (rétention 24 mois par défaut) : ~5-15 USD/mois post-campagne

**Poste critique caché** : GMP ingestion sur V2 (cardinality × 9 amendements). Sans `Telemetry` API drop labels côté Istio, peut grimper à 25 USD sur V2 seul.

**Garde-fous en place :**
- Alertes budget à 50 % / 80 % / 95 % / 100 % (email `stive.chameni@facsciences-uy1.cm`)
- `tools/budget-check.sh` (check quotidien via GitHub Actions cron 06:00 UTC)
- `tools/cleanup-orphans.sh` (détection cluster/PD/LB orphelins)
- Destruction obligatoire cluster après chaque phase (`99-destroy.sh`)
- **Interdiction** de laisser un cluster idle > 1 h hors bench (150 USD/mois par cluster oublié).

---

## Traçabilité

Chaque exécution produit :
- Résultats JSON Fortio dans `v*/results/`
- Captures Grafana PNG (à archiver manuellement)
- Logs Terraform (`terraform.log`)
- Tag git à chaque étape critique (`v0-baseline-ok`, `v1-t2-ok`, `v2-amend-3-ok`, etc.)

---

## Licence

Apache 2.0 — voir [LICENSE](LICENSE).

---

## Références

- Bremler-Barr et al. 2024 — benchmark multi-mesh mTLS
- NIST SP 800-233 (Chandramouli et al. 2024) — taxonomie DPA
- Høiland-Jørgensen et al. 2018 — XDP (borne 24 Mpps/cœur)
- Brandner et al. 2026 (ETH) — L7FP eBPF offloading
- + 5 autres articles analyse croisée (voir `docs/`)
