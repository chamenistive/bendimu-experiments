# Amendement 02 — hugepages

**Objectif** : activer les hugepages 2 Mi sur les nodes SUT (`vm.nr_hugepages`) et mesurer l'impact sur la TLB pressure du dataplane.

**Justification** : eBPF (Cilium) et Envoy manipulent de gros pools mémoire. Les hugepages réduisent le nombre d'entrées TLB nécessaires → moins de miss cache CPU → latence plus stable.

**Attendu** : p99 en baisse plus marquée côté Cilium (eBPF plus sensible à la localité TLB).

**Rejouer** : `../../scripts/01-run-amendments.sh --amendment=02`.
