# 03 — Runbook V1 : Bendimu-Présentation (Adaptations Open Banking)

**Objectif :** évaluer H1 (niveau réseau) et H2 (niveau applicatif) du protocole Bendimu sur un SUT identique à V0 étendu de 3 handlers PSD2 synthétiques conformes Berlin Group NextGenPSD2. Toute variation V1 vs V0 est attribuable aux adaptations Bendimu (pas au changement de SUT).

**Pré-requis :** [02-v0-bremler.md](02-v0-bremler.md) validé (tag git `v0-validated`).

**Durée estimée :** **12-16 h** (provision + build image + 5 phases T0→T4 × 3 runs par mesh + synthèse + re-runs).

**Coût estimé :** **40-55 USD** avec T4 (2 clusters × 1 h). Sans T4 : **30-40 USD**.

**Décomposition** :
- Compute cluster principal (identique V0 + pool obs) ≈ 1.71 USD/h × 15 h = **26 USD**
- 2ème cluster T4 (1 h, ressources identiques) ≈ **1.7 USD**
- GMP ingestion (cardinality × 3 endpoints PSD2 + labels mesh) ≈ **8-12 USD** (poste sensible)
- Cloud Logging (traces Envoy si Telemetry filter oublié) : 0-5 USD
- Cloud NAT (pulls images Artifact Registry) + LB : ~1 USD

**Piège cardinality** : sans `Telemetry` API filter (drop labels `source_workload_namespace`, `destination_workload_namespace`, `request_protocol`, `response_flags`), GMP peut monter à 25 USD. Appliquer le filter en T2 est **obligatoire**.

**Critère GO/NO-GO :** H1 attribué (Δ réseau visible entre Istio et Cilium), H2 attribué (overhead applicatif quantifié par endpoint PSD2).

---

## 1. Hypothèses testées

| Hypothèse | Formulation | Preuve attendue |
|---|---|---|
| **H1** | Cilium/eBPF réduit la latence réseau vs Istio sidecar sous mTLS strict pour des microservices PSD2 | Δ p99 réseau = latence mesurée − délai fixe endpoint, comparaison Istio vs Cilium par endpoint |
| **H2** | L'overhead applicatif (parsing L7, télémétrie, filters) diffère significativement entre les deux dataplanes | Overhead applicatif = latence mesh − latence baseline, décomposition par phase (auth, parse, forward) |

---

## 2. SUT V1 (nouveauté vs V0)

Image custom : `europe-west1-docker.pkg.dev/${PROJECT_ID}/bendimu-images/sut-v1:1.0.0`

Base : Go 1.23 → scratch multi-stage → **5.24 Mo**, non-root (65532), read-only fs, `SecurityContext.capabilities.drop=[ALL]`.

**Endpoints hérités Bremler (V0-compat) :**
- `GET /` — page HTML minimale
- `GET /data10kb` — 10 KB aléatoires
- `GET /data1mb` — 1 MB aléatoires

**Endpoints PSD2 synthétiques (V1 nouveaux) :**

| Endpoint | Méthode | Délai fixe | Payload cible | Source spec |
|---|---|---|---|---|
| `/aisp/accounts` | GET | 100 ms | 512 B JSON | Berlin Group XS2A `/v1/accounts` |
| `/pisp/authorize` | POST | 200 ms | 256 B JSON, code 201 | Berlin Group `/v1/payments/{payment-service}/authorisations` |
| `/pisp/execute` | POST | 400 ms | 1 KB JSON | Berlin Group `/v1/payments/{payment-service}` (execute) |

**Endpoint healthcheck :** `/healthz` — hors mesures, non compté dans latence agrégée.

**Ratio de charge V1 :** 60 / 30 / 10 (AISP dominant, PISP autorisation moyen, PISP exécution rare).

Le code Go est dans `v1-bendimu/tls-server/main.go`. Compilation + push image via `01-t0-baseline-reseau.sh` (première étape).

---

## 3. Topologie déployée

Identique V0 avec ajout d'un troisième node pool observabilité pour absorber le volume GMP :

```
GKE cluster : bendimu-v1 (europe-west1-b)
├─ Node pool "sut"    : 5 × n2-standard-4  (SUT + mesh)  — preemptible OFF
├─ Node pool "load"   : 2 × n2-standard-4  (Fortio DaemonSet)  — preemptible OFF
└─ Node pool "obs"    : 1 × n2-standard-2  (agents divers)  — preemptible ON
```

---

## 4. Séquence complète (T0 → T4)

### 4.1 Provision

```bash
cd ~/Desktop/bendimu-experiments/v1-bendimu
source ../.env
cp terraform/terraform.tfvars.example terraform/terraform.tfvars

./scripts/00-provision.sh
```

Similaire V0 mais :
- Cluster `bendimu-v1`
- **Istio 1.24.0** (pas 1.22.6 — on adopte la version courante pour tester Bendimu contre le mesh moderne)
- Cilium OSS 1.16.3 (identique V0 pour comparaison réseau)
- Node pool `obs` supplémentaire
- Tag git : `v1-provisioned`

