variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "europe-west1"
}

variable "zone" {
  type    = string
  default = "europe-west1-b"
}

variable "cluster_name" {
  type    = string
  default = "bendimu-v1"
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
  default = "bendimu-subnet-europe-west1"
}

variable "node_sa_email" {
  type = string
}

variable "notification_channels" {
  type    = list(string)
  default = []
}

variable "sut_disk_size_gb" {
  type        = number
  default     = 70
  description = "Taille PD-SSD par node pool SUT (5 nodes). 70 par défaut pour tenir quota 500 GB."
}

variable "load_disk_size_gb" {
  type        = number
  default     = 50
  description = "Taille PD-SSD par node pool load (2 nodes). Fortio écrit peu, 50 GB suffit."
}
