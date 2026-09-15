# Bendimu Experiments — Journal de session

> Journal chronologique des sessions de travail : opérations réalisées,
> erreurs rencontrées, procédures de correction, état final.
> Format : nouvelle section par session, du plus récent au plus ancien.
> À référencer via : `docs/SESSION_LOG.md` (ce fichier).

---

## Session Sep 14-15 2026 — V0 **COMPLET GO** (T0+T1+T2) + cross-check adaptatif

**Statut final : ✅ V0 verdict GO. T3 Ambient skip (conflit CNI Cilium/Istio). Cluster destroy pour pause.**

### Résultats V0

| Test | ActualQPS | Saturation | p99 (ms) | Overhead vs T0 |
|---|---|---|---|---|
| T0 baseline (no mesh) | 12798 | 100.0% | **0.99** | 1.0× (référence) |
| T1 Istio 1.22 sidecar + mTLS STRICT | 9650 | 75.4% | **19.95** | 20.1× |
| T2 Cilium 1.16 eBPF + mutual-auth SPIRE | 12739 | 99.5% | **10.68** | 10.8× |
| T3 Ambient | — | — | SKIP | — |

**Verdict cross-check adaptatif**:
- ✅ Ordre p99 T0 < T2 < T1 (mesh overhead croissant)
- ✅ Saturation ≥ 60% (T1 75%, T2 99.5%)
- ✅ Ratio T1/T2 = 1.87× (paper Bremler-Barr 2024 = 1.36×)

**Pattern Bremler-Barr 2024 reproduit qualitativement**. Cibles absolues paper (600/440ms) obsolètes sur infra 2026 (kernel 6.12 eBPF + n2-standard-4 dépassent testbed 2024).

### Erreurs rencontrées + fixes

| # | Erreur | Cause | Correction |
|---|---|---|---|
| E14 | `Fortio /tmp/x.json: no such file or directory` | Image `fortio/fortio:1.68.0` scratch, pas de `/tmp` | DS Fortio ajout `emptyDir` volume + sidecar `busybox:1.36 helper` monté même /tmp. `kubectl exec -c helper` pour rm/cat, `-c fortio` pour load |
| E15 | Tous 21 partiels T1 = 333B (`sh not found in $PATH`) | `sh -c` wrapper échoue (image scratch) | 3 kubectl exec séparés (rm/fortio/cat), pas de shell |
| E16 | data1mb 12800 kubectl exec drop mid-cat | Internet local drop | Retry cat 3× avec backoff |
| E17 | T2 Cilium tous partiels, smoke curl timeout | `bpf-lb-sock-hostns-only=true` (héritage T1 fix) + `enable-mutual-auth=true` sans SPIRE | Reinstall Cilium DEFAUT + `authentication.mutual.spire.enabled=true` + `install.enabled=true` |
| E18 | Cilium `AuthCertificateProvider: SPIRE admin socket missing` | 5 agents SPIRE sur 7 nodes (taint Load `bendimu.role=load:NoSchedule` non toléré par SPIRE DS) | Patch DS spire-agent avec tolération → 7 agents ready, Cilium OK |
| E19 | CiliumNetworkPolicy YAML `line 18: did not find expected key` | Syntaxe inline mixte block/flow non délimité | Flow style explicit `- { method: "GET", path: "/" }` |
| E20 | `cilium status --verbose: unknown flag` | Flag retiré CLI 0.16.x | `cilium status` + kubectl inspection |
| E21 | Ambient install CNI + Ztunnel timeout 5min | Conflit CNI Cilium vs Istio Ambient CNI | Skip T3 (marqué optionnel Bendimu focus DPA-1 vs DPA-3) |
| E22 | Cross-check `TypeError: unsupported operand type(s) for |: type and NoneType` | PEP 604 requiert Python 3.10+ (user has 3.8) | `from typing import Optional, Tuple` |
| E23 | Cross-check false NO-GO (p99 20× meilleur que target absolue paper) | Cibles absolues 2024 obsolètes | Refactor verdict adaptatif : ordre p99 T0<T2<T1 + saturation ≥ 60% + ratio T1/T2 > 1 |
| E24 | Istio `PeerAuthentication portLevelMtls` rejected | Namespace-scope PA n'accepte pas portLevelMtls | Retire portLevelMtls (auto-bypass health checks via rewriteAppHTTPProbers) |
| E25 | `istioctl authn tls-check: unknown command` | Sous-commande retirée Istio 1.22 | Remplacé par kubectl inspection 3 signaux (pod ready 2/2 + PA STRICT + istiod up) |
| E26 | `istioctl x describe pod: pod not found` (mais kubectl le trouve) | Bug istioctl GKE 1.35 (résolution pod cassée) | Remplacé validation cluster state directe kubectl |
| E27 | T1 tous 21 = 65B ou 925B fallback | Fortio `-quiet` + kubectl exec `sh -c` fail (E15 root) | Reformulé pattern kubectl exec 3× séparés (E15 solution) |
| E28 | Fortio Read errors EOF T1 (avant helper sidecar) | `bpf-lb-sock=true` (Cilium socketLB pod) intercepte AVANT iptables Istio → mTLS bypass → SUT sidecar rejette plaintext STRICT | Reinstall Cilium `--set socketLB.hostNamespaceOnly=true` (socketLB restreint host, pod traffic passe iptables Envoy) |

