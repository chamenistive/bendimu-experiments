# Bootstrap Bendimu

**Rôle** : provisionner l'infrastructure GCP partagée par les trois versions du protocole (V0, V1, V2). À exécuter **une seule fois** avant tout le reste.

**Ressources créées** :
- Réseau VPC `bendimu-vpc` + subnet régional avec ranges secondaires pods/services
- Cloud Router + Cloud NAT (egress internet des pods)
- Firewalls : IAP SSH (35.235.240.0/20), Google health checks (35.191.0.0/16, 130.211.0.0/22)
- Artifact Registry `bendimu-images` (images SUT V1 + éventuels mirrors Cilium/Istio)
- Service Account `bendimu-gke-nodes` avec rôles minimum pour les node pools GKE
- Budget mensuel USD + canal notification email + seuils 50/80/95/100 %

**Prérequis** : [docs/00-prerequis.md](../docs/00-prerequis.md) validé, [docs/01-setup-gcp.md](../docs/01-setup-gcp.md) exécuté jusqu'au §7 (compte GCP + APIs + SA + bucket state).

## Exécution

```bash
cd ~/Desktop/bendimu-experiments/bootstrap
cp terraform.tfvars.example terraform.tfvars
# éditer : project_id, project_number, billing_account_id

source ../.env
terraform init \
  -backend-config="bucket=${TF_BACKEND_BUCKET}" \
  -backend-config="prefix=bootstrap"

terraform plan -out=bootstrap.plan
terraform apply bootstrap.plan
```

**Durée** : ~3 min. **Coût** : ~0.10 USD/h (juste le NAT idle).

## Destruction

Bootstrap n'est pas détruit à chaque campagne — uniquement en fin de projet. Voir [docs/06-cleanup.md](../docs/06-cleanup.md) §7 pour la procédure de décommissionnement complet.

**Attention** : `terraform destroy` sur ce module supprime le VPC → tous les clusters V0/V1/V2 doivent être détruits d'abord.
