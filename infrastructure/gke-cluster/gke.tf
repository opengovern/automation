# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0

variable "gke_username" {
  default     = ""
  description = "gke username"
}

variable "gke_password" {
  default     = ""
  description = "gke password"
}

variable "gke_num_nodes" {
  default     = 3
  description = "number of gke nodes"
}

variable "gke_node_type" {
  description = "Machine Instance Type (i.e. c4-standard-4)"
  default = "c3-standard-4"
}

variable "cluster_version_prefix" {
  description = "Google Kubernetes cluster version"
  default = "1.30."
}

variable "gke_cluster_region" {
  description = "Google Kubernetes cluster version"
  default = "us-central1-a"
}

variable "kubernetes_version" {
  description = "The Kubernetes version of the masters. If set to 'latest' it will pull latest available version in the selected region."
  type        = string
  default     = "latest"
}

# GKE cluster
data "google_container_engine_versions" "gke_version" {
  location = var.gke_cluster_region
  version_prefix = "1.30."
}

resource "google_container_cluster" "primary" {
  name     = "${var.project_id}-gke"
  location = var.gke_cluster_region

  # We can't create a cluster with no node pool defined, but we want to only use
  # separately managed node pools. So we create the smallest possible default
  # node pool and immediately delete it.
  remove_default_node_pool = true
  initial_node_count       = 1
  network    = google_compute_network.vpc.name
  subnetwork = google_compute_subnetwork.subnet.name
  min_master_version = "1.30"
}

# Separately Managed Node Pool
resource "google_container_node_pool" "primary_nodes" {
  name       = google_container_cluster.primary.name
  location   = var.gke_cluster_region
  cluster    = google_container_cluster.primary.name
  
  #version = data.google_container_cluster.primary.latest_node_version
  node_count = var.gke_num_nodes

  node_config {
    oauth_scopes = [
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
    ]

    labels = {
      env = var.project_id
    }

    # preemptible  = true
    machine_type = var.gke_node_type
    tags         = ["gke-node", "${var.project_id}-gke"]
    metadata = {
      disable-legacy-endpoints = "true"
    }
  }
}


# # Kubernetes provider
# # The Terraform Kubernetes Provider configuration below is used as a learning reference only. 
# # It references the variables and resources provisioned in this file. 
# # We recommend you put this in another file -- so you can have a more modular configuration.
# # https://learn.hashicorp.com/terraform/kubernetes/provision-gke-cluster#optional-configure-terraform-kubernetes-provider
# # To learn how to schedule deployments and services using the provider, go here: https://learn.hashicorp.com/tutorials/terraform/kubernetes-provider.

# provider "kubernetes" {
#   load_config_file = "false"

#   host     = google_container_cluster.primary.endpoint
#   username = var.gke_username
#   password = var.gke_password

#   client_certificate     = google_container_cluster.primary.master_auth.0.client_certificate
#   client_key             = google_container_cluster.primary.master_auth.0.client_key
#   cluster_ca_certificate = google_container_cluster.primary.master_auth.0.cluster_ca_certificate
# }

# ---------------------------------------------------------------------------------------------------------------------
# Prepare locals to keep the code cleaner
# ---------------------------------------------------------------------------------------------------------------------

locals {
  latest_version     = data.google_container_engine_versions.location.latest_master_version
  kubernetes_version = var.kubernetes_version != "latest" ? var.kubernetes_version : local.latest_version
}

# ---------------------------------------------------------------------------------------------------------------------
# Pull in data
# ---------------------------------------------------------------------------------------------------------------------

// Get available master versions in our location to determine the latest version
data "google_container_engine_versions" "location" {
  location = var.gke_cluster_region
  project  = var.project_id
}