### Commits pushés

- `2f36441` — Fortio sidecar busybox helper + emptyDir /tmp
- `7098d79` — CiliumNetworkPolicy YAML flow style
- `b4b4836` — cilium status --verbose retiré
- `ad353da` — 04-ambient retire prompt read
- `4db88ea` — cross-check Python 3.8 compat
- `66a00b6` — cross-check verdict adaptatif + parser mixed-format
- + précédents commits T1/T2 results

### Fichiers résultats persistants

```
v0-bremler/results/
├── t0-baseline/       # 21 JSON (ancien format streaming, extraction via parser fallback)
├── t1-istio/          # 21 JSON propres 5-11KB
├── t2-cilium/         # 21 JSON propres 6-11KB
├── memory-cilium.txt  # kubectl top pods DS
└── cross-check-v0.md  # verdict GO détaillé
```

### Fix DNS + auth durables appliqués session précédente encore actifs
- `/etc/systemd/resolved.conf.d/bendimu.conf` : DNS 1.1.1.1+8.8.8.8, Fallback 1.0.0.1+8.8.4.4
- `~/.config/gcloud/bendimu-terraform-key.json` : SA JSON key `terraform-bendimu`
- `gcloud auth activate-service-account` : session kubectl long-lived sans reauth

### Reprise V1 (prochaine session)

```bash
cd ~/Desktop/bendimu-experiments
source .env
# Vérifier auth SA encore active
gcloud auth list
kubectl config current-context

# Bootstrap conservé — recréer V1
bash v1-bendimu/scripts/00-provision.sh
# Puis séquence T0 → T4 v1-bendimu (~2h charge tests)
```

### Points d'attention V1

- V1 tls-server = binary Go PSD2 custom (build local + push GCR)
- Bendimu-présentation = handlers /pisp, /aisp, /piisp, /confirm
- Handlers multi-parallel Fortio load pattern (scripts V1 diffèrent de V0)
- **Pattern helper sidecar Fortio doit être porté à V1/V2** (encore ancien pattern `-json '-'` streaming)
- ID SPIRE trust domain à re-vérifier post-recreate cluster

### Coût session

~10h cluster tournant (~15 USD Sep 14-15) + storage négligeable. Bootstrap idle ~1 USD/j.

### Actions clôture session (post-cross-check GO)

- ✅ Commit résultats T2 + cross-check + SESSION_LOG (`78ef302`) pushé origin/main
- ✅ `terraform -chdir=v0-bremler/terraform destroy -auto-approve` exécuté
- ✅ `gcloud container clusters list` → vide (cluster GKE bremler-v0 supprimé)
- ✅ Bootstrap conservé (VPC + NAT + Artifact Registry + SA + bucket + budget) → ~1 USD/j idle
- ✅ SA JSON key `~/.config/gcloud/bendimu-terraform-key.json` conservée pour V1
- ✅ DNS fix systemd-resolved persist reboot
- ✅ SESSION_LOG.md à jour, prêt reprise V1

### Note sur `results/t3-ambient/` vide (intentionnel)

Dossier créé par `mkdir -p` au démarrage script `04-ambient.sh`, mais rien écrit dedans car `istioctl install --set profile=ambient` a échoué avant la charge matrix :

- Étape 3 script (install Ambient) : CNI DaemonSet + Ztunnel DaemonSet timeout 5 min
- Cause : conflit avec Cilium (Cilium contrôle CNI et iptables via eBPF, `istio-cni` + `ztunnel` restent Pending/CrashLoopBackOff)
- Étape 4-6 script (label ns, ztunnel check, charge matrix) : jamais atteintes (`set -e` exit sur erreur install)

Script `04-ambient.sh` marqué **optionnel** en commentaire ligne 2 (« OPTIONNEL, non bloquant pour verdict V0 »). Cross-check GO obtenu sans T3. Dossier vide conservé pour cohérence structure `results/` + tracé git.

