################################################################################
# Terraform Configuration
################################################################################

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 4.0.0"  # Ensure this is updated to the latest stable version
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.0.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0.0"
    }
  }

  required_version = ">= 1.0.0"
}

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

# RDS Engine Version Data Source
data "aws_rds_engine_version" "postgresql" {
  engine             = "postgres"
  preferred_versions = ["15.5", "15.4", "15.3", "15.2", "15.1"]
}

################################################################################
# Random Resources
################################################################################

resource "random_string" "suffix" {
  length  = 8
  special = false
  upper   = false
  numeric = true
  lower   = true
}

resource "random_password" "rds_password" {
  length  = 16
  special = true
  upper   = true
  numeric = true
  lower   = true
}

# OpenSearch Master Password
resource "random_password" "opensearch_master_password" {
  length  = 16
  special = true
  upper   = true
  numeric = true
  lower   = true
}

################################################################################
# Locals
################################################################################

locals {
  name   = "opengovernance"
  region = var.region

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    Name        = local.name
    Environment = var.environment
    Repository  = "https://github.com/terraform-aws-modules/terraform-aws-rds"
  }

  db_username = var.rds_master_username
  db_password = random_password.rds_password.result
}

################################################################################
# VPC
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = "${local.name}-vpc-${random_string.suffix.result}"
  cidr = local.vpc_cidr

  azs = local.azs

  private_subnets  = [for k, az in local.azs : cidrsubnet(local.vpc_cidr, 8, k)]
  public_subnets   = [for k, az in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 4)]
  database_subnets = [for k, az in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 8)]

  enable_nat_gateway = true
  single_nat_gateway = true

  create_database_subnet_group           = true
  manage_default_network_acl             = false
  manage_default_route_table             = false
  create_database_subnet_route_table     = true
  create_database_internet_gateway_route = false
  create_database_nat_gateway_route      = false

  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "Name"                    = "opengovernance-public-subnet"
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "Name"                            = "opengovernance-private-subnet"
  }

  database_subnet_tags = {
    "Name" = "opengovernance-database-subnet"
  }

  tags = local.tags
}

################################################################################
# EKS Cluster
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.11"

  cluster_name                   = "${local.name}-eks-${random_string.suffix.result}"
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
    instance-store = {
      instance_types = var.eks_instance_types
      min_size       = 1
      max_size       = 5
      desired_size   = 3

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 125
            volume_type           = "gp3"
            iops                  = 3000
            encrypted             = true
            kms_key_id            = module.ebs_kms_key.key_arn
            delete_on_termination = true
          }
        }
      }

      cloudinit_pre_nodeadm = [
        {
          content_type = "application/node.eks.aws"
          content      = <<-EOT
            ---
            apiVersion: node.eks.aws/v1alpha1
            kind: NodeConfig
            spec:
              instance:
                localStorage:
                  strategy: RAID0
          EOT
        }
      ]
    }
  }

  tags = local.tags
}

################################################################################
# EBS KMS Key
################################################################################

module "ebs_kms_key" {
  source  = "terraform-aws-modules/kms/aws"
  version = "~> 1.5"

  description = "Customer managed key to encrypt EKS managed node group volumes"

  key_administrators = [data.aws_caller_identity.current.arn]
  key_service_roles_for_autoscaling = [
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling",
    module.eks.cluster_iam_role_arn,
  ]

  aliases = ["eks/${local.name}/ebs"]

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
# EKS Blueprints Addons
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
  
  helm_releases = {
    open-governance = {  # Custom Helm Release for Open Governance
      description      = "A Helm chart for Open Governance"
      namespace        = "opengovernance"
      create_namespace = true
      chart            = "open-governance"
      chart_version    = "0.1.94"  # Specify the desired chart version
      repository       = "https://kaytu-io.github.io/kaytu-charts"
      values = [
        file("${path.module}/values.yaml")
      ]
      timeout          = 750  # Timeout set to 600 seconds (10 minutes)
    }
  }
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
    encrypted = false
    fsType    = "ext4"
    type      = "gp3"
  }

  depends_on = [
    module.eks_blueprints_addons
  ]
}

################################################################################
# RDS Resources
################################################################################

# Security group for RDS
module "rds_security_group" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = "${local.name}-rds-sg"
  description = "Allow database access from VPC"
  vpc_id      = module.vpc.vpc_id

  ingress_with_cidr_blocks = [
    {
      from_port   = 5432
      to_port     = 5432
      protocol    = "tcp"
      cidr_blocks = module.vpc.vpc_cidr_block  # Corrected: Pass as a string within a list
      description = "Allow PostgreSQL access from VPC"
    },
  ]

  egress_rules = ["all-all"]

  tags = local.tags
}