**Vérification supplémentaire :**
```bash
istioctl version   # doit afficher 1.24.0
istioctl analyze -A  # zéro warning attendu
```

---

### 4.2 T0 — Baseline réseau pure (sans mesh, sans mTLS)

```bash
./scripts/01-t0-baseline-reseau.sh
```

Étapes :
1. **Build image** `sut-v1:1.0.0` depuis `tls-server/`
2. **Push** vers Artifact Registry `bendimu-images`
3. Applique manifests SUT dans `bendimu-sut-v1` (aucune injection, aucune PeerAuth)
4. Applique Fortio DaemonSet
5. Palier de charge : 100 → 500 → 1 000 → 2 000 → 4 000 → 8 000 → 12 800 RPS, palier 2 min, `-nocatchup -jitter`
6. 3 runs séparés (un par endpoint PSD2), ratios respectés au niveau du DaemonSet
7. Résultats : `results/t0-baseline-reseau/`
   - `aisp-{palier}.json`
   - `authorize-{palier}.json`
   - `execute-{palier}.json`
8. Scrape latence réseau brut (aucune télémétrie mesh)
9. Tag git : `v1-t0-ok`

**Attendu :**
- p99 `/aisp/accounts` ≈ 100 ms (délai fixe + < 1 ms overhead réseau GKE)
- p99 `/pisp/authorize` ≈ 200 ms
- p99 `/pisp/execute` ≈ 400 ms

Tout écart > 5 ms sur ces cibles indique un problème de dimensionnement (contention, MTU, node saturation).

---

### 4.3 T1 — Baseline applicative (sans mesh, mTLS applicatif natif Go)

```bash
./scripts/02-t1-baseline-appli.sh
```

Étapes :
1. Redéploie SUT V1 avec **mTLS applicatif implémenté en Go stdlib** (`crypto/tls` sur les endpoints PSD2)
2. Certificats auto-signés via `openssl` dans `secrets/`
3. Fortio configuré avec certificat client
4. Palier identique T0
5. Résultats : `results/t1-baseline-appli/`
6. Tag git : `v1-t1-ok`

**Objectif :** isoler le coût du chiffrement/handshake TLS **sans** le dataplane mesh. Sert de référence pour évaluer H2 (overhead applicatif mesh spécifique).

**Attendu :** p99 augmente de +5 à +15 ms par endpoint (coût TLS pur).

---

### 4.4 T2 — Istio sidecar + mTLS STRICT

```bash
./scripts/03-t2-istio-mtls.sh
```

Étapes :
1. Retire mTLS applicatif Go du SUT (revient V0-style)
2. Label namespace `bendimu-sut-v1` : `istio-injection=enabled`
3. Rollout
4. Applique :
   - `PeerAuthentication STRICT` sur `bendimu-sut-v1`
   - `PortLevelMtls` exception port 15021 (health checks LB)
   - `BackendConfig` HTTP/2
   - `Telemetry` filter (drop labels : `source_workload_namespace`, `destination_workload_namespace`, `request_protocol`, `response_flags`) — cardinality control
5. Vérifie mTLS : `istioctl authn tls-check`
6. Palier identique
7. Résultats : `results/t2-istio-mtls/`
8. Scrape Envoy sidecar : RSS, connections actives, CPU
9. Tag git : `v1-t2-ok`

**Attendu :**
- p99 `/aisp/accounts` : 105 – 130 ms (overhead +5 à +30 ms)
- p99 `/pisp/execute` : 405 – 420 ms (overhead +5 à +20 ms)
- RSS Envoy sidecar : 200 – 260 MiB (charge PSD2 < charge Bremler stress test)

---

### 4.5 T3 — Cilium eBPF + mutual auth

```bash
./scripts/04-t3-cilium-mtls.sh
```

Étapes :
1. Retire injection Istio, rollout SUT sans sidecar
2. Applique `CiliumNetworkPolicy` L7 + `CiliumClusterwideEnvoyConfig`
3. Enable mutual auth : `cilium config set enable-mutual-auth true`
4. Rollout Cilium DaemonSet
5. Vérifie eBPF programs : `cilium sysdump` (archivé dans `results/`)
6. Palier identique
7. Résultats : `results/t3-cilium-mtls/`
8. Scrape `cilium-agent` : RSS, eBPF maps size, drops
9. Tag git : `v1-t3-ok`

**Attendu :**
- p99 `/aisp/accounts` : 101 – 115 ms (overhead +1 à +15 ms — H1 : Cilium < Istio)
- RSS cilium-agent : 20 – 40 MiB

---

### 4.6 T4 — Stress convergent SÉQUENTIEL (T4a Istio → T4b Cilium, même cluster)

```bash
./scripts/05-t4-stress.sh
```

**Séquentiel et non parallèle** — conforme méthodologie Bremler-Barr 2024 (§4 : uninstall/reinstall même cluster).