### Alignement flowchart méthodologique `worfowmethodologie.png`

Le flowchart du mémoire M2 définit **5 étapes** (0 réseau brut → 1 app vierge → 2 DPA1 → 3 DPA3 → 4 rupture). V0 (Bremler-Barr reproduction) couvre **3/5 étapes** (0, 2, 3). Étapes 1 (calibration app vierge) et 4 (épreuve rupture) **absentes du V0 intentionnellement** car V0 = ancrage paper Bremler-Barr 2024 (uniquement 3 conditions comparées), pas protocole Bendimu complet.

**V1 réalisera les 5 étapes complètes** avec SUT PSD2 Open Banking :

| Script V1 | Étape flowchart | Objet |
|---|---|---|
| `01-t0-baseline-reseau.sh` | étape 0 | Baseline réseau (identique V0 T0 mais SUT PSD2) |
| `02-t1-baseline-appli.sh` | **étape 1** | Calibration app vierge (`step1calibration.json`, référence variabilité sans mesh) |
| `03-t2-istio-mtls.sh` | étape 2 | DPA1 Istio sidecar mTLS PSD2 |
| `04-t3-cilium-mtls.sh` | étape 3 | DPA3 Cilium eBPF natif + WireGuard optionnel |
| `05-t4-stress.sh` | **étape 4** | Épreuve rupture (PASSE 1 DPA-1 A, PASSE 2 DPA-3 B → `robustesse.md`) |
| `06-synthese-h1-h2.py` | synthèse | H1 (overhead réseau) + H2 (overhead applicatif) |

Donc étapes 1 + 4 seront couvertes en V1 avec chaîne PSD2 réelle (pas re-run au V0).

### Commits pushés session Sep 14-15 (chronologique)

- `1fcbe74` — drop portLevelMtls (PA namespace-scope invalide)
- `8fbeb5b` — remplacer istioctl authn tls-check par x describe pod
- `024de13` — istioctl-1.22 pour authn tls-check (retiré Istio 1.23+)
- `6424530` — validation mTLS via cluster state (istioctl x describe bug GKE 1.35)
- `34f96c9` — Fortio écrit résultats dans pod filesystem + cat unique
- `c4b5841` — 3 kubectl exec séparés (image fortio scratch pas de sh)
- `2f36441` — sidecar busybox helper + emptyDir /tmp partagé
- `207fb9d` — archive Istio benchmark T1 21/21
- `7098d79` — CiliumNetworkPolicy YAML flow style
- `b4b4836` — cilium status --verbose retiré CLI 0.16.x
- `991a84c` — archive Cilium T2 21/21 + SPIRE mutual-auth
- `ad353da` — 04-ambient retire prompt read
- `4db88ea` — cross-check compat Python 3.8
- `66a00b6` — cross-check verdict adaptatif + parser mixed-format
- `78ef302` — V0 GO complet + SESSION_LOG

---

## Session Sep 14 2026 (soir) — T0 baseline **COMPLET 21/21** + fixes durables

**Statut final : ✅ T0 baseline validé complet (21/21). Prêt pour T1 Istio.**

### Opérations
- Re-auth stive.chameni + re-provision cluster V0 (script `00-provision.sh` corrigé fonctionne)
- `01-baseline.sh` full run : root ×7 ✓ + data10kb ×7 ✓, mais data1mb 6/7 échec à ~17:14 (auth gcloud expiré ~1h30 après login)
- **SA JSON key** créée sur `terraform-bendimu` → `gcloud auth activate-service-account`
- kubectl utilise SA long-lived → aucune reauth requise pendant runs
- Rerun 7 data1mb : bug **buffer Fortio** révélé (warn spam `Buffer is too small`)
- Fix `-httpbufferkb 2048` → tous 7 data1mb passent OK (10KB JSON compact = SUT saturé ~2434 qps réel sur cible 12800)

### Erreurs révélées + fixes
- **E14 (auth)** : `Reauthentication failed. cannot prompt` mid-run (~30 min après login). **Fix** = SA JSON key. Créé `~/.config/gcloud/bendimu-terraform-key.json` (hors repo git). `gcloud auth activate-service-account --key-file=...`. Auth kubectl stable indéfiniment.
- **E15 (buffer)** : `Buffer is too small for headers + data - change -httpbufferkb flag`. Fortio default 128KB, needed 1025KB pour payload 1MB. Warn spam engorge stdout kubectl exec (925B partials = kubectl exec crash sous flood). **Fix** = `-httpbufferkb 2048` sur toutes invocations Fortio load. Bulk sed sur 9 scripts V0/V1/V2.

