################################################################################
# Variables
################################################################################

variable "region" {
  description = "The AWS region to deploy resources."
  type        = string
  default     = "us-west-2"
}



variable "eks_instance_types" {
  description = "The instance types for the EKS node group."
  type        = list(string)
  default     = ["m6in.xlarge"]
}



