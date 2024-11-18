variable "project_id" {
  description = "Google Cloud project ID"
  type        = string
}

variable "subnet_region" {
  description = "Region for the subnet"
  type        = string
}

variable "ip_cidr_range" {
  description = "CIDR range for the subnet"
  type        = string
}
