# Module monitoring — PodMonitoring GMP + policies alertes standard Bendimu

resource "kubernetes_manifest" "pm_cilium_agent" {
  count = var.enable_cilium_monitoring ? 1 : 0

  manifest = {
    apiVersion = "monitoring.googleapis.com/v1"
    kind       = "PodMonitoring"
    metadata = {
      name      = "cilium-agent"
      namespace = "kube-system"
    }
    spec = {
      selector = { matchLabels = { "k8s-app" = "cilium" } }
      endpoints = [
        {
          port     = "prometheus"
          interval = "15s"
          path     = "/metrics"
        }
      ]
    }
  }
}

resource "kubernetes_manifest" "pm_envoy" {
  count = var.enable_istio_monitoring ? 1 : 0

  manifest = {
    apiVersion = "monitoring.googleapis.com/v1"
    kind       = "PodMonitoring"
    metadata = {
      name      = "envoy-sidecar"
      namespace = var.mesh_namespace
    }
    spec = {
      selector = { matchLabels = { "security.istio.io/tlsMode" = "istio" } }
      endpoints = [
        {
          port     = "http-envoy-prom"
          interval = "15s"
          path     = "/stats/prometheus"
        }
      ]
    }
  }
}

resource "google_monitoring_alert_policy" "node_disk_high" {
  count        = var.enable_alerts ? 1 : 0
  project      = var.project_id
  display_name = "Bendimu node disk > 80%"
  combiner     = "OR"

  conditions {
    display_name = "Disk utilisation > 80% on any GKE node"
    condition_threshold {
      filter          = "metric.type=\"kubernetes.io/node/ephemeral_storage/used_bytes\" resource.type=\"k8s_node\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.80
      duration        = "300s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = var.notification_channels
}
