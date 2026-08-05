output "primary_cluster_name" { value = module.gke_primary.cluster_name }
output "primary_endpoint" { value = module.gke_primary.endpoint }
output "primary_get_credentials" { value = module.gke_primary.get_credentials_command }

output "us_cluster_name" {
  value = try(module.gke_us[0].cluster_name, null)
}
output "asia_cluster_name" {
  value = try(module.gke_asia[0].cluster_name, null)
}
