# Amendement 03 — ambient

**Objectif** : substituer Istio sidecar par Istio Ambient mode (ztunnel + waypoint), sans changer aucune autre variable.

**Justification** : Ambient est la nouvelle architecture Istio (2024+) qui supprime le sidecar Envoy par pod pour un ztunnel L4 par node + waypoint L7 optionnel. Isole le coût du sidecar per-pod.

**Attendu** : p99 intermédiaire entre Istio classique (T2) et Cilium eBPF (T3). RSS mémoire divisé par 5-10.

**Exécution** : nécessite `istioctl uninstall + install --set profile=ambient`. Le script auto ne le fait pas pour préserver l'état T2/T3 — lancer manuellement selon `docs/04 §5`.