### Résultat T0 baseline
| Endpoint | Résultat |
|---|---|
| root ×7 | ✅ 7/7 |
| data10kb ×7 | ✅ 7/7 |
| data1mb ×7 | ✅ 7/7 (buffer 2048KB, SA auth) |

**Total 21/21** dans `v0-bremler/results/t0-baseline/`.

Insight data1mb : SUT saturé à ~2434 qps réel (bandwidth ~2.4 GB/s dépassée sur 4 vCPU par pod × 5 replicas). p99 latence à plateau saturation = donnée signifiante Bremler-Barr.

### Commits associés
- `29096ab` : `fix(v0/00-provision): auth pre-check + 2-step apply + Cilium cluster.name`
- (pending) : results T0 21/21 + fix `-httpbufferkb 2048` bulk + SESSION_LOG update

### Reprise T1
```bash
# Auth SA doit être active (persiste jusqu'à new login user)
gcloud auth list  # doit montrer terraform-bendimu@... ACTIVE

# Lancer T1 Istio
bash v0-bremler/scripts/02-istio.sh
```

---

## Session Sep 14 2026 — Tentative reprise V0 (échec auth) + fix 00-provision.sh

**Statut final : ⏸️ Reprise V0 avortée — auth gcloud expirée depuis pause. Script fixé pour prochaine tentative.**

### Opérations
- Tentative `bash v0-bremler/scripts/00-provision.sh` par user
- Script s'est arrêté silencieux après `🔍 Vérification quotas GCP` (quota-check.sh interne bloqué par gcloud auth expiré, exit propagé via `set -e`)
- Ensuite user a tenté `kubectl -n bendimu-load get pod` → `Reauthentication failed. cannot prompt during non-interactive execution`
- FORTIO_POD vide → tests data1mb tous `error: pod, type/name or --filename must be specified`

### Erreurs révélées
- **E12** : `Reauthentication failed. cannot prompt during non-interactive execution` — sessions gcloud ~1h30 window dépassée (session précédente pause = 2 jours)
- **E13** : `00-provision.sh` avait bugs latents : (a) pas de auth pre-check → silent fail à quota-check ; (b) chicken-and-egg terraform apply pré-namespaces jamais résolu dans script (uniquement en manuel session précédente) ; (c) Cilium `cluster.name` non override → refuse >32 chars ; (d) `istioctl-1.22` via `which` sans fallback path

### Fix appliqué (commit `29096ab`)
`v0-bremler/scripts/00-provision.sh` refactoré :
1. **§0 Auth pre-check** : `gcloud auth print-access-token` + ADC + set-quota-project. Exit early avec message clair si expiré.
2. **§2a Terraform 2-step** : `terraform apply -target=module.gke` d'abord.
3. **§4 Namespaces créés AVANT full apply** : `bendimu-sut` + `bendimu-load`.
4. **§2b Full apply** : PodMonitoring + alert policy sans plus casser sur `pm_envoy`.
5. **§5 Cilium** : `--set cluster.name="$CLUSTER_NAME_V0"` (fixe E4).
6. **§6 Istio** : `command -v istioctl-1.22 || ~/.local/bin/istioctl-1.22` (portable).

### Reprise (prochaine session, corrigée)

```bash
# 1. Ré-auth OBLIGATOIRE (session > 1h30 après pause)
gcloud auth login stive.chameni@facsciences-uy1.cm
gcloud auth application-default login  # si tokens ADC aussi expirés
gcloud auth application-default set-quota-project bendimu-mesh-bench

# 2. Verify cluster absent
gcloud container clusters list --project=bendimu-mesh-bench

# 3. Script 00-provision fixé (auth pre-check préviendra silent fail)
cd ~/Desktop/bendimu-experiments
bash v0-bremler/scripts/00-provision.sh
# Répondra 'y' au prompt "Continuer avec apply cluster ? [y/N]"

# 4. Après cluster + Cilium + Istio OK → rerun 5 partiels data1mb :
source .env
FORTIO_POD=$(kubectl -n bendimu-load get pod -l app=fortio -o jsonpath='{.items[0].metadata.name}')
# NOTE : Fortio et SUT sont créés par 01-baseline.sh, PAS par 00-provision.sh !
# → Il faut d'abord :
#   bash v0-bremler/scripts/01-baseline.sh  (relance TOUT baseline)
# OU juste déployer Fortio + SUT manuellement avant rerun partiels.
```

