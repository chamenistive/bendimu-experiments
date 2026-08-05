# Amendement 01 — pktgen

**Objectif** : substituer Fortio HTTP par un générateur de paquets bas-niveau (`trex` ou `pktgen-dpdk`) pour isoler le comportement dataplane du parsing HTTP.

**Justification** : le protocole V1 mesure l'aller-retour HTTP complet. pktgen retire la couche parsing L7 et permet d'observer le coût pur du dataplane (Envoy vs eBPF) sur du trafic TCP synthétique.

**Attendu** : signal dataplane isolé, Δ Istio-Cilium plus net qu'en V1.

**Rejouer** : `../../scripts/01-run-amendments.sh --amendment=01`.

**Résultats** : `results/*.json`.
