################################################################################
# Variables
################################################################################

# AWS Region
variable "region" {
  description = "The AWS region to deploy resources in"
  type        = string
  default     = "us-west-2"
}

# EKS Node Instance Types
variable "eks_instance_types" {
  description = "The instance types for the EKS node group"
  type        = list(string)
  default     = ["m6in.xlarge"]
}

variable "rds_instance_class" {
  default = "db.m6i.large"
}

variable "rds_allocated_storage" {
  default = 20
}

variable "rds_backup_retention" {
  default = 7
}

variable "db_username" {
  default = "postgres_user"
}

variable "db_password" {
  default = "UberSecretPassword" // Consider using a more secure method for managing passwords.
}

variable "rds_master_username" {
  description = "Master username for the RDS instance"
  type        = string
  default     = "postgres_user" // Update with your desired username or set to null if you want to input it at runtime
}

variable "rds_master_password" {
  description = "Master password for the RDS instance"
  type        = string
  default     = "UberSecretPassword" // Update with a secure password or use a more secure method to manage secrets
}

variable "environment" {
  description = "The environment for the deployment (e.g., dev, staging, prod)"
  type        = string
  default     = "dev"  # You can set a default value or leave it without one
}


# variables.tf

variable "opensearch_domain_name" {
  description = "The name of the OpenSearch domain"
  type        = string
  default     = "opengovernance-os"
}

variable "opensearch_master_username" {
  description = "The master username for OpenSearch"
  type        = string
  default     = "admin"  # Change as needed
}

variable "opensearch_instance_type" {
  description = "The instance type for OpenSearch nodes"
  type        = string
  default     = "r6g.large.search"
}

variable "opensearch_instance_count" {
  description = "Number of OpenSearch instances"
  type        = number
  default     = 3
}

variable "opensearch_ebs_volume_size" {
  description = "The size of EBS volume for OpenSearch in GB"
  type        = number
  default     = 150
}

variable "opensearch_engine_version" {
  description = "The OpenSearch engine version"
  type        = string
  default     = "OpenSearch_2.7"
}

variable "opensearch_environment" {
  description = "The environment tag for OpenSearch"
  type        = string
  default     = "dev"  # Change to "test" as needed
}

variable "install_opensearch" {
  description = "Whether to install OpenSearch."
  type        = bool
  default     = false
}
