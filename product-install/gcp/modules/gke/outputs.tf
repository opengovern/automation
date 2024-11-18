# ---------------------------------------------------
# GKE Module Outputs
# ---------------------------------------------------

output "cluster_name" {
  description = "Name of the GKE cluster"
  value       = google_container_cluster.primary.name
}

output "cluster_endpoint" {
  description = "Endpoint of the GKE cluster"
  value       = google_container_cluster.primary.endpoint
}

output "client_certificate" {
  description = "Client certificate for the GKE cluster"
  value       = google_container_cluster.primary.master_auth.0.client_certificate
  sensitive   = true
}

output "client_key" {
  description = "Client key for the GKE cluster"
  value       = google_container_cluster.primary.master_auth.0.client_key
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "Cluster CA certificate for the GKE cluster"
  value       = google_container_cluster.primary.master_auth.0.cluster_ca_certificate
  sensitive   = true
}
