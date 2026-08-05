variable "project_id" { type = string }
variable "cluster_name" { type = string }
variable "zone" { type = string }
variable "k8s_version" { type = string }
variable "network" { type = string }
variable "subnetwork" { type = string }
variable "node_sa_email" { type = string }
variable "campaign_id" {
  type    = string
  default = "unspecified"
}
variable "labels" {
  type    = map(string)
  default = {}
}
variable "deletion_protection" {
  type    = bool
  default = true
}
variable "disable_kube_network_policy" {
  description = "Désactive network policy K8s natif pour laisser Cilium OSS gérer"
  type        = bool
  default     = true
}

variable "node_pools" {
  description = "Liste des node pools à créer"
  type = list(object({
    name         = string
    node_count   = number
    machine_type = string
    disk_size_gb = number
    disk_type    = string
    preemptible  = bool
    labels       = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = string
      effect = string
    })), [])
  }))
}
