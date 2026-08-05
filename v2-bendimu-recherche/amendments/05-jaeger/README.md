# Amendement 05 — Jaeger

**Objectif** : activer tracing distribué Jaeger (sampling 100 %) et mesurer l'impact sur la latence dataplane.

**Justification** : la télémétrie détaillée est courante en production. Cet amendement quantifie son coût pour chaque dataplane. Envoy sidecar émet plus de spans que Cilium (parsing L7 plus riche).

**Attendu** : overhead p99 : +5 à +15 ms côté Istio, +2 à +8 ms côté Cilium.

**Rejouer** : `../../scripts/01-run-amendments.sh --amendment=05`.
