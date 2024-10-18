variable "project_id" {
  description = "Google Cloud project ID"
  type        = string
}

variable "cluster_name" {
  description = "Name of the GKE cluster"
  type        = string
}

variable "cluster_location" {
  description = "Location of the GKE cluster (region)"
  type        = string
}

variable "network_name" {
  description = "Name of the VPC network"
  type        = string
}

variable "subnetwork_name" {
  description = "Name of the subnet"
  type        = string
}

variable "remove_default_node_pool" {
  description = "Whether to remove the default node pool"
  type        = bool
}

variable "initial_node_count" {
  description = "Initial number of nodes in the default node pool"
  type        = number
}

variable "kubernetes_version" {
  description = "The Kubernetes version of the masters. If set to 'latest', it will pull the latest available version in the selected region."
  type        = string
}

variable "node_pool_name" {
  description = "Name of the node pool"
  type        = string
}

variable "node_count" {
  description = "Number of nodes in the node pool"
  type        = number
}

variable "machine_type" {
  description = "Machine type for the nodes"
  type        = string
}

variable "oauth_scopes" {
  description = "OAuth scopes for the node pool"
  type        = list(string)
}

variable "tags" {
  description = "Base network tags for the node pool"
  type        = list(string)
  default     = ["gke-node"]
}

variable "disable_legacy_endpoints" {
  description = "Disable legacy endpoints on nodes"
  type        = bool
}
