# 02 — Runbook V0 : Reproduction Bremler-Barr 2024

**Objectif :** reproduire les chiffres publiés dans Bremler-Barr et al. 2024 sur GKE, avec l'artefact officiel `simulated_tls_server`. Cette version est **l'ancre méthodologique** du protocole Bendimu : sans elle, les Δ V1/V2 ne sont pas interprétables.

**Pré-requis :** [01-setup-gcp.md](01-setup-gcp.md) validé + bootstrap Terraform appliqué.

**Durée estimée :** 8-11 h (provision 25 min + T0 + 3 mesh × **3 runs** × 40 min + cross-check + destroy + re-runs échecs).

**Coût estimé :** **25-30 USD** avec Ambient et 3 runs par mesh (rigueur stat). Sans Ambient : 18-22 USD.

**Décomposition** :
- Compute (7 × `n2-standard-4` + 450 GB PD-SSD 70/50 GB par node + fee cluster GKE) ≈ 1.56 USD/h × 11 h = **17.2 USD**
- GMP ingestion (Cilium metrics + Envoy `stats_prometheus` sur 11 h) ≈ **4 USD**
- LB forwarding + Cloud NAT + Logging résiduel ≈ 1 USD
- Marge re-runs (30 %) déjà incluse dans les 11 h.

**Critère GO/NO-GO :** écart p99 ≤ 15 %, écart mémoire ≤ 20 %, saturation détectée autour de 12 800 RPS. Sans validation V0, **ne pas passer à V1**.

---

## 1. Chiffres cibles Bremler-Barr 2024

| Métrique | Istio sidecar | Cilium eBPF | Ambient (option) |
|---|---|---|---|
| p99 latence `/data10kb` @ 12 800 RPS | **600 ms** | **440 ms** | ~500 ms |
| RSS mémoire /pod dataplane | **255 MiB** | **26 MiB** | ~120 MiB |
| Saturation RPS max (5 nodes n2-standard-4) | ~13 000 | ~14 000 | ~13 500 |
| Overhead p50 vs baseline | +12 ms | +3 ms | +8 ms |

**Tolérance mémoire :** notre banc doit rester dans **±20 %** de ces chiffres pour valider V0. Dans le cas contraire, investiguer avant de continuer.

---

## 2. Topologie déployée

```
GKE cluster : bendimu-v0 (europe-west1-b)
├─ Node pool "sut"    : 5 × n2-standard-4  (SUT + mesh)
└─ Node pool "load"   : 2 × n2-standard-4  (Fortio DaemonSet)

Namespaces :
├─ bendimu-sut    : SUT + PeerAuth STRICT (V0 mesh runs)
├─ bendimu-load   : Fortio DaemonSet
├─ istio-system   : Istio 1.22.6 (V0 aligné Bremler)
├─ kube-system    : Cilium 1.16.3 OSS
└─ gmp-system     : Google Managed Prometheus
```

---

## 3. Séquence complète

### 3.1 Provision cluster

```bash
cd ~/Desktop/bendimu-experiments/v0-bremler
source ../.env
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# éditer terraform.tfvars : project_id, region, node counts

./scripts/00-provision.sh
```

Le script :
1. `terraform init -backend-config=...` sur le state bucket
2. `terraform plan -out=v0.plan`
3. Affiche le plan et **demande confirmation interactive** (Y/N)
4. `terraform apply v0.plan`
5. Configure `kubectl` : `gcloud container clusters get-credentials bendimu-v0 --zone=europe-west1-b`
6. Installe Cilium OSS 1.16.3 via Helm (values `../shared/helm-values/cilium-v0.yaml`)
7. Installe Istio 1.22.6 profile `default` avec `istioctl-1.22`
8. Applique `PodMonitoring` GMP pour Cilium + Envoy
9. Tag git : `v0-provisioned`

**Vérifications post-provision :**
```bash
kubectl get nodes -o wide
# doit lister 7 nodes Ready

cilium status
# doit afficher "Cilium: OK, Operator: OK, Hubble Relay: OK"

istioctl version
# doit afficher client 1.22.6 ET control plane 1.22.6

kubectl get podmonitoring -n gmp-system
# doit lister cilium-agent + envoy-sidecar
```

