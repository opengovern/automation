# ---------------------------------------------------
# Root Outputs
# ---------------------------------------------------

output "network_name" {
  description = "Name of the VPC network"
  value       = module.network.network_name
}

output "subnetwork_name" {
  description = "Name of the subnet"
  value       = module.network.subnetwork_name
}

output "gke_cluster_name" {
  description = "Name of the GKE cluster"
  value       = module.gke.cluster_name
}

output "gke_cluster_endpoint" {
  description = "Endpoint of the GKE cluster"
  value       = module.gke.cluster_endpoint
}

output "gke_client_certificate" {
  description = "Client certificate for the GKE cluster"
  value       = module.gke.client_certificate
  sensitive   = true
}

output "gke_client_key" {
  description = "Client key for the GKE cluster"
  value       = module.gke.client_key
  sensitive   = true
}

output "gke_cluster_ca_certificate" {
  description = "Cluster CA certificate for the GKE cluster"
  value       = module.gke.cluster_ca_certificate
  sensitive   = true
}
