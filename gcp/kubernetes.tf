# ---------------------------------------------------
# Kubernetes Provider Configuration
# ---------------------------------------------------

provider "kubernetes" {
  host                   = module.gke.cluster_endpoint
  client_certificate     = base64decode(module.gke.client_certificate)
  client_key             = base64decode(module.gke.client_key)
  cluster_ca_certificate = base64decode(module.gke.cluster_ca_certificate)
  username               = var.gke_username
  password               = var.gke_password
}
