terraform {
  required_version = ">= 1.7.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.30, < 6.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 5.30, < 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.30, < 3.0"
    }
  }
  backend "gcs" {}
}

provider "google" {
  project               = var.project_id
  region                = var.region
  zone                  = var.primary_zone
  billing_project       = var.project_id
  user_project_override = true
}

provider "google-beta" {
  project               = var.project_id
  region                = var.region
  zone                  = var.primary_zone
  billing_project       = var.project_id
  user_project_override = true
}

data "google_client_config" "default" {}

provider "kubernetes" {
  host                   = "https://${module.gke_primary.endpoint}"
  cluster_ca_certificate = base64decode(module.gke_primary.ca_certificate)
  token                  = data.google_client_config.default.access_token
}
