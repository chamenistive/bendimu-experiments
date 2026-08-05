# Amendement 09 — Bank of Anthos

**Objectif** : refaire T2 (Istio) et T3 (Cilium) sur un SUT complètement différent — **Bank of Anthos** (6 microservices banking Java/Python/Go, publiés par Google).

**Justification** : c'est le test de **validité externe** du protocole Bendimu. Si le rang Istio-vs-Cilium tient sur un SUT réel hétérogène, la conclusion se généralise. Sinon, elle est dépendante du SUT synthétique V1.

**Attendu** : même hiérarchie de performance qu'en V1 (Cilium ≤ Istio p99), quelle que soit la répartition trafic Bank of Anthos.

**Rejouer** : `../../scripts/01-run-amendments.sh --amendment=09` (délègue à `02-run-external-anthos.sh`).
