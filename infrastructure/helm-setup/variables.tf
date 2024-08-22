# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0

variable "region" {
  default = "us-east-2"
}

variable "helm_release_name" {
  description = "Release name (Name used when creating the helm chart)"
  type        = string
  default     = "cert-manager"
}

variable "helm_repository_url" {
  description = "Repository URL to locate the requested chart"
  type        = string
  default     = "https://charts.jetstack.io"
}

variable "helm_chart_name" {
  description = "Chart name to be installed (Name of the chart to source/install)"
  type        = string
  default     = "cert-manager"
}

variable "namespace" {
  description = "Namespace to install the release into"
  type        = string
  default     = "cert-manager"
}

variable "replica_count" {
  description = "Number of replica pods to create"
  type        = number
  default     = 1
}