################################################################################
# Variables
################################################################################

variable "region" {
  description = "The AWS region where resources will be created."
  type        = string
  default     = "us-east-2"  # You can change the default region here
}

variable "high_availability" {
  description = "Enable high availability for production-like environments."
  type        = bool
  default     = false
}

variable "eks_instance_types" {
  description = "List of EC2 instance types for the EKS node groups."
  type        = list(string)
  default     = ["m6i.xlarge"]  # Modify as per your requirements
}

################################################################################
# Providers
################################################################################

provider "aws" {
  region = var.region
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

################################################################################
# Data Sources
################################################################################

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_region" "current" {}

################################################################################
# Random Resources
################################################################################

resource "random_string" "suffix" {
  length  = 3
  special = false
  upper   = false
  numeric = true
  lower   = true
}

################################################################################
# Locals
################################################################################

locals {
  name = "opencomply"

  # Derive settings based on high_availability flag
  azs = var.high_availability ? slice(data.aws_availability_zones.available.names, 0, 3) : slice(data.aws_availability_zones.available.names, 0, 2)

  tags = {
    Name             = local.name
    HighAvailability = var.high_availability
  }
}

################################################################################
# VPC
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = "${local.name}-vpc-${random_string.suffix.result}"
  cidr = "10.0.0.0/16"

  azs = local.azs

  private_subnets = [for k, az in local.azs : cidrsubnet("10.0.0.0/16", 8, k)]
  public_subnets  = [for k, az in local.azs : cidrsubnet("10.0.0.0/16", 8, k + 4)]

  enable_nat_gateway = var.high_availability
  single_nat_gateway = !var.high_availability  # Use single NAT gateway in non-HA

  manage_default_network_acl = false
  manage_default_route_table = false

  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "Name"                   = "opencomply-public-subnet"
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "Name"                            = "opencomply-private-subnet"
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = local.tags
}

################################################################################
# EKS Cluster
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.11"

  cluster_name                   = "opencomply-${random_string.suffix.result}"
  cluster_version                = "1.31"
  cluster_endpoint_public_access = true

  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_group_defaults = {
    iam_role_additional_policies = {
      AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    }
    public_ip = false
  }

  eks_managed_node_groups = {
    opencomply-main = {
      instance_types = var.eks_instance_types
      min_size       = var.high_availability ? 3 : 1
      max_size       = var.high_availability ? 9 : 5
      desired_size   = var.high_availability ? 5 : 3

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 125
            volume_type           = "gp3"
            iops                  = 3000
            encrypted             = false  # Set to false or remove
            delete_on_termination = true
            # kms_key_id removed
          }
        }
      }
    }
  }
  tags = local.tags
}

################################################################################
# EBS CSI Driver IRSA
################################################################################

module "ebs_csi_driver_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.20"

  role_name_prefix = "${substr(module.eks.cluster_name, 0, 20)}-ebs-csi-"

  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = local.tags
}

################################################################################
# EKS Blueprints Addons (Excluding opencomply)
################################################################################

module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.16"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  create_delay_dependencies = [
    for group in module.eks.eks_managed_node_groups : group.node_group_arn
  ]

  eks_addons = {
    aws-ebs-csi-driver = {
      service_account_role_arn = module.ebs_csi_driver_irsa.iam_role_arn
    }
    coredns    = {}
    vpc-cni    = {}
    kube-proxy = {}
  }

  enable_aws_load_balancer_controller = true
  aws_load_balancer_controller = {
    chart_version = "1.6.0"
  }

  # Removed opencomply from helm_releases to avoid cyclic dependency
  helm_releases = {}

  tags = local.tags
}

################################################################################
# Storage Classes
################################################################################

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"

    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  allow_volume_expansion = true
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"

  parameters = {
    encrypted = "false"  # Ensure encryption is set to false
    fsType    = "ext4"
    type      = "gp3"
  }

  depends_on = [
    module.eks
  ]
}

################################################################################
# Outputs
################################################################################

output "vpc_id" {
  description = "The ID of the VPC"
  value       = module.vpc.vpc_id
}

output "eks_cluster_name" {
  description = "The name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "configure_kubectl" {
  description = "Configure kubectl: make sure you're logged in with the correct AWS profile and run the following command to update your kubeconfig"
  value       = "aws eks --region ${var.region} update-kubeconfig --name ${module.eks.cluster_name}"
}
