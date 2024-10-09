################################################################################
# Variables
################################################################################

variable "region" {
  description = "The AWS region to deploy resources."
  type        = string
  default     = "us-west-2"
}

variable "environment" {
  description = "The environment for the deployment (e.g., dev, staging, production)."
  type        = string
  default     = "dev"
}

variable "rds_master_username" {
  description = "Master username for the RDS instance."
  type        = string
  default     = "postgres_user"
}

variable "rds_master_password" {
  description = "Master password for the RDS instance."
  type        = string
  sensitive   = true
  default     = "UberSecretPassword"  # Consider using a more secure method to manage secrets
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

variable "eks_instance_types" {
  description = "The instance types for the EKS node group."
  type        = list(string)
  default     = ["m6in.xlarge"]
}



