###############################################################################
# Providers
###############################################################################
provider "aws" {
  region = local.region
}

provider "kubernetes" {
  # Pin provider if desired, for example:
  # version = "~> 2.20"

  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # Requires awscli installed locally
    args = [
      "eks",
      "get-token",
      "--cluster-name", module.eks.cluster_name,
      "--region",       local.region
    ]
  }
}

provider "helm" {
  # Pin provider if desired, for example:
  # version = "~> 2.10"

  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      # Requires awscli installed locally
      args = [
        "eks",
        "get-token",
        "--cluster-name", module.eks.cluster_name,
        "--region",       local.region
      ]
    }
  }
}

###############################################################################
# Data Sources
###############################################################################
data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  # Exclude local zones
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

###############################################################################
# Locals
###############################################################################
locals {
  # Use variables for your cluster name and AWS region
  name   = var.cluster_name
  region = var.region

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  # Example tags
  tags = {
    "Project"   = var.cluster_name
    "ManagedBy" = "Terraform"
  }
}

###############################################################################
# VPC and Subnets
###############################################################################
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for i in range(length(local.azs)) : cidrsubnet(local.vpc_cidr, 4, i)]
  public_subnets  = [for i in range(length(local.azs)) : cidrsubnet(local.vpc_cidr, 8, i + 48)]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = local.tags
}

###############################################################################
# EKS Cluster
###############################################################################
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.11"

  cluster_name                   = local.name
  cluster_version                = "1.31"
  cluster_endpoint_public_access = true

  # Allows this Terraform user to deploy into the cluster
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Attach SSM policy, etc. to node roles if desired
  eks_managed_node_group_defaults = {
    iam_role_additional_policies = {
      AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    }
  }

  # Single managed node group example
  eks_managed_node_groups = {
    opencomply_app = {
      instance_types = ["m6in.xlarge"]
      min_size       = 3
      desired_size   = 3
      max_size       = 5

      # Force gp3 for root volumes
      disk_type = "gp3"
      disk_size = 25

      labels = {
        "opencomply-node" = "app"
      }
    },
    opencomply_opensearch = {
      instance_types = ["c5.xlarge"]
      min_size       = 1
      desired_size   = 1
      max_size       = 1

      # Force gp3 for root volumes
      disk_type = "gp3"
      disk_size = 15

      labels = {
        "opencomply-node" = "opensearch"
      }
    }
    opencomply_keda = {
      instance_types = ["c5.xlarge"]
      min_size       = 1
      desired_size   = 1
      max_size       = 3

      # Force gp3 for root volumes
      disk_type = "gp3"
      disk_size = 15

      labels = {
        "opencomply-node" = "worker"
      }
    }
  }

  tags = local.tags
}

###############################################################################
# EKS Blueprints Addons (Velero Disabled)
###############################################################################
module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.16"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  create_delay_dependencies = [for group in module.eks.eks_managed_node_groups : group.node_group_arn]

  eks_addons = {
    aws-ebs-csi-driver = {
      service_account_role_arn = module.ebs_csi_driver_irsa.iam_role_arn
    }
    coredns    = {}
    vpc-cni    = {}
    kube-proxy = {}
  }

  enable_velero             = false
  enable_aws_efs_csi_driver = false

  tags = local.tags
}

###############################################################################
# Storage Classes (Example)
###############################################################################
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
    encrypted = true
    fsType    = "ext4"
    type      = "gp3"
  }

  depends_on = [
    module.eks_blueprints_addons
  ]
}

/*
# Example EFS StorageClass (commented out):

resource "kubernetes_storage_class_v1" "efs" {
  metadata {
    name = "efs"
  }

  storage_provisioner = "efs.csi.aws.com"
  parameters = {
    provisioningMode = "efs-ap"
    fileSystemId     = module.efs.id
    directoryPerms   = "700"
  }

  mount_options = ["iam"]

  depends_on = [module.eks_blueprints_addons]
}
*/

###############################################################################
# Optional EFS Module (commented out)
###############################################################################
/*
module "efs" {
  source  = "terraform-aws-modules/efs/aws"
  version = "~> 1.1"

  creation_token = local.name
  name           = local.name

  mount_targets = {
    for k, subnet in zipmap(local.azs, module.vpc.private_subnets) : k => {
      subnet_id = subnet
    }
  }

  security_group_description = "${local.name} EFS security group"
  security_group_vpc_id      = module.vpc.vpc_id

  security_group_rules = {
    vpc = {
      description = "NFS ingress from private subnets"
      cidr_blocks = module.vpc.private_subnets_cidr_blocks
    }
  }

  tags = local.tags
}
*/

###############################################################################
# KMS Key for EBS Encryption
###############################################################################
module "ebs_kms_key" {
  source  = "terraform-aws-modules/kms/aws"
  version = "~> 1.5"

  description = "KMS key for EKS managed node group volumes"

  key_administrators = [data.aws_caller_identity.current.arn]
  key_service_roles_for_autoscaling = [
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling",
    # Required for the cluster / PVC controller to create encrypted volumes
    module.eks.cluster_iam_role_arn,
  ]

  aliases = ["eks/${local.name}/ebs"]

  tags = local.tags
}

###############################################################################
# IRSA for the EBS CSI Driver
###############################################################################
module "ebs_csi_driver_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.20"

  role_name_prefix = "${module.eks.cluster_name}-ebs-csi-driver-"

  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = local.tags
}
