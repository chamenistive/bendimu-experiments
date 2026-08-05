# Shared — modules Terraform réutilisables

Modules HCL utilisés par `bootstrap/`, `v0-bremler/`, `v1-bendimu/`, `v2-bendimu-recherche/`.

## Modules disponibles

| Module | Rôle | Utilisé par |
|---|---|---|
| [`modules/gke-cluster`](modules/gke-cluster/) | Cluster GKE Standard + node pools paramétrables (SUT, load, obs, external-sut) | V0, V1, V2 |
| [`modules/budget-alerts`](modules/budget-alerts/) | Notification channel email + `google_billing_budget` avec seuils | Bootstrap |
| [`modules/monitoring`](modules/monitoring/) | `PodMonitoring` GMP pour Cilium et Envoy + alerte disque node > 80 % | V0, V1, V2 |

## Conventions

- Chaque module a `main.tf`, `variables.tf`, `outputs.tf`.
- Variables typées explicitement (pas d'`any`).
- Outputs sensibles marqués `sensitive = true`.
- Versions providers pinned dans le module racine (`bootstrap/main.tf`).

## Ajouter un module

1. Créer `modules/<nom>/` avec les 3 fichiers HCL
2. Documenter dans ce README + créer `modules/<nom>/README.md`
3. Faire tourner `tflint` et `terraform fmt -recursive`
