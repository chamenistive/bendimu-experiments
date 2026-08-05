# Amendement 08 — endpoints PSD2 étendus

**Objectif** : ajouter des endpoints PSD2 supplémentaires (SCA challenge, batch transfers, refund) au SUT V1 pour diversifier la charge applicative.

**Justification** : V1 ne mesure que 3 endpoints (`/aisp/accounts`, `/pisp/authorize`, `/pisp/execute`). Cet amendement teste si le verdict Bendimu tient sur une surface plus large.

**Nécessite** : extension de `v1-bendimu/tls-server/main.go` avec les nouveaux handlers. Rebuild image, push AR, redeploy SUT.

**Attendu** : rang Istio-vs-Cilium **inchangé** — sinon menace validité interne du résultat V1.
