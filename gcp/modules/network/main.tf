resource "google_compute_network" "vpc" {
  name                    = "${var.project_id}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name          = "${var.project_id}-subnet"
  region        = var.subnet_region
  network       = google_compute_network.vpc.name
  ip_cidr_range = var.ip_cidr_range
}
