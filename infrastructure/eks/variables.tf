################################################################################
# Variables
################################################################################

# AWS Region
variable "region" {
  description = "The AWS region to deploy resources."
  type        = string
  default     = "us-west-2"
}

# Environment
variable "environment" {
  description = "The environment for the deployment (e.g., dev, staging, prod)."
  type        = string
  default     = "dev"  # Set a default value or leave it without one
}

# RDS Instance Configuration
variable "rds_master_username" {
  description = "Master username for the RDS instance."
  type        = string
  default     = "postgres_user"  # Update with your desired username or set to null for runtime input
}

variable "rds_master_password" {
  description = "Master password for the RDS instance."
  type        = string
  default     = "UberSecretPassword"  # Consider using a secure method for managing passwords
}

variable "rds_instance_class" {
  description = "The instance class for the RDS instance."
  type        = string
  default     = "db.m6i.large"
}

variable "rds_allocated_storage" {
  description = "The allocated storage for the RDS instance in GB."
  type        = number
  default     = 20
}

variable "rds_backup_retention" {
  description = "The number of days to retain backups for the RDS instance."
  type        = number
  default     = 7
}

# EKS Node Configuration
variable "eks_instance_types" {
  description = "The instance types for the EKS node group."
  type        = list(string)
  default     = ["m6in.xlarge"]
}

# Scaled Workers Instance Type
variable "scaled_workers_instance_type" {
  description = "The instance type for the scaled workers node group. Defaulting to the first instance type in eks_instance_types."
  type        = list(string)
  default     = ["t3.large"]
}


# KMS Key Configuration
variable "existing_kms_key_id" {
  description = "The existing KMS key ID for EBS volumes. If not provided, a new key will be created."
  type        = string
  default     = ""
}