# RDS Instance
resource "aws_db_instance" "postgresql" {
  identifier             = "${local.name}-postgresql"
  allocated_storage      = var.rds_allocated_storage
  max_allocated_storage  = 100
  storage_type           = "gp3"
  engine                 = "postgres"
  engine_version         = data.aws_rds_engine_version.postgresql.version
  instance_class         = var.rds_instance_class
  db_name                = "mydatabase"
  username               = local.db_username
  password               = local.db_password
  port                   = 5432

  publicly_accessible     = false
  multi_az                = false
  storage_encrypted       = true
  skip_final_snapshot     = true
  deletion_protection     = false

  # Use the subnet group from the VPC module
  db_subnet_group_name    = module.vpc.database_subnet_group_name

  # Apply security group
  vpc_security_group_ids  = [module.rds_security_group.security_group_id]

  backup_retention_period = var.rds_backup_retention

  tags = {
    Name = "PostgreSQL Database"
  }

  depends_on = [
    module.vpc,
    module.rds_security_group
  ]
}

################################################################################
# OpenSearch Security Group
################################################################################

resource "aws_security_group" "opensearch_sg" {
  count       = var.install_opensearch ? 1 : 0
  name        = "${local.name}-opensearch-sg"
  description = "Security group for OpenSearch domain"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description      = "Allow HTTPS traffic from VPC"
    from_port        = 443
    to_port          = 443
    protocol         = "tcp"
    cidr_blocks      = [module.vpc.vpc_cidr_block]  # Ensure this is a list of strings
    ipv6_cidr_blocks = []
    prefix_list_ids  = []
    security_groups  = []
  }

  egress {
    description      = "Allow all outbound traffic"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
    prefix_list_ids  = []
    security_groups  = []
  }

  tags = merge(local.tags, {
    Name = "${local.name}-opensearch-sg"
  })
}


# IAM Policy for OpenSearch Access (Already defined above)
# Add to your existing IAM Policies section or create a new one

data "aws_iam_policy_document" "opensearch_access" {
  statement {
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["*"]  # Replace "*" with specific IAM roles or users for enhanced security
    }

    actions = [
      "es:ESHttpGet",
      "es:ESHttpPost",
      "es:ESHttpPut",
      "es:ESHttpDelete",
      "es:ESHttpHead"
    ]

    resources = [
      "arn:aws:es:${var.region}:${data.aws_caller_identity.current.account_id}:domain/${var.opensearch_domain_name}/*"
    ]

    # Optional: Add conditions to restrict access further
    # condition {
    #   test     = "IpAddress"
    #   variable = "aws:SourceIp"
    #   values   = ["203.0.113.0/24"]  # Replace with your IP range
    # }
  }
}


# OpenSearch Domain (Updated)
resource "aws_opensearch_domain" "opengovernance" {
  count         = var.install_opensearch ? 1 : 0
  domain_name = var.opensearch_domain_name

  engine_version = var.opensearch_engine_version

  cluster_config {
    instance_type          = var.opensearch_instance_type
    instance_count         = var.opensearch_instance_count
    zone_awareness_enabled = true

    zone_awareness_config {
      availability_zone_count = 3
    }
  }
  encrypt_at_rest {
    enabled = true
    #kms_key_id  =  data.aws_kms_key.rds.arn
  }

  ebs_options {
    ebs_enabled = true
    volume_size = var.opensearch_ebs_volume_size
    volume_type = "gp3"
  }

  vpc_options {
    subnet_ids         = module.vpc.private_subnets
    security_group_ids = [aws_security_group.opensearch_sg[0].id]
  }

  access_policies = data.aws_iam_policy_document.opensearch_access.json

  advanced_options = {
    "rest.action.multi.allow_explicit_index" = "true"
  }

  # Enable Advanced Security Options
  advanced_security_options {
    enabled                        = true
    internal_user_database_enabled = true  # Enable the internal user database

    master_user_options {
      master_user_name     = var.opensearch_master_username
      master_user_password = random_password.opensearch_master_password.result
    }
  }
  node_to_node_encryption {
    enabled = true
  }
  domain_endpoint_options {
    enforce_https = true
  }
  

  # Automated snapshots
  snapshot_options {
    automated_snapshot_start_hour = 0  # UTC midnight
  }

  tags = merge(local.tags, {
    Name        = var.opensearch_domain_name
    Environment = var.opensearch_environment
  })

  # Auto-tune options
  auto_tune_options {
    desired_state = "ENABLED"
  }

  lifecycle {
    prevent_destroy = false
  }

  depends_on = [
    aws_security_group.opensearch_sg,
    module.vpc
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

output "rds_endpoint" {
  description = "The endpoint of the RDS PostgreSQL instance"
  value       = aws_db_instance.postgresql.endpoint
}

output "opensearch_domain_endpoint" {
  description = "The endpoint of the OpenSearch domain"
  value       = try(aws_opensearch_domain.opengovernance[0].endpoint, null)
}

output "opensearch_domain_arn" {
  description = "The ARN of the OpenSearch domain"
  value       = try(aws_opensearch_domain.opengovernance[0].arn, null)
}

output "opensearch_master_username" {
  description = "The master username for OpenSearch"
  value       = try(aws_opensearch_domain.opengovernance[0].advanced_security_options[0].master_user_options[0].master_user_name, null)
}

output "opensearch_master_password" {
  description = "The master password for OpenSearch"
  value       = try(random_password.opensearch_master_password.result, null)
  sensitive   = true
}
