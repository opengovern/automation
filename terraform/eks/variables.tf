variable "region" {
  type        = string
  description = "AWS region in which to deploy resources."
  default     = "us-west-2"
}

variable "cluster_name" {
  type        = string
  description = "Name of the EKS cluster."
  default     = "opencomply"
}