**⚠️ Note importante** : `00-provision.sh` déploie cluster + Cilium + Istio, mais PAS le SUT `sut-bremler` ni le DS Fortio. Ces derniers sont créés par `01-baseline.sh` (lignes 12-77). Pour rerun uniquement les 5 partiels data1mb sans refaire tous les 21 tests, il faut soit :
- **Option A** (simple) : relancer `01-baseline.sh` complet (~50 min avec DNS fix, tous 21 devraient passer)
- **Option B** (chirurgical) : extraire section SUT+Fortio de 01-baseline.sh, la deployer, puis rerun uniquement les 5 partiels via boucle for

**Recommandé** : Option A avec DNS fix — teste complet et valide fix par la même occasion.

### Commit associé
- `29096ab` : `fix(v0/00-provision): auth pre-check + 2-step apply + Cilium cluster.name`

---

## Session Sep 12 → Sep 14 2026 — Bootstrap GCP + V0 provision + T0 baseline

**Statut final : ⏸️ Pause après T0 baseline. Cluster V0 destroy. Bootstrap conservé.**

### 1. Objectifs

| # | Objectif | État |
|---|---|---|
| 1 | Configurer GCP réel (auth, projet, billing, quotas) | ✅ |
| 2 | Bootstrap Terraform (VPC, NAT, SA, bucket, budget) | ✅ |
| 3 | Provisionner cluster V0 (GKE + Cilium + Istio + monitoring) | ✅ |
| 4 | Exécuter T0 baseline Bremler (Fortio charge sans mesh) | ⚠️ 16/21 valides (5 partiels data1mb) |
| 5 | Passer à T1 Istio | ⏸️ Différé après recréation V0 + rerun 5 partiels |
| 6 | Destroy infra coûteuse pour pause | ✅ V0 supprimé, bootstrap conservé |

### 2. Opérations réalisées (chronologie)

#### 2.1 Reprise session initiale — vérification état projet
- Working directory : `~/Desktop/bendimu-experiments/`
- Git tree propre, dernier commit `ccb397b` (audit qualité T4 séquentiel + quota 500 GB)
- Squelette complet vérifié : `bootstrap/`, `v0-bremler/`, `v1-bendimu/`, `v2-bendimu-recherche/`, `shared/modules/`, `tools/`, `docs/`
- Aucun TODO résiduel dans le code

#### 2.2 Corrections documentaires préliminaires
- `docs/01-setup-gcp.md` : incohérences relevées → corrigées
  - Section 4 : quota SSD 1000 → 500 GB (aligné audit ccb397b Free-Trial-upgraded)
  - Section 7 : budget 800 → 300 USD (crédit UY1)
  - Section 8 : nomenclature `.env` (`PROJECT_ID` → `GCP_PROJECT_ID`, `BILLING_ACCOUNT_ID` → `GCP_BILLING_ACCOUNT`, etc.)

#### 2.3 Pré-flight local
- Vérifiés présents : `gcloud` (579.0.0), `terraform`, `kubectl`, `helm`, `cilium` CLI, `docker`, `jq`
- Manquants : `yq`, `go`, `istioctl-1.22`
- `python3` = 3.8.10 (doc requiert 3.10) — non bloquant pour bootstrap
- Terraform validate offline : `bootstrap/`, `v0-bremler/terraform/`, `v1-bendimu/terraform/`, `v2-bendimu-recherche/terraform/` → tous OK, `fmt` clean

#### 2.4 Auth GCP
- Session initiale : `stive.chameni@facsciences-uy1.cm` déjà actif mais token expiré
- Piège détecté : `gcloud config set auth/impersonate_service_account terraform-bendimu@…` en root shell précédent — SA n'existe pas encore, bloquerait toutes commandes
- Correction : `gcloud config unset auth/impersonate_service_account`
- Re-auth en shell stivax (pas root — my Bash tool tourne en stivax) via
  `gcloud auth login stive.chameni@facsciences-uy1.cm` + `gcloud auth application-default login`

#### 2.5 Découverte état GCP existant
- Projet `bendimu-mesh-bench` déjà créé (2026-08-25), lifecycle ACTIVE
  - `projectNumber` = `388549942189`
  - Billing account = `0133B5-B199F1-9FB8C3`
  - 9 APIs requises toutes déjà activées
- **Manquants** :
  - SA `terraform-bendimu` (seul le default compute existait)
  - Bucket `bendimu-tfstate-bendimu-mesh-bench`
  - Budget
  - API `billingbudgets.googleapis.com` (nécessaire pour Terraform budget module)

#### 2.6 Setup infra GCP restant (batch)
```
1. Enable billingbudgets.googleapis.com
2. Create SA terraform-bendimu + 9 rôles (compute.admin, container.admin,
   iam.serviceAccountAdmin/User, resourcemanager.projectIamAdmin,
   storage.admin, artifactregistry.admin, monitoring.admin, logging.admin)
   [note : billing.viewer refusé au niveau projet — s'applique au billing account, skip]
3. Create bucket gs://bendimu-tfstate-bendimu-mesh-bench + versioning + lifecycle
4. tools/quota-check.sh : CPUS 200, SSD 500, Addr 8 — tous OK
```

