# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0

variable "project_id" {
  description = "project id"
}

variable "subnet_region" {
  description = "region"
}

provider "google" {
  project = var.project_id
  region  = var.subnet_region
}

# VPC
resource "google_compute_network" "vpc" {
  name                    = "${var.project_id}-vpc"
  auto_create_subnetworks = "false"
}

# Subnet
resource "google_compute_subnetwork" "subnet" {
  name          = "${var.project_id}-subnet"
  region        = var.subnet_region
  network       = google_compute_network.vpc.name
  ip_cidr_range = "10.10.0.0/24"
}
