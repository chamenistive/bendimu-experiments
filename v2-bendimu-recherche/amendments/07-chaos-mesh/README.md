# Amendement 07 — Chaos Mesh

**Objectif** : injecter des perturbations contrôlées (pod-kill toutes les 30 s, network partition) pendant le run, mesurer la résilience du dataplane.

**Justification** : la résilience compte autant que la performance nominale pour un système Open Banking PSD2. Cet amendement produit des chiffres de MTTR (mean time to recovery) et de taux d'erreur 5xx sous chaos.

**Attendu** : Cilium récupère plus vite (état L3/L4 réhydraté depuis eBPF maps), moins d'erreurs 5xx. Istio recharge le sidecar → 2-5 s de trou.

**Rejouer** : `../../scripts/01-run-amendments.sh --amendment=07`.