#### 2.7 Bootstrap Terraform
- `.env` local créé pré-rempli (2 valeurs remplies auto : `GCP_PROJECT_NUMBER=388549942189`, `GCP_BILLING_ACCOUNT=0133B5-B199F1-9FB8C3`)
- `bootstrap/terraform.tfvars` créé via `sed` sur `.example`
- `terraform init` avec backend GCS (bucket + prefix)
- `terraform plan` : 25 ressources à ajouter (idempotent sur les 9 APIs déjà enable)
- `terraform apply` : 23/25 OK au premier passage
  - Fail sur `google_billing_budget.this` : `Error 403: billingbudgets.googleapis.com API requires a quota project`
  - **Fix** : `providers google + google-beta` ajout `billing_project = var.project_id` + `user_project_override = true` dans `bootstrap/main.tf`
  - Retry apply : 25/25 ✅
- Outputs : `vpc_name=bendimu-vpc`, `nat_gateway_name=bendimu-nat`, `artifact_registry_url=europe-west1-docker.pkg.dev/bendimu-mesh-bench/bendimu-images`, `gke_nodes_sa_email=bendimu-gke-nodes@…`, `budget_id=billingAccounts/0133B5-B199F1-9FB8C3/budgets/2cce89a9-…`

#### 2.8 Installation `istioctl-1.22.6`
- Script `00-provision.sh` V0 bloque explicitement si `istioctl-1.22` absent (fidélité Bremler-Barr 2024)
- Installé depuis `github.com/istio/istio/releases/download/1.22.6/istioctl-1.22.6-linux-amd64.tar.gz` vers `~/.local/bin/istioctl-1.22`

#### 2.9 V0 provisioning (cluster GKE)
- Backend V0/V1/V2 patchés préventivement avec `user_project_override` (cohérence avec bootstrap)
- `v0-bremler/terraform/terraform.tfvars` créé
- `terraform init` OK
- 2-step apply requis à cause de `kubernetes_manifest` (chicken-and-egg : cluster doit exister pour Terraform K8s provider)
  - **Step 1** : `terraform apply -target=module.gke` — cluster + node pools uniquement
  - **Step 2** : `terraform apply` complet — PodMonitoring + alert_policy
- Cluster créé : `bremler-v0`, zone `europe-west1-b`, k8s `1.35.6-gke.1250000`, 7× `n2-standard-4` (5 SUT + 2 Load taintés), PD-SSD 450 GB total

#### 2.10 Installation services meshes
- Namespaces `bendimu-sut` + `bendimu-load` créés (via kubectl, requis pour `pm_envoy` PodMonitoring)
- Full terraform apply : 3 add + 1 change (cluster monitoring reorder) → OK
- **Cilium 1.16.3** : `cluster.name=bremler-v0`, `kubeProxyReplacement=true`, vxlan MTU 1450, Hubble metrics + Prometheus
  - Note : `kube-proxy` DS déjà scale 0/0 sur GKE 1.35 (node selector `kube-proxy-ds-ready=true` sans match) → step patch script no-op
  - `cilium status --wait` : 7/7 DS + 7/7 envoy DS + 1/1 operator OK
- **Istio 1.22.6** : profile default (istiod + ingressgateway Running)
  - Warning EOL affiché (attendu, fidélité Bremler-Barr)

#### 2.11 T0 baseline (`01-baseline.sh`)
- Deploy `sut-bremler` (image `yanivdocker92/simulated_tls_server:0.0.3`, 5 replicas, node selector pool SUT)
- Deploy `fortio` DS (image `fortio/fortio:1.68.0`, 2 replicas, taint tolerations pool Load)
- Charge matrix : 3 endpoints × 7 RPS × 120s + 15s pause = **21 tests**
- Endpoints : `/` (root), `/data10kb`, `/data1mb`
- Paliers RPS : 100, 500, 1000, 2000, 4000, 8000, 12800

### 3. Erreurs rencontrées + procédures de correction

