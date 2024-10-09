region                = "us-west-2"
environment           = "dev"

rds_master_username   = "prod_user"
rds_master_password   = "SecurePassword123!"  # Use a secure method to manage this, e.g., Terraform Cloud variables or AWS Secrets Manager

rds_instance_class    = "db.m6i.large"
rds_allocated_storage = 30

eks_instance_types    = ["m6in.xlarge", "m5.large"]  # Example of multiple instance types
