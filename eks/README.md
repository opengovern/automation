# SOP: Deploying OpenGovernance on AWS using Terraform and Helm

This Standard Operating Procedure (SOP) provides detailed instructions for deploying the OpenGovernance platform on AWS using Terraform for infrastructure provisioning and Helm for application deployment. The steps include cloning the Terraform configuration from GitHub, configuring variables, deploying the infrastructure, accessing the Kubernetes cluster using `kubectl`, and installing the OpenGovernance application via Helm.

---

## Prerequisites

Before you begin, ensure you have the following installed and configured on your machine:

- **Git**: For cloning the repository.
- **Terraform**: For deploying infrastructure as code.
- **AWS CLI**: For AWS interactions and configuring `kubectl`.
- **kubectl**: For managing the Kubernetes cluster.
- **Helm**: For deploying applications on Kubernetes.
- **AWS Credentials**: Configured with sufficient permissions to create the necessary resources.

---

## Overview

The deployment process involves the following major steps:

1. **Clone the Terraform Repository**: Get the infrastructure code.
2. **Configure Variables**: Customize your deployment settings.
3. **Deploy Infrastructure with Terraform**: Provision AWS resources.
4. **Configure kubectl Access**: Access your Kubernetes cluster.
5. **Install OpenGovernance Application**: Deploy the app using Helm.
6. **Access OpenGovernance**: Verify the deployment.

---

## Steps

### 1. Clone the Terraform Repository

Clone the Terraform configuration repository from GitHub and navigate to the `eks` directory:

```sh
git clone https://github.com/opengovern/deployment-automation.git
cd deployment-automation/eks
```

### 2. Review and Modify Variables

#### **Option A: Use Default Variables**

The Terraform configuration includes a `variables.tf` file with default values:

```hcl
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
  default     = "UberSecretPassword"  # Consider using a more secure method to manage secrets.
}

# Additional variables...
```

#### **Option B: Create a `terraform.tfvars` File**

To customize variable values without modifying the `variables.tf` file, create a `terraform.tfvars` file in the same directory:

```hcl
region                = "your-aws-region"
environment           = "your-environment"            # e.g., "staging" or "production"
rds_master_username   = "your-db-username"
rds_master_password   = "your-db-password"            # Use a secure password
rds_instance_class    = "your-rds-instance-class"     # e.g., "db.m6i.large"
rds_allocated_storage = your-allocated-storage        # e.g., 20
eks_instance_types    = ["your-eks-instance-type"]    # e.g., ["m6in.xlarge"]
```

**Note:** Replace the placeholders with your desired values. Ensure sensitive values like passwords are stored securely and are not committed to version control.

### 3. Initialize Terraform

Initialize the Terraform working directory to download necessary providers and modules:

```sh
terraform init
```

### 4. Validate the Terraform Configuration (Optional)

Validate your Terraform configuration before applying:

```sh
terraform validate
```

### 5. Plan the Deployment (Optional)

Review the changes Terraform will make without actually applying them:

```sh
terraform plan
```

### 6. Deploy the Infrastructure

Apply the Terraform configuration to deploy the infrastructure:

```sh
terraform apply
```

### 7. Confirm the Deployment

When prompted, type `yes` to confirm the deployment:

```
Do you want to perform these actions?
  Terraform will perform the actions described above.
  Only 'yes' will be accepted to approve.

  Enter a value: yes
```

### 8. Wait for Deployment to Complete

Terraform will provision the resources. This process may take several minutes. Upon completion, Terraform will output important information, including commands to configure `kubectl`.

### 9. Configure `kubectl` to Access the EKS Cluster

After the cluster is created, configure `kubectl` to connect to your new EKS cluster using the command provided in the Terraform outputs.

#### **A. Retrieve the `kubectl` Configuration Command**

The Terraform configuration includes an output named `configure_kubectl`. Retrieve this command:

```sh
terraform output configure_kubectl
```

This will display a command similar to:

```
configure_kubectl = "aws eks --region your-aws-region update-kubeconfig --name your-cluster-name"
```

#### **B. Run the Command to Update `kubectl` Configuration**

Execute the command provided by Terraform to configure `kubectl`:

```sh
aws eks --region your-aws-region update-kubeconfig --name your-cluster-name
```

- Replace `your-aws-region` and `your-cluster-name` with the values from the Terraform output if necessary.

#### **C. Verify Cluster Access**

Test the connection:

```sh
kubectl get nodes
```

You should see a list of nodes in your EKS cluster, confirming that `kubectl` is correctly configured.

---

### 10. Install the OpenGovernance Application via Helm

With the Kubernetes cluster up and `kubectl` configured, install the OpenGovernance application using Helm.

#### **A. Add the OpenGovernance Helm Repository**

Add the OpenGovernance Helm repository and update Helm repositories:

```sh
helm repo add opengovernance https://opengovern.github.io/charts
helm repo update
```

#### **B. Deploy the OpenGovernance Application**

Run the following command to deploy the OpenGovernance application inside the `opengovernance` namespace:

```sh
helm install -n opengovernance opengovernance opengovernance/opengovernance --create-namespace --timeout=10m
```

