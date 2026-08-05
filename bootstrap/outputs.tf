output "vpc_id" { value = google_compute_network.vpc.id }
output "vpc_name" { value = google_compute_network.vpc.name }
output "subnet_id" { value = google_compute_subnetwork.subnet.id }
output "subnet_name" { value = google_compute_subnetwork.subnet.name }
output "artifact_registry_url" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.bendimu_images.repository_id}"
}
output "gke_nodes_sa_email" { value = google_service_account.gke_nodes.email }
output "nat_gateway_name" { value = google_compute_router_nat.nat.name }
output "budget_id" { value = module.budget.budget_id }
