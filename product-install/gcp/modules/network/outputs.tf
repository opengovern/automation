# ---------------------------------------------------
# Network Module Outputs
# ---------------------------------------------------

output "network_name" {
  description = "Name of the VPC network"
  value       = google_compute_network.vpc.name
}

output "subnetwork_name" {
  description = "Name of the subnet"
  value       = google_compute_subnetwork.subnet.name
}