- **Explanation:**
  - `helm install`: Command to install a Helm chart.
  - `-n opengovernance`: Specifies the Kubernetes namespace.
  - `opengovernance`: The release name.
  - `opengovernance/opengovernance`: Chart reference (`repository/chart`).
  - `--create-namespace`: Creates the namespace if it doesn't exist.
  - `--timeout=10m`: Sets the timeout for the operation to 10 minutes.

#### **C. Verify the Deployment**

Check the status of the deployment:

```sh
helm status opengovernance -n opengovernance
```

List the pods to ensure they are running:

```sh
kubectl get pods -n opengovernance
```

---

### 11. Accessing the OpenGovernance Platform

With the application deployed, you can now access the OpenGovernance platform.

#### **A. Retrieve the Load Balancer DNS Name**

Get the DNS name of the load balancer provisioned for OpenGovernance:

```sh
kubectl get ingress -n opengovernance
```

This will display the ingress resource, including the hostname of the load balancer.

Alternatively, use Terraform output if available:

```sh
terraform output opengovernance_lb_dns_name
```

#### **B. Access OpenGovernance**

Open a web browser and navigate to:

```
http://your-load-balancer-dns-name
```

- Replace `your-load-balancer-dns-name` with the actual DNS name from the ingress or Terraform output.

---

## Notes

- **AWS Credentials**: Ensure your AWS CLI is configured with credentials that have sufficient permissions to create resources.
- **Security**: Treat sensitive information like passwords and secrets securely. Avoid committing them to version control.
- **Cleanup**: To remove all resources created by Terraform and Helm, run:

  ```sh
  terraform destroy
  ```

  Confirm the destruction by typing `yes` when prompted.

- **Terraform Outputs**: The Terraform configuration provides outputs to assist you, such as commands to configure `kubectl`.

---

## Example Commands

Assuming you are deploying to `us-east-1` and have customized your variables in `terraform.tfvars`:

### Initialize Terraform

```sh
terraform init
```

### Apply the Terraform Configuration

```sh
terraform apply
```

### Retrieve the `kubectl` Configuration Command

```sh
terraform output configure_kubectl
```

### Configure `kubectl`

Copy and paste the command output by Terraform, for example:

```sh
aws eks --region us-east-1 update-kubeconfig --name your-cluster-name
```

### Verify `kubectl` Access

```sh
kubectl get nodes
```

### Add the OpenGovernance Helm Repository

```sh
helm repo add opengovernance https://opengovern.github.io/charts
helm repo update
```

### Install OpenGovernance via Helm

```sh
helm install -n opengovernance opengovernance opengovernance/opengovernance --create-namespace --timeout=10m
```

### Verify the Deployment

```sh
helm status opengovernance -n opengovernance
kubectl get pods -n opengovernance
```

---

## Additional Information

### Variable Descriptions

- **region**: AWS region to deploy resources (e.g., `us-east-1`, `us-west-2`).
- **environment**: Deployment environment (`dev`, `staging`, `production`).
- **rds_master_username**: Username for the RDS database.
- **rds_master_password**: Password for the RDS database.
- **rds_instance_class**: Instance class for RDS (e.g., `db.m6i.large`).
- **rds_allocated_storage**: Storage allocated for RDS in GB (e.g., `20`).
- **eks_instance_types**: List of EC2 instance types for the EKS node group (e.g., `["m6in.xlarge"]`).

### AWS Credentials Configuration

If you haven't configured AWS CLI credentials, you can do so using:

```sh
aws configure
```

You will be prompted to enter your AWS Access Key ID, Secret Access Key, region, and output format.

### Accessing the OpenGovernance Platform

- **Ingress Resource**: The Kubernetes ingress is configured to expose the OpenGovernance application.
- **Load Balancer**: An AWS Application Load Balancer (ALB) is created by the ingress controller.
- **DNS Name**: Use the DNS name provided by the ingress to access the application.

---

## Troubleshooting

- **Terraform Errors**: If you encounter errors during `terraform apply`, review the error messages for guidance.
- **AWS CLI Issues**: Ensure the AWS CLI is installed and properly configured with the necessary permissions.
- **kubectl Connection Issues**: Verify that the AWS CLI command to update `kubeconfig` was successful and that you are using the correct cluster name and region.
- **Helm Deployment Issues**: If the Helm installation fails, check the pod logs for errors.
- **Accessing OpenGovernance**: If you cannot access the platform, ensure that the load balancer DNS name is correct and that all pods are running.

---

## Best Practices

- **Version Control**: Keep your infrastructure code in version control (e.g., Git) but avoid committing sensitive information.
- **Security**:
  - Use AWS IAM roles and policies to grant the least privilege necessary.
  - Securely manage secrets and sensitive data.
- **Infrastructure Updates**: When making changes to the infrastructure, use `terraform plan` to review changes before applying.
- **Monitoring and Logging**: Implement monitoring and logging to track the health of your application and infrastructure.
- **Resource Cleanup**: Regularly review and clean up unused resources to minimize costs.

---

## Conclusion

By following this SOP, you have successfully deployed the OpenGovernance platform on AWS using Terraform for infrastructure provisioning and Helm for application deployment. You have configured access to your Kubernetes cluster using `kubectl` and installed the OpenGovernance application.

---

**Remember**: Always adhere to your organization's security policies and best practices when deploying and managing infrastructure and applications.