---
name: Bug report
about: Signaler un problème d'exécution du protocole Bendimu
labels: bug
---

**Contexte**
- Version : V0 / V1 / V2 / bootstrap / tools
- Script échoué : `path/du/script.sh`
- Cluster : `bendimu-vX`
- Region : `europe-west9`

**Comportement observé**
Ce qui s'est passé.

**Comportement attendu**
Ce qui aurait dû se passer (ex : `terraform apply` OK, `cross-check.py` exit 0).

**Reproduction**
1. `source .env`
2. `./scripts/00-provision.sh`
3. …

**Logs**
```
coller la sortie d'erreur
```

**État GCP au moment du bug**
- `gcloud container clusters list` :
- `kubectl get pod -A | grep -v Running` :

**Vérifications déjà tentées**
- [ ] `docs/05-troubleshooting.md` consulté (section applicable : …)
- [ ] `tools/quota-check.sh` OK
- [ ] `terraform plan` sans erreur avant apply
