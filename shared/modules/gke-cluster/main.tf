# Module gke-cluster — cluster GKE Standard + node pools paramétrables Bendimu

resource "google_container_cluster" "this" {
  name     = var.cluster_name
  location = var.zone
  project  = var.project_id

  min_master_version = var.k8s_version
  network            = var.network
  subnetwork         = var.subnetwork

  remove_default_node_pool = true
  initial_node_count       = 1
  deletion_protection      = var.deletion_protection

  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_ipv4_cidr_block  = ""
    services_ipv4_cidr_block = ""
  }

  release_channel { channel = "UNSPECIFIED" }

  network_policy {
    enabled  = var.disable_kube_network_policy ? false : true
    provider = var.disable_kube_network_policy ? "PROVIDER_UNSPECIFIED" : "CALICO"
  }

  addons_config {
    http_load_balancing { disabled = false }
    horizontal_pod_autoscaling { disabled = true }
    network_policy_config { disabled = var.disable_kube_network_policy }
    gce_persistent_disk_csi_driver_config { enabled = true }
    gcp_filestore_csi_driver_config { enabled = false }
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS", "APISERVER", "CONTROLLER_MANAGER", "SCHEDULER"]
    managed_prometheus { enabled = true }
  }

  logging_config {
    enable_components = ["SYSTEM_COMPONENTS"]
  }

  cluster_autoscaling { enabled = false }

  maintenance_policy {
    daily_maintenance_window { start_time = "03:00" }
  }

  resource_labels = merge(var.labels, {
    campaign = var.campaign_id
    bendimu  = "true"
  })
}

resource "google_container_node_pool" "pools" {
  for_each = { for p in var.node_pools : p.name => p }

  name       = each.value.name
  cluster    = google_container_cluster.this.name
  location   = var.zone
  project    = var.project_id
  node_count = each.value.node_count

  node_config {
    machine_type = each.value.machine_type
    disk_size_gb = each.value.disk_size_gb
    disk_type    = each.value.disk_type
    image_type   = "COS_CONTAINERD"
    preemptible  = each.value.preemptible
    spot         = false

    service_account = var.node_sa_email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    workload_metadata_config { mode = "GKE_METADATA" }

    labels = merge(each.value.labels, {
      "bendimu.role" = each.value.name
    })

    dynamic "taint" {
      for_each = each.value.taints
      content {
        key    = taint.value.key
        value  = taint.value.value
        effect = taint.value.effect
      }
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    tags = ["bendimu", each.value.name]
  }

  management {
    auto_repair  = true
    auto_upgrade = false
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }
}
