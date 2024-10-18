# ---------------------------------------------------
# Provider Configuration
# ---------------------------------------------------

provider "google" {
  region = var.gke_cluster_region
  # 'project' is omitted to allow the provider to infer it from gcloud or environment variables
}

# ---------------------------------------------------
# Data Sources
# ---------------------------------------------------

# Retrieve the current Google Cloud client configuration
data "google_client_config" "default" {}

# Retrieve available GKE versions with the specified prefix
data "google_container_engine_versions" "gke_version" {
  project        = data.google_client_config.default.project
  location       = var.gke_cluster_region
  version_prefix = var.cluster_version_prefix
}

# Retrieve the latest available master version in the specified region
data "google_container_engine_versions" "location" {
  project  = data.google_client_config.default.project
  location = var.gke_cluster_region
}

# ---------------------------------------------------
# Locals
# ---------------------------------------------------

locals {
  latest_version     = data.google_container_engine_versions.location.latest_master_version
  kubernetes_version = var.kubernetes_version != "latest" ? var.kubernetes_version : local.latest_version
}

# ---------------------------------------------------
# Modules
# ---------------------------------------------------

module "network" {
  source        = "./modules/network"
  project_id    = data.google_client_config.default.project
  subnet_region = var.gke_cluster_region
  ip_cidr_range = var.ip_cidr_range
}

module "gke" {
  source                     = "./modules/gke"
  project_id                 = data.google_client_config.default.project
  cluster_name               = var.cluster_name
  cluster_location           = var.gke_cluster_region
  network_name               = module.network.network_name
  subnetwork_name            = module.network.subnetwork_name
  remove_default_node_pool   = var.remove_default_node_pool
  initial_node_count         = var.initial_node_count
  kubernetes_version         = local.kubernetes_version
  node_pool_name             = var.node_pool_name
  node_count                 = var.gke_num_of_nodes
  machine_type               = var.gke_node_type
  oauth_scopes               = var.oauth_scopes
  tags                       = var.tags
  disable_legacy_endpoints   = var.disable_legacy_endpoints
}

# ---------------------------------------------------
# (Optional) Kubernetes Provider Configuration
# ---------------------------------------------------
# If you plan to manage Kubernetes resources with Terraform, uncomment and configure the provider below.
# It's recommended to place this configuration in a separate file (e.g., kubernetes.tf) for better modularity.

# provider "kubernetes" {
#   host                   = module.gke.cluster_endpoint
#   client_certificate     = base64decode(module.gke.client_certificate)
#   client_key             = base64decode(module.gke.client_key)
#   cluster_ca_certificate = base64decode(module.gke.cluster_ca_certificate)
#   username               = var.gke_username
#   password               = var.gke_password
# }
