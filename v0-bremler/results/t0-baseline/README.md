# V0 T0 Baseline — État session Sep 12 2026

## Contexte
Reproduction Bremler-Barr 2024 — palier de charge Fortio sans mesh sur
cluster `bremler-v0` (GKE zonal europe-west1-b, k8s 1.35.6-gke.1250000,
7× n2-standard-4).

Charge : 3 endpoints × 7 paliers RPS × 120s.

## Résultats capturés (21 tests)

| Endpoint | Valides | Partiels | Notes |
|---|---|---|---|
| `/` (root) | 7/7 | 0 | Baseline propre |
| `/data10kb` | 7/7 | 0 | 5 en `-c 200`, 2 rerun en `-c 100` (8000/12800) |
| `/data1mb` | 2/7 | 5 | 100rps + 500rps OK. 1000/2000/4000/8000/12800 = 925B partiels |

**Total valides pour analyse : 16/21 (76%)**

## Cause partiels `/data1mb` haute RPS

DNS local jitter (systemd-resolved uplink drop) → `gke-gcloud-auth-plugin`
refresh token échoue → `kubectl exec fortio` avorté avant début run.

Pas de saturation SUT ni indisponibilité GKE control plane.

Preuve : contenu `data1mb-1000rps.json` = 925B avec message
`Failed to resolve 'oauth2.googleapis.com' ([Errno -3] Temporary failure in name resolution)`.

## Fix appliqué (post-baseline)

`sudo /etc/systemd/resolved.conf.d/bendimu.conf` :
```ini
[Resolve]
DNS=1.1.1.1 8.8.8.8
FallbackDNS=1.0.0.1 8.8.4.4
Cache=yes
```

DNS statique + fallback + cache → élimine dépendance uplink flaky.

Vérif post-fix : `resolvectl status` montre `1.1.1.1 8.8.8.8` + fallback.

## Reprise après destroy — checklist

1. Recréer cluster : `cd v0-bremler && bash scripts/00-provision.sh`
   (durée ~10 min, coût ~1.48 USD/h)
2. Rerun 5 partiels `/data1mb` uniquement (1000/2000/4000/8000/12800 RPS)
   avec params baseline originaux (`-c 200 -t 120s`) — DNS fix devrait
   maintenant permettre run complet.
3. Si 5/5 valides → passer à T1 Istio (`bash scripts/02-istio.sh`)
4. Sinon → investigation supplémentaire avant T1.

## Commits associés

- `7999c46` : bootstrap Terraform + provider fix
- `1e541e1` : STABLE channel + K8s 1.35.6 + backend V0/V1/V2
- `a33f865` : Fortio `-nocatchup` + `gcloud monitoring` obsolète
- Prochain : ce commit = archive résultats T0 + STATE

## Fichiers générés

```
21 JSON Fortio load results (72KB valides, 925B partiels)
memory-baseline.json (vide — gcloud monitoring cmd obsolète)
```
