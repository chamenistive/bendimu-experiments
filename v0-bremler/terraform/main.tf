# V0 — cluster GKE dédié reproduction Bremler-Barr 2024

data "google_project" "current" { project_id = var.project_id }

module "gke" {
  source = "../../shared/modules/gke-cluster"

  project_id    = var.project_id
  cluster_name  = var.cluster_name
  zone          = var.zone
  k8s_version   = var.k8s_version
  network       = var.network_name
  subnetwork    = var.subnetwork_name
  node_sa_email = var.node_sa_email
  campaign_id   = "v0-bremler"
  labels        = { version = "v0" }

  deletion_protection         = false
  disable_kube_network_policy = true

  node_pools = [
    {
      name         = "sut"
      node_count   = 5
      machine_type = "n2-standard-4"
      disk_size_gb = var.sut_disk_size_gb
      disk_type    = "pd-ssd"
      preemptible  = false
      labels       = { "bendimu.pool" = "sut" }
      taints       = []
    },
    {
      name         = "load"
      node_count   = 2
      machine_type = "n2-standard-4"
      disk_size_gb = var.load_disk_size_gb
      disk_type    = "pd-ssd"
      preemptible  = false
      labels       = { "bendimu.pool" = "load" }
      taints = [{
        key    = "bendimu.role"
        value  = "load"
        effect = "NO_SCHEDULE"
      }]
    },
  ]
}

module "monitoring" {
  source = "../../shared/modules/monitoring"

  project_id               = var.project_id
  enable_cilium_monitoring = true
  enable_istio_monitoring  = true
  mesh_namespace           = "bendimu-sut"
  notification_channels    = var.notification_channels

  depends_on = [module.gke]
}
