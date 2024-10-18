resource "google_container_cluster" "primary" {
  name                     = var.cluster_name
  location                 = var.cluster_location
  network                  = var.network_name
  subnetwork               = var.subnetwork_name
  remove_default_node_pool = var.remove_default_node_pool
  initial_node_count       = var.initial_node_count
  min_master_version       = var.kubernetes_version
  deletion_protection      = false

  # Optional: Enable IP Aliasing if required
  # ip_allocation_policy {
  #   cluster_secondary_range_name  = "pods"
  #   services_secondary_range_name = "services"
  # }
}

resource "google_container_node_pool" "primary_nodes" {
  name       = var.node_pool_name
  location   = var.cluster_location
  cluster    = google_container_cluster.primary.name
  node_count = var.node_count

  node_config {
    oauth_scopes = var.oauth_scopes

    labels = {
      env = var.project_id
    }

    machine_type = var.machine_type
    tags         = concat(var.tags, ["${var.project_id}-gke"])  # Dynamic tag addition
    metadata = {
      disable-legacy-endpoints = tostring(var.disable_legacy_endpoints)
    }
  }

  # Optional: Enable Autoscaling
  # autoscaling {
  #   min_node_count = 1
  #   max_node_count = 5
  # }
}