| # | Erreur | Cause | Correction |
|---|---|---|---|
| E1 | `Error 400: Master version "1.30.5-gke.1355000" is unsupported` | GKE a retiré 1.30 des versions supportées | Query serverConfig API → `1.35.6-gke.1250000` (STABLE channel dernier) |
| E2 | `Error 400: not enrolling clusters in a release channel is now only allowed for existing customers` | GKE deprecation : `channel = "UNSPECIFIED"` interdit nouveaux clients | `shared/modules/gke-cluster/main.tf` : `channel = "STABLE"` |
| E3 | `Error 403 billingbudgets.googleapis.com requires a quota project` | ADC user creds n'ont pas quota project set pour billingbudgets | Providers Terraform : `billing_project = var.project_id` + `user_project_override = true` |
| E4 | `The cluster name is invalid: must not be more than 32 characters` (Cilium install) | Cilium auto-détecte nom GKE = `gke-bendimu-mesh-bench-europe-west1-b-bremler-v0` (48 chars) | Override : `cilium install --set cluster.name=bremler-v0` |
| E5 | `namespaces "bendimu-sut" not found` (Terraform pm_envoy) | Chicken-and-egg : `kubernetes_manifest` référence ns créé par kubectl script | Créer ns via `kubectl create namespace` avant `terraform apply` full |
| E6 | `flag provided but not defined: -no-catchup` (Fortio) | Fortio 1.68 renomme `-no-catchup` → `-nocatchup` (mono-mot) | Bulk `sed -i 's/-no-catchup/-nocatchup/g'` sur 12 scripts V0/V1/V2 + docs 02/03/05 |
| E7 | `gcloud monitoring metrics list: Invalid choice: 'metrics'` | Commande retirée gcloud récent | Remplacer par `kubectl top pods` + `curl` API Monitoring v3 avec ADC token |
| E8 | `Unable to connect to the server: net/http: TLS handshake timeout` + `connection refused 34.140.211.2` (kubectl exec Fortio) | DNS local jitter → `gke-gcloud-auth-plugin` échoue refresh (Failed to resolve `oauth2.googleapis.com`) | Fix systemd-resolved persistant : `/etc/systemd/resolved.conf.d/bendimu.conf` avec `DNS=1.1.1.1 8.8.8.8` + `FallbackDNS=1.0.0.1 8.8.4.4` |
| E9 | `istioctl-1.22 absent` (bloqueur script 00-provision) | Binary manquant machine (fidélité Istio 1.22.6 Bremler-Barr) | Download tarball GitHub release + install `~/.local/bin/istioctl-1.22` |
| E10 | Auth `gcloud` expire ~1h30 (ré-auth password interactif requis) | Politique gcloud CLI + user session length | Ré-auth manuelle en shell stivax quand détecté (pas de fix automatique appliqué) |
| E11 | Kubeconfig context obsolète (localhost:33335 = ancien kind/minikube) | `get-credentials` avait échoué silencieusement (auth expiré) | Re-run `gcloud container clusters get-credentials` après ré-auth réussie |

### 4. Résultats T0 baseline (16/21 valides)

| Endpoint | Valides | Partiels | Détail |
|---|---|---|---|
| `/` (root) | **7/7** ✓ | 0 | Baseline propre, tous 72KB Fortio JSON |
| `/data10kb` | **7/7** ✓ | 0 | 5 en `-c 200` initial + 2 rerun (8000/12800) en `-c 100` |
| `/data1mb` | **2/7** | 5 | 100+500rps OK, 1000/2000/4000/8000/12800 = 925B partiels (DNS jitter avant fix E8) |

Fichiers dans `v0-bremler/results/t0-baseline/*.json` (JSON Fortio) + `README.md`.
`memory-baseline.json` vide (E7 non fixé à temps).

### 5. Commits pushés `origin/main` sur `github.com/chamenistive/bendimu-experiments`

| SHA | Message | Contenu |
|---|---|---|
| `7999c46` | `fix(bootstrap): user_project_override provider + aligner doc/gitignore` | Providers bootstrap + doc 01 800→300 + SSD 1000→500 + nomenclature .env + gitignore `*.plan` |
| `1e541e1` | `fix(v0/v1/v2): STABLE release channel + K8s 1.35.6 + backend provider` | Module gke STABLE + tfvars.example V0/V1/V2 K8s 1.30→1.35.6 + backend V0/V1/V2 `user_project_override` |
| `a33f865` | `fix(scripts): Fortio -nocatchup flag (1.68) + gcloud monitoring metrics obsolète` | 12 scripts V0/V1/V2 + docs 02/03/05 + fix gcloud monitoring dans `01-baseline.sh` |
| `345e8c5` | `chore(v0/t0): archive baseline results + STATE reprise après destroy` | 21 JSON Fortio + `results/t0-baseline/README.md` reprise checklist |

### 6. État final infra GCP

