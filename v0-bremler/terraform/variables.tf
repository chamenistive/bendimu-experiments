variable "project_id" { type = string }
variable "region" {
  type    = string
  default = "europe-west9"
}
variable "zone" {
  type    = string
  default = "europe-west9-a"
}
variable "cluster_name" {
  type    = string
  default = "bremler-v0"
}
variable "k8s_version" {
  type    = string
  default = "1.29.9-gke.1000000"
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
  type        = string
  description = "SA node pools (créé par bootstrap : bendimu-gke-nodes@...)"
}
variable "notification_channels" {
  type    = list(string)
  default = []
}