Si l'un des checks échoue → **NE PAS CONTINUER**. Voir [05-troubleshooting.md](05-troubleshooting.md).

---

### 3.2 Baseline sans mesh (T0)

```bash
./scripts/01-baseline.sh
```

Ce script :
1. Déploie `simulated_tls_server` (image `yanivdocker92/simulated_tls_server:0.0.3`) dans `bendimu-sut` sans injection sidecar, sans NetworkPolicy Cilium
2. Attend `Ready` 5/5 réplicas
3. Déploie Fortio DaemonSet dans `bendimu-load` (2 pods sur 2 nodes load)
4. Charge progressive : 100 → 500 → 1 000 → 2 000 → 4 000 → 8 000 → 12 800 RPS, palier 2 min, `-no-catchup -jitter -uniform`
5. Endpoints : `/`, `/data10kb`, `/data1mb` (ratio 33/33/33)
6. Écrit résultats JSON dans `results/t0-baseline/`
7. Scrape RSS mémoire pod SUT via GMP
8. Tag git : `v0-t0-ok`

**Sortie attendue :**
```
results/t0-baseline/
├── palier-100-rps.json
├── palier-500-rps.json
├── ...
├── palier-12800-rps.json
├── memory-sut-baseline.csv
└── summary-t0.json
```

**Critère validation T0 :** p99 `/data10kb` @ 12800 RPS < 50 ms (baseline sans mesh doit être quasi-directe).

---

### 3.3 Mesh Istio sidecar (T1)

```bash
./scripts/02-istio.sh
```

1. Label namespace `bendimu-sut` : `istio-injection=enabled`
2. Rollout SUT (force re-création pods avec sidecar Envoy)
3. Applique `PeerAuthentication STRICT` sur `bendimu-sut`
4. Applique `BackendConfig` HTTP/2 health check port 15021 (exception STRICT pour LB Google)
5. Vérifie mTLS : `istioctl authn tls-check` doit retourner `STATUS: OK`
6. **Interdit port-forward** : Fortio reste dans un pod injecté du namespace mesh
7. Même palier de charge que T0
8. Ratio charge : 33/33/33
9. Résultats : `results/t1-istio/`
10. Scrape RSS Envoy sidecar (attendu ~255 MiB @ saturation)
11. Tag git : `v0-t1-ok`

**Critère validation T1 :**
- p99 `/data10kb` @ 12800 RPS ∈ [510 ms, 690 ms] (600 ± 15 %)
- RSS sidecar Envoy ∈ [204, 306] MiB (255 ± 20 %)

---

### 3.4 Mesh Cilium eBPF (T2)

```bash
./scripts/03-cilium.sh
```

1. Retire label `istio-injection` et rollout (pods sans sidecar)
2. Applique `CiliumNetworkPolicy` L7 HTTP + `CiliumClusterwideEnvoyConfig` avec mTLS
3. Enable Cilium mutual auth (`cilium config set enable-mutual-auth true` + rollout DaemonSet)
4. Vérifie eBPF programs chargés : `cilium status --verbose | grep -A5 "eBPF"`
5. Palier de charge identique
6. Résultats : `results/t2-cilium/`
7. Scrape RSS `cilium-agent` (attendu ~26 MiB par pod)
8. Tag git : `v0-t2-ok`

**Critère validation T2 :**
- p99 `/data10kb` @ 12800 RPS ∈ [374 ms, 506 ms] (440 ± 15 %)
- RSS cilium-agent ∈ [20, 32] MiB (26 ± 20 %)

---

### 3.5 Ambient (optionnel — extension récente Bremler)

```bash
./scripts/04-ambient.sh
```

Bremler-Barr 2024 étendu avec un run Ambient (ztunnel) — utile pour compléter le tableau mais **non bloquant** pour V0.

1. Uninstall Istio sidecar
2. Réinstall avec profile `ambient` (istioctl 1.22.6+)
3. Label namespace `istio.io/dataplane-mode=ambient`
4. Vérifie ztunnel démarré
5. Palier de charge
6. Résultats : `results/t3-ambient/`

