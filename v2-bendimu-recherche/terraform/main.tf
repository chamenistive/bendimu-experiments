# V2 — cluster principal + clusters cross-region optionnels (amendement A8)

module "gke_primary" {
  source = "../../shared/modules/gke-cluster"

  project_id    = var.project_id
  cluster_name  = var.cluster_name
  zone          = var.primary_zone
  k8s_version   = var.k8s_version
  network       = var.network_name
  subnetwork    = var.subnetwork_name
  node_sa_email = var.node_sa_email
  campaign_id   = "v2-bendimu-recherche"
  labels        = { version = "v2" }

  deletion_protection         = false
  disable_kube_network_policy = true

  node_pools = [
    {
      name         = "sut"
      node_count   = 5
      machine_type = "n2-standard-4"
      disk_size_gb = 100
      disk_type    = "pd-ssd"
      preemptible  = false
      labels       = { "bendimu.pool" = "sut" }
      taints       = []
    },
    {
      name         = "load"
      node_count   = 2
      machine_type = "n2-standard-4"
      disk_size_gb = 50
      disk_type    = "pd-ssd"
      preemptible  = false
      labels       = { "bendimu.pool" = "load" }
      taints       = [{ key = "bendimu.role", value = "load", effect = "NO_SCHEDULE" }]
    },
    {
      name         = "obs"
      node_count   = 1
      machine_type = "n2-standard-2"
      disk_size_gb = 50
      disk_type    = "pd-standard"
      preemptible  = true
      labels       = { "bendimu.pool" = "obs" }
      taints       = []
    },
    {
      name         = "external-sut"
      node_count   = var.enable_external_sut ? 2 : 0
      machine_type = "n2-standard-4"
      disk_size_gb = 50
      disk_type    = "pd-standard"
      preemptible  = false
      labels       = { "bendimu.pool" = "external-sut" }
      taints       = []
    },
  ]
}

# Amendement A8 — clusters cross-régionaux (activés à la demande, coût élevé)
module "gke_us" {
  count  = var.enable_a8_multi_region ? 1 : 0
  source = "../../shared/modules/gke-cluster"

  project_id    = var.project_id
  cluster_name  = "${var.cluster_name}-us"
  zone          = "us-central1-a"
  k8s_version   = var.k8s_version
  network       = var.network_name
  subnetwork    = "bendimu-subnet-us-central1"
  node_sa_email = var.node_sa_email
  campaign_id   = "v2-A8-us"
  labels        = { version = "v2", amendment = "A8" }

  deletion_protection         = false
  disable_kube_network_policy = true

  node_pools = [
    {
      name         = "sut", node_count = 3, machine_type = "n2-standard-4"
      disk_size_gb = 50, disk_type = "pd-ssd", preemptible = false
      labels       = { "bendimu.pool" = "sut" }, taints = []
    },
  ]
}

module "gke_asia" {
  count  = var.enable_a8_multi_region ? 1 : 0
  source = "../../shared/modules/gke-cluster"

  project_id    = var.project_id
  cluster_name  = "${var.cluster_name}-asia"
  zone          = "asia-east1-a"
  k8s_version   = var.k8s_version
  network       = var.network_name
  subnetwork    = "bendimu-subnet-asia-east1"
  node_sa_email = var.node_sa_email
  campaign_id   = "v2-A8-asia"
  labels        = { version = "v2", amendment = "A8" }

  deletion_protection         = false
  disable_kube_network_policy = true

  node_pools = [
    {
      name         = "sut", node_count = 3, machine_type = "n2-standard-4"
      disk_size_gb = 50, disk_type = "pd-ssd", preemptible = false
      labels       = { "bendimu.pool" = "sut" }, taints = []
    },
  ]
}

module "monitoring" {
  source = "../../shared/modules/monitoring"

  project_id               = var.project_id
  enable_cilium_monitoring = true
  enable_istio_monitoring  = true
  mesh_namespace           = "bendimu-sut-v1"
  notification_channels    = var.notification_channels

  depends_on = [module.gke_primary]
}
