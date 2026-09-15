# Synthèse V1 Bendimu


## H1 — Δ réseau Istio vs Cilium (RPS=12800)

| Endpoint | Istio p99 (ms) | Cilium p99 (ms) | Δ (ms) | H1 |
|---|---|---|---|---|
| aisp | 120.0 | 120.0 | +0.0 | ❌ |
| authorize | 221.3 | 220.2 | +1.1 | ❌ |
| execute | 416.0 | 419.0 | -3.0 | ❌ |

## H2 — Overhead applicatif mesh (isolé du délai fixe)

| Endpoint | Δ = p99 - délai fixe (Istio) | Δ = p99 - délai fixe (Cilium) |
|---|---|---|
| aisp | +20.0 ms | +20.0 ms |
| authorize | +21.3 ms | +20.2 ms |
| execute | +16.0 ms | +19.0 ms |

**Verdict H1 :** réfutée (0/3 endpoints)
**Verdict H2 :** dépend interprétation domaine (voir docs/03 §1)