**Peut être sauté** — le protocole Bendimu se concentre sur DPA-1 vs DPA-3. Ambient est bonus.

---

### 3.6 Cross-check statistique

```bash
python scripts/05-cross-check.py
```

Le script :
1. Charge tous les JSON `results/t{0,1,2,3}/summary-*.json`
2. Calcule Δ p99 vs Bremler pour chaque mesh
3. Calcule Δ RSS vs Bremler
4. Test Mann-Whitney sur distribution latence (300 samples par palier)
5. Écrit `results/cross-check-v0.md` :
   - Tableau final Δ vs cible
   - Verdict GO / NO-GO explicite
6. **Exit code 0 = GO, exit code 1 = NO-GO**

Exemple sortie GO :
```
V0 GO — écart moyen p99 = 8.4 %, écart moyen RSS = 12.1 %
Istio p99=612 ms  (target 600, Δ +2.0%)  ✅
Cilium p99=458 ms (target 440, Δ +4.1%)  ✅
Ambient p99=478 ms (target 500, Δ -4.4%) ✅
Passer à V1 : ./v1-bendimu/scripts/00-provision.sh
```

Exemple NO-GO :
```
V0 NO-GO — Cilium p99=580 ms hors tolérance (target 440, Δ +31.8%)
Investigation requise avant V1 :
  - Vérifier Cilium OSS version (1.16.3 ?)
  - Vérifier MTU node (attendu 1460)
  - Vérifier mutual auth activé
  - Consulter docs/05-troubleshooting.md §C1
```

---

### 3.7 Destruction

```bash
./scripts/99-destroy.sh
```

Le script :
1. Uninstall Istio + Cilium (évite ressources orphelines LB)
2. Supprime namespaces `bendimu-sut`, `bendimu-load`
3. `terraform destroy` sur le cluster
4. Vérifie **explicitement** absence de PD orphelins, LB forwarding rules, IP externes réservées
5. Écrit `results/teardown-v0.log`

**JAMAIS oublier ce script.** Un cluster GKE oublié = ~150 USD/mois. Voir [06-cleanup.md](06-cleanup.md) pour la vérification systématique post-destroy.

---

## 4. Checklist V0 complète

- [ ] `00-provision.sh` → cluster Ready, mesh installés
- [ ] `01-baseline.sh` → baseline T0 saine
- [ ] `02-istio.sh` → T1 dans tolérance Bremler ±15 %/20 %
- [ ] `03-cilium.sh` → T2 dans tolérance Bremler ±15 %/20 %
- [ ] `04-ambient.sh` (optionnel) → T3 capturé
- [ ] `05-cross-check.py` → exit 0
- [ ] `99-destroy.sh` → cluster détruit, `tools/cleanup-orphans.sh` clean
- [ ] Tag git `v0-validated` posé

Si toutes cases OK → passer à [03-v1-bendimu.md](03-v1-bendimu.md).

---

## 5. Modes d'échec V0 spécifiques (issus du bench local)

| # | Symptôme | Cause probable | Action |
|---|---|---|---|
| V0-E1 | `istio_requests_total = 0` malgré trafic | Fortio hors mesh (via port-forward ou LB direct) | Vérifier pod Fortio a label `istio-injection` OU tourne dans namespace injecté |
| V0-E2 | Cilium `ImagePullBackOff` | `image.useDigest=true` avec image miroir Artifact Registry (digest ≠) | Values Helm : `image.useDigest: false` |
| V0-E3 | LB Google health checks failing sur pod injecté | `PeerAuth STRICT` bloque probes non-mTLS | `BackendConfig` port 15021 (Envoy status port hors STRICT) |
| V0-E4 | Fortio timeout après 30 s | `-no-catchup` absent, backlog s'accumule | Toujours `-no-catchup -jitter` sur runs > 60 s |
| V0-E5 | p99 baseline anormalement élevé | Fortio et SUT sur mêmes nodes → contention | Node selector strict sur pool `load` vs pool `sut` |

Détail complet des modes d'échec dans [05-troubleshooting.md](05-troubleshooting.md).
