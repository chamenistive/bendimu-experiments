# Module gke-cluster

Cluster GKE Standard + N node pools paramétrables. Utilisé par V0, V1, V2.

## Inputs principaux

| Variable | Type | Défaut | Rôle |
|---|---|---|---|
| `project_id` | string | — | Projet GCP |
| `cluster_name` | string | — | Nom cluster |
| `zone` | string | — | Zone GCP (mono-zone) |
| `k8s_version` | string | — | Version GKE (ex : `1.30.5-gke.1355000`) |
| `network` / `subnetwork` | string | — | Sortis du bootstrap |
| `node_sa_email` | string | — | SA `bendimu-gke-nodes@...` |
| `campaign_id` | string | `unspecified` | Tag ressources pour billing per-run |
| `deletion_protection` | bool | `true` | Empêche `terraform destroy` accidentel |
| `disable_kube_network_policy` | bool | `true` | Nécessaire pour Cilium OSS remplace kube-proxy |
| `node_pools` | list(object) | — | Liste de pools (name, node_count, machine_type, disk, preemptible, labels, taints) |

## Outputs

| Output | Rôle |
|---|---|
| `cluster_name`, `endpoint`, `location` | Identification |
| `ca_certificate` | Provider Kubernetes (sensitive) |
| `get_credentials_command` | Commande à exécuter pour configurer kubectl |

## Design

- `remove_default_node_pool = true` + `initial_node_count = 1` — GKE crée un pool éphémère puis on gère nos propres pools.
- `workload_metadata_config.mode = "GKE_METADATA"` obligatoire pour Workload Identity.
- `monitoring_config.managed_prometheus.enabled = true` → GMP scrape automatique.
- `logging_config` limité à `SYSTEM_COMPONENTS` (pas de workload logs) pour maîtriser coût Cloud Logging.
- `auto_upgrade = false` sur les pools : pas de surprise durant la campagne.
