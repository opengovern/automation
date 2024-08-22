# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-2"
}


variable "instance_type" {
  description = "AWS Instance Type"
  type        = list
  default     = ["m6in.xlarge"]
}

variable "eks_nodes" {
  description = "AWS EKS Nodes"
  type        = number
  default     = "3"
}

variable "eks_max_nodes" {
  description = "AWS EKS Nodes"
  type        = number
  default     = "5"
}