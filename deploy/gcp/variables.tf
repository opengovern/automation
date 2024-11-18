# ---------------------------------------------------
# Root Variables
# ---------------------------------------------------

variable "gke_username" {
  default     = ""
  description = "GKE username"
}

variable "gke_password" {
  default     = ""
  description = "GKE password"
  sensitive   = true
}

variable "gke_num_of_nodes" {
  default     = 3
  description = "Number of GKE nodes"
}

variable "gke_node_type" {
  description = "Machine Instance Type (e.g., c3-standard-4)"
  default     = "c3-standard-4"
}

variable "cluster_version_prefix" {
  description = "Google Kubernetes cluster version prefix"
  default     = "1.30."
}

variable "gke_cluster_region" {
  description = "Google Kubernetes cluster region (e.g., us-central1)"
  default     = "us-central1"
}

variable "kubernetes_version" {
  description = "The Kubernetes version of the masters. If set to 'latest', it will pull the latest available version in the selected region."
  type        = string
  default     = "latest"
}

variable "ip_cidr_range" {
  description = "CIDR range for the subnet"
  default     = "10.10.0.0/24"
}

variable "cluster_name" {
  description = "Name of the GKE cluster"
  default     = "primary-gke"
}

variable "remove_default_node_pool" {
  description = "Whether to remove the default node pool"
  type        = bool
  default     = true
}

variable "initial_node_count" {
  description = "Initial number of nodes in the default node pool"
  type        = number
  default     = 1
}

variable "node_pool_name" {
  description = "Name of the node pool"
  default     = "primary-node-pool"
}

variable "oauth_scopes" {
  description = "OAuth scopes for the node pool"
  type        = list(string)
  default     = [
    "https://www.googleapis.com/auth/logging.write",
    "https://www.googleapis.com/auth/monitoring",
  ]
}

variable "tags" {
  description = "Base network tags for the node pool"
  type        = list(string)
  default     = ["gke-node"]
}

variable "disable_legacy_endpoints" {
  description = "Disable legacy endpoints on nodes"
  type        = bool
  default     = true
}
