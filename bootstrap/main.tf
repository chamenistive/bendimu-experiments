# Bootstrap Bendimu — VPC, Artifact Registry, Cloud NAT, Firewalls, Budget, SA nodes
# Exécuter UNE fois avant les versions V0/V1/V2.

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
  }

  backend "gcs" {
    # bucket + prefix passés via -backend-config au terraform init
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# --- APIs (déjà activées via gcloud dans docs/01, ici on documente en state) ---
locals {
  required_apis = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com",
    "cloudbilling.googleapis.com",
  ]
}

resource "google_project_service" "apis" {
  for_each                   = toset(local.required_apis)
  project                    = var.project_id
  service                    = each.value
  disable_dependent_services = false
  disable_on_destroy         = false
}

# --- Réseau VPC dédié Bendimu ---
resource "google_compute_network" "vpc" {
  name                    = "bendimu-vpc"
  project                 = var.project_id
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
  depends_on              = [google_project_service.apis]
}

resource "google_compute_subnetwork" "subnet" {
  name                     = "bendimu-subnet-${var.region}"
  project                  = var.project_id
  region                   = var.region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = "10.20.0.0/20"
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.24.0.0/14"
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.28.0.0/20"
  }
}

# --- Cloud Router + NAT (egress internet des pods) ---
resource "google_compute_router" "router" {
  name    = "bendimu-router"
  project = var.project_id
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "bendimu-nat"
  project                            = var.project_id
  region                             = var.region
  router                             = google_compute_router.router.name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
  min_ports_per_vm                   = 512
  max_ports_per_vm                   = 4096
  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# --- Firewalls : IAP + Google health checks ---
resource "google_compute_firewall" "allow_iap_ssh" {
  name    = "bendimu-allow-iap-ssh"
  project = var.project_id
  network = google_compute_network.vpc.name
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["35.235.240.0/20"] # IAP range
  target_tags   = ["bendimu"]
}

resource "google_compute_firewall" "allow_google_health_checks" {
  name    = "bendimu-allow-hc"
  project = var.project_id
  network = google_compute_network.vpc.name
  allow {
    protocol = "tcp"
    ports    = ["80", "443", "8080", "15021"]
  }
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags   = ["bendimu"]
}

# --- Artifact Registry (images sut-v1, mirrors Cilium/Istio) ---
resource "google_artifact_registry_repository" "bendimu_images" {
  provider      = google-beta
  project       = var.project_id
  location      = var.region
  repository_id = "bendimu-images"
  format        = "DOCKER"
  description   = "Registry Bendimu (SUT V1, mirrors Cilium/Istio)"
  depends_on    = [google_project_service.apis]
}

# --- Service Account pour node pools GKE (workload identity + moindre privilège) ---
resource "google_service_account" "gke_nodes" {
  project      = var.project_id
  account_id   = "bendimu-gke-nodes"
  display_name = "Bendimu GKE node SA (moindre privilège)"
}

resource "google_project_iam_member" "gke_nodes_roles" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/artifactregistry.reader",
    "roles/storage.objectViewer",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

# --- Budget + alertes via module partagé ---
module "budget" {
  source = "../shared/modules/budget-alerts"

  project_id         = var.project_id
  project_number     = var.project_number
  billing_account_id = var.billing_account_id
  alert_email        = var.alert_email
  budget_amount_usd  = var.budget_amount_usd
  thresholds_percent = var.budget_thresholds
  display_name       = "Bendimu ${var.budget_amount_usd} USD/mois"
}