Étapes :
1. **T4a — Stress Istio** : cluster déjà en état T2, charge 3× nominale = **38 400 RPS agrégé** (3 paliers : 12800, 25600, 38400), 3 min par palier
2. Uninstall Istio complet (`istioctl uninstall --purge`) + rollout SUT + vérif zéro sidecar résiduel
3. **Idle 5 min** — clear cache kernel, stabilisation
4. Install Cilium OSS 1.16.3 + mutual auth sur le **même cluster**
5. **Idle 5 min** — warmup eBPF maps
6. **T4b — Stress Cilium** : même palier de charge (12800, 25600, 38400)
7. Résultats : `results/t4a-stress-istio/` et `results/t4b-stress-cilium/`
8. Tags git : `v1-t4a-ok`, `v1-t4b-ok`, `v1-t4-ok`

**Avantages séquentiel vs parallèle 2 clusters** :
- Fidélité littérature Bremler-Barr 2024 (approche officielle du paper)
- Élimine variance hardware/zone GCP inter-cluster (même nodes, même NIC, même kernel scheduler)
- Reproductibilité renforcée
- Coût divisé par 2 (~4 USD au lieu de ~8 USD)
- Consommation quota SSD divisée par 2 (450 GB au lieu de 900 GB) → passe sous quota Free-Trial-upgraded

**Durée T4** : ~90 min (T4a 30 min + transition 15 min + T4b 30 min + tag).

**Coût T4** : ~4 USD. Peut être **skippé** si budget serré, non requis pour H1/H2 (T2 + T3 suffisent).

---

### 4.7 Synthèse H1 + H2

```bash
python scripts/06-synthese-h1-h2.py
```

Le script :
1. Charge tous les JSON `results/t{0..4}/*.json`
2. Calcule pour chaque endpoint et chaque paliers :
   - Latence réseau pure (T0)
   - Latence + TLS applicatif (T1)
   - Latence + Istio mTLS (T2)
   - Latence + Cilium mTLS (T3)
3. Décompose overhead :
   - Overhead réseau mesh = T{2,3} − T0
   - Overhead applicatif mesh = T{2,3} − T1 (isole coût dataplane spécifique hors TLS)
4. Test Wilcoxon signed-rank pour significativité H1
5. Effect size Cohen's d pour H2
6. Écrit `results/synthese-v1.md` :
   - Tableau H1 : Δ réseau Istio vs Cilium par endpoint (avec p-value)
   - Tableau H2 : décomposition overhead applicatif par endpoint
   - Verdict : H1 validée/réfutée, H2 validée/réfutée
7. Génère 3 graphiques `results/plots/` (histogrammes latence, boxplot par mesh, courbe overhead vs RPS)

---

### 4.8 Destruction

```bash
./scripts/99-destroy.sh
```

Identique V0-destroy avec vérification supplémentaire du cluster stress `bendimu-v1-stress` (si T4 lancé). Le script détruit **les deux clusters** si présents.

---

## 5. Checklist V1

- [ ] `00-provision.sh` → cluster + mesh Ready
- [ ] Image `sut-v1:1.0.0` buildée + poussée Artifact Registry
- [ ] `01-t0-baseline-reseau.sh` → p99 endpoints alignés délai fixe ±5 ms
- [ ] `02-t1-baseline-appli.sh` → TLS applicatif isolé
- [ ] `03-t2-istio-mtls.sh` → mesh Istio mesuré, `istioctl authn tls-check` OK
- [ ] `04-t3-cilium-mtls.sh` → mesh Cilium mesuré, mutual auth ON
- [ ] `05-t4-stress.sh` (optionnel) → point de rupture caractérisé
- [ ] `06-synthese-h1-h2.py` → H1 + H2 verdicts posés
- [ ] `99-destroy.sh` → clusters détruits, orphelins nettoyés
- [ ] Tag git `v1-validated`

Si toutes cases OK → passer à [04-v2-recherche.md](04-v2-recherche.md).

---

## 6. Modes d'échec V1 spécifiques (issus du bench local)

| # | Symptôme | Cause | Action |
|---|---|---|---|
| V1-E1 | Charge « auto-catchup » gonfle p99 artificiellement | Défaut Fortio | **Toujours** `-nocatchup -jitter -uniform` |
| V1-E2 | `execute` p99 = 400 ms strict (aucune variance) | Endpoint code Go sans jitter | OK — c'est le comportement attendu, délai déterministe |
| V1-E3 | `authorize` retourne 200 au lieu de 201 | Handler mal implémenté | Vérifier `w.WriteHeader(http.StatusCreated)` dans main.go |
| V1-E4 | Sidecar Envoy expose `istio_agent_*` uniquement | Aucun trafic mesh encore passé | Injecter trafic AVANT scrape (attente 30 s minimum) |
| V1-E5 | Ratio 60/30/10 non respecté dans results | Fortio `-qps` alloué globalement au lieu de par endpoint | Utiliser 3 runs séparés avec QPS calculé (60% × total, 30% × total, 10% × total) |
| V1-E6 | Cilium mutual auth ne s'active pas | Version < 1.14 | Vérifier `cilium version` ≥ 1.14 |
| V1-E7 | Cardinality Prometheus explose (>10 M samples/min) | Telemetry v2 verbose par défaut | Appliquer `Telemetry` API drop labels (fait par T2) |

Détail complet dans [05-troubleshooting.md](05-troubleshooting.md).