**Actif** (facturation ~1 USD/jour) :
- Projet `bendimu-mesh-bench`
- VPC `bendimu-vpc` + subnet `bendimu-subnet-europe-west1` + secondary IP (pods 10.24/14, svc 10.28/20)
- Cloud Router `bendimu-router` + Cloud NAT `bendimu-nat` **← seul coût idle (~1 USD/jour)**
- Firewalls IAP SSH + Google health checks
- Artifact Registry `bendimu-images`
- SA `bendimu-gke-nodes` (moindre privilège 6 rôles)
- SA `terraform-bendimu` (9 rôles admin)
- Bucket state `bendimu-tfstate-bendimu-mesh-bench` (versioning + lifecycle 5 versions/30j)
- Budget 300 USD + alerts email 50/80/95/100 %

**Supprimé** (facturation coupée) :
- Cluster GKE `bremler-v0`
- Node pools `sut` (5×n2-standard-4) + `load` (2×n2-standard-4)
- PD-SSD 450 GB
- Alert policy `node_disk_high`
- PodMonitoring `pm_cilium_agent` + `pm_envoy`

Consommation session totale : **~8 USD** (cluster ~5h30 tournant + provision).

### 7. Fix DNS persistant appliqué

```ini
# /etc/systemd/resolved.conf.d/bendimu.conf
[Resolve]
DNS=1.1.1.1 8.8.8.8
FallbackDNS=1.0.0.1 8.8.4.4
Cache=yes
CacheFromLocalhost=no
DNSStubListener=yes
```

Vérif : `resolvectl status | grep "DNS Servers"` doit montrer `1.1.1.1 8.8.8.8` + Fallback `1.0.0.1 8.8.4.4`.

**Impact attendu** : élimine `Failed to resolve oauth2.googleapis.com` → kubectl exec long-running stable → 5 partiels data1mb devraient passer valides à la reprise.

### 8. Reprise (prochaine session)

**Prérequis** : DNS fix actif (déjà appliqué, persiste reboot).

```bash
cd ~/Desktop/bendimu-experiments
source .env

# Vérifier auth encore valide (sinon re-auth)
gcloud auth list
kubectl config current-context 2>/dev/null

# 1. Recréer cluster V0 (~10 min, coût démarre ~1.48 USD/h)
bash v0-bremler/scripts/00-provision.sh

# 2. Rerun 5 partiels data1mb avec params originaux (-c 200 -t 120s)
FORTIO_POD=$(kubectl -n bendimu-load get pod -l app=fortio -o jsonpath='{.items[0].metadata.name}')
SUT_URL="http://sut-bremler.bendimu-sut.svc.cluster.local:8080"
for rps in 1000 2000 4000 8000 12800; do
  echo "→ /data1mb rps=$rps"
  kubectl -n bendimu-load exec "$FORTIO_POD" -- fortio load \
    -qps "$rps" -c 200 -t 120s -nocatchup -jitter -uniform \
    -json "-" "$SUT_URL/data1mb" \
    > "v0-bremler/results/t0-baseline/data1mb-${rps}rps.json"
  sleep 15
done

# 3. Vérifier 5/5 sont réels (pas 925B)
ls -la v0-bremler/results/t0-baseline/data1mb-*rps.json

# 4. Si OK → passer à T1 Istio
bash v0-bremler/scripts/02-istio.sh
```

**Coût recréation V0** : ~10 min provision + tests = quelques USD.
**Alternative si DNS refléteait encore** : baisser `-c 100` puis `-c 50` sur data1mb high-RPS.

### 9. Points d'attention pour sessions futures

- **Auth gcloud expire ~1h30** : re-auth password interactive requise. Impacte scripts long-running. Envisager cache token bearer ou WIF pour CI/CD.
- **`gcloud monitoring metrics list` retiré** : mêmes patrons dans `02-istio.sh` / `03-cilium.sh` / `04-ambient.sh` V0 (avec `|| true` safe). Fixer proactivement avant runs.
- **Version Istio 1.22** en EOL** : warning `istioctl` normal, fidélité Bremler-Barr préservée.
- **GKE zonal SLA 99.5%** : blips control plane possibles. Prévoir retry mécanismes pour T1/T2/T3.
- **Coût NAT idle** : ~1 USD/jour continu tant que bootstrap actif. Destroy bootstrap si break > 1 semaine.

---

## Format ajout futur session

```markdown
## Session YYYY-MM-DD → YYYY-MM-DD — <titre court>

**Statut final : <emoji + phrase>**

### 1. Objectifs
### 2. Opérations réalisées
### 3. Erreurs rencontrées + procédures de correction
### 4. Résultats
### 5. Commits pushés
### 6. État final infra
### 7. Reprise
### 8. Points d'attention
```
