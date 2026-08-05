variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "europe-west9"
}

variable "primary_zone" {
  type    = string
  default = "europe-west9-a"
}

variable "cluster_name" {
  type    = string
  default = "bendimu-v2"
}

variable "k8s_version" {
  type    = string
  default = "1.30.5-gke.1355000"
}

variable "network_name" {
  type    = string
  default = "bendimu-vpc"
}

variable "subnetwork_name" {
  type    = string
  default = "bendimu-subnet-europe-west9"
}

variable "node_sa_email" {
  type = string
}

variable "notification_channels" {
  type    = list(string)
  default = []
}

variable "enable_external_sut" {
  description = "Provisionne pool dédié Bank of Anthos / OBP"
  type        = bool
  default     = false
}

variable "enable_a8_multi_region" {
  description = "Cross-region multi-cluster (amendement 08 étendu). ATTENTION coût élevé"
  type        = bool
  default     = false
}
