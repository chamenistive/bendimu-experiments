output "cluster_name" { value = google_container_cluster.this.name }
output "endpoint" { value = google_container_cluster.this.endpoint }
output "master_version" { value = google_container_cluster.this.master_version }
output "ca_certificate" {
  value     = google_container_cluster.this.master_auth[0].cluster_ca_certificate
  sensitive = true
}
output "location" { value = google_container_cluster.this.location }
output "get_credentials_command" {
  value = "gcloud container clusters get-credentials ${google_container_cluster.this.name} --zone=${var.zone} --project=${var.project_id}"
}
