# Amendement 04 — audit mTLS croisé

**Objectif** : vérifier que l'application `PeerAuthentication STRICT` (Istio) et `authentication.mode=required` (Cilium) est effective pour 100 % du trafic. Aucune connexion clair tolérée.

**Justification** : sans cet audit, un doute persiste sur la validité du T2/T3 (mTLS annoncé mais peut-être partiel). Amendement méthodologique de contrôle.

**Outils** :
- `istioctl authn tls-check` pour Istio
- `cilium hubble observe --type l7` pour Cilium
- Comparaison spec Berlin Group via `scripts/03-audit-obp.sh` (OBP-API OpenAPI diff)

**Sortie** : `results/istio-tls-check.txt`, `results/cilium-hubble.json`, `../../results/audit-obp/audit-obp.md`.
