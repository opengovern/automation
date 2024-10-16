# SOP: Deploying OpenGovernance on AWS with HTTPS Using Terraform and Helm

This Standard Operating Procedure (SOP) provides step-by-step instructions to deploy the OpenGovernance platform on AWS. The deployment utilizes Terraform for infrastructure provisioning and Helm for application deployment. Additionally, it covers setting up an Application Load Balancer (ALB) with HTTPS using AWS Certificate Manager (ACM), configuring Kubernetes Ingress via `kubectl`, and updating DNS records.

---

## Prerequisites

Ensure the following tools and configurations are in place before proceeding:

- **Git**: For cloning repositories.
- **Terraform**: For Infrastructure as Code (IaC) deployments.
- **AWS CLI**: For interacting with AWS services.
- **kubectl**: For managing Kubernetes clusters.
- **Helm**: For deploying Kubernetes applications.
- **AWS Account**: With permissions to create necessary resources.
- **Domain Name**: Owned and managed via a DNS provider.
- **AWS Credentials**: Configured with sufficient permissions.

---

## Overview

The deployment process includes:

1. **Cloning the Terraform Repository**
2. **Configuring Variables**
3. **Deploying Infrastructure with Terraform**
4. **Configuring `kubectl` Access**
5. **Obtaining an ACM Certificate**
6. **Setting Environment Variables**
7. **Installing OpenGovernance via Helm**
8. **Configuring Kubernetes Ingress with HTTPS**
9. **Creating DNS CNAME Record**
10. **Accessing OpenGovernance**

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

The repository contains a `variables.tf` file with predefined variables.

#### **Option B: Create a `terraform.tfvars` File**

To customize deployment settings, create a `terraform.tfvars` file:

```sh
cat <<EOF > terraform.tfvars
region                = "your-aws-region"            # e.g., "us-east-1"
environment           = "your-environment"           # e.g., "staging" or "production"
domain_name           = "your.domain.com"            # Your domain name
certificate_arn       = "your-acm-certificate-arn"   # ACM Certificate ARN
rds_master_username   = "your-db-username"
rds_master_password   = "your-db-password"           # Use a secure password
rds_instance_class    = "your-rds-instance-class"    # e.g., "db.m6i.large"
rds_allocated_storage = 20                           # Adjust as needed
eks_instance_types    = ["m6in.xlarge"]              # e.g., ["m6in.xlarge"]
EOF
```

**Note:**
- Replace placeholders with actual values.
- Ensure sensitive information like `rds_master_password` is handled securely and not committed to version control.

### 3. Deploy Infrastructure with Terraform

#### **A. Initialize Terraform**

Initialize the Terraform working directory to download necessary providers and modules:

```sh
terraform init
```

#### **B. Validate the Configuration (Optional)**

Validate the Terraform configuration to ensure correctness:

```sh
terraform validate
```

#### **C. Plan the Deployment (Optional)**

Review the planned actions without applying them:

```sh
terraform plan
```

#### **D. Apply the Terraform Configuration**

Deploy the infrastructure:

```sh
terraform apply
```

#### **E. Confirm the Deployment**

When prompted, type `yes` to proceed:

```
Do you want to perform these actions?
  Terraform will perform the actions described above.
  Only 'yes' will be accepted to approve.

  Enter a value: yes
```

### 4. Configure `kubectl` Access

After Terraform completes, configure `kubectl` to interact with your EKS cluster.

#### **A. Retrieve the `kubectl` Configuration Command**

Use Terraform's output to get the command for configuring `kubectl`:

```sh
CONFIGURE_KUBECTL=$(terraform output -raw configure_kubectl)
echo "Run the following command to configure kubectl:"
echo "$CONFIGURE_KUBECTL"
```

#### **B. Execute the Configuration Command**

Run the command to update your `kubeconfig`:

```sh
eval "$CONFIGURE_KUBECTL"
```

#### **C. Verify Cluster Access**

Ensure `kubectl` can communicate with the cluster:

```sh
kubectl get nodes
```

You should see a list of nodes in your EKS cluster.

### 5. Obtain an ACM Certificate

To enable HTTPS, obtain an SSL/TLS certificate through AWS Certificate Manager (ACM).

#### **A. Request an ACM Certificate**

1. **Access AWS Certificate Manager:**

   Navigate to the [AWS Certificate Manager console](https://console.aws.amazon.com/acm/home).

2. **Request a Public Certificate:**

   - Click **Request a certificate**.
   - Choose **Request a public certificate**.
   - Click **Request a certificate**.

3. **Add Domain Names:**

   - Enter your domain name (e.g., `your.domain.com`).
   - Click **Next**.

4. **Select Validation Method:**

   - Choose **DNS validation**.
   - Click **Next**.

5. **Add Tags (Optional):**

   - Add any necessary tags.
   - Click **Review**.

6. **Confirm and Request:**

   - Review the details.
   - Click **Confirm and request**.

7. **Validate Domain Ownership:**

   - ACM provides CNAME records for DNS validation.
   - Add these CNAME records to your DNS provider.
   - Wait for ACM to validate and issue the certificate.

#### **B. Record the Certificate ARN**

Once validated, note down the **Certificate ARN** from the ACM console.

### 6. Set Environment Variables

Export the domain name and certificate ARN as environment variables to use in subsequent steps:

```sh
export DOMAIN_NAME="your.domain.com"
export CERTIFICATE_ARN="arn:aws:acm:your-region:account-id:certificate/certificate-id"
```

**Ensure you replace the placeholders with your actual domain and certificate ARN.**

### 7. Install OpenGovernance via Helm

With the Kubernetes cluster configured, deploy the OpenGovernance application using Helm.

#### **A. Add the OpenGovernance Helm Repository**

Add the repository and update Helm:

```sh
helm repo add opengovernance https://opengovern.github.io/charts
helm repo update
```

#### **B. Deploy the OpenGovernance Application**

Install OpenGovernance in the `opengovernance` namespace:

```sh
helm install opengovernance opengovernance/opengovernance \
  -n opengovernance --create-namespace \
  --timeout 10m
```

#### **C. Verify the Deployment**

Check the status of the Helm release and pods:

```sh
helm status opengovernance -n opengovernance
kubectl get pods -n opengovernance
```

Ensure all pods are running without issues.

### 8. Configure Kubernetes Ingress with HTTPS

Set up the Kubernetes Ingress resource to use the ACM certificate for HTTPS.

#### **A. Create the Ingress Resource Using Environment Variables**

Use a heredoc to define and apply the Ingress YAML, injecting environment variables for `domain_name` and `certificate_arn`:

```sh
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  namespace: opengovernance
  name: opengovernance-ingress
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/backend-protocol: HTTP
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS":443}]'
    alb.ingress.kubernetes.io/certificate-arn: "$CERTIFICATE_ARN"
    kubernetes.io/ingress.class: alb
spec:
  ingressClassName: alb
  rules:
    - host: "$DOMAIN_NAME"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: nginx-proxy
                port:
                  number: 80
EOF
```

**Explanation:**
- **`alb.ingress.kubernetes.io/certificate-arn`**: Uses the exported `CERTIFICATE_ARN`.
- **`host`**: Uses the exported `DOMAIN_NAME`.

#### **B. Verify Ingress Creation**

Ensure the Ingress resource is correctly applied:

```sh
kubectl get ingress opengovernance-ingress -n opengovernance
```

You should see the Ingress status with the Load Balancer details.

### 9. Create DNS CNAME Record

Point your domain to the Load Balancer by creating a DNS CNAME record.

#### **A. Retrieve the Load Balancer DNS Name**

Get the DNS name of the ALB from the Ingress status:

```sh
LB_DNS=$(kubectl get ingress opengovernance-ingress -n opengovernance -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "Load Balancer DNS: $LB_DNS"
```

#### **B. Create a CNAME Record**

1. **Log in to Your DNS Provider**:

   Access your DNS management console (e.g., Route 53, GoDaddy, etc.).

2. **Add a CNAME Record**:

   - **Host/Name**: `your.domain.com` (replace with your actual domain).
   - **Type**: `CNAME`.
   - **Value/Points to**: `$LB_DNS` (the Load Balancer DNS obtained above).
   - **TTL**: Set to default or as desired.

3. **Save the Record**:

   Apply the changes and wait for DNS propagation (can take a few minutes to hours).

### 10. Accessing the OpenGovernance Platform

Once DNS propagation is complete, access OpenGovernance via your domain.

```sh
https://your.domain.com
```

**Note:** Ensure you replace `your.domain.com` with your actual domain name.

---

## Outputs Provided by Terraform

The Terraform configuration includes outputs to assist in accessing and managing the deployed resources.

### 1. Configure `kubectl` Command

Retrieve the command to configure `kubectl`:

```sh
terraform output configure_kubectl
```

**Example Output:**

```
configure_kubectl = "aws eks --region your-aws-region update-kubeconfig --name your-cluster-name"
```

- **Usage**: Run the command to set up `kubectl` access.

### 2. Load Balancer DNS Name

Retrieve the Load Balancer DNS name:

```sh
kubectl get ingress opengovernance-ingress -n opengovernance -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

**Example Output:**

```
k8s-openg-overprov-1234567890.us-east-1.elb.amazonaws.com
```

---

## Cleanup

To remove all deployed resources, run the following command:

```sh
terraform destroy
```

When prompted, type `yes` to confirm the destruction:

```
Do you really want to destroy all resources?
  Terraform will destroy all your managed infrastructure, as shown above.
  There is no undo. Only 'yes' will be accepted to confirm.

  Enter a value: yes
```

**Caution:** This action deletes all resources managed by Terraform. Ensure you no longer need them before proceeding.

---

## Troubleshooting

- **ACM Certificate Not Validated**:
  - Ensure DNS CNAME records for validation are correctly added.
  - Wait for DNS propagation and certificate status to update.

- **Ingress Not Creating Load Balancer**:
  - Verify Ingress annotations and ensure the AWS ALB Ingress Controller is deployed.
  - Check Kubernetes events for errors: `kubectl describe ingress opengovernance-ingress -n opengovernance`

- **Cannot Access OpenGovernance**:
  - Confirm DNS CNAME records are correctly pointing to the Load Balancer.
  - Ensure the Load Balancer is active and serving traffic.
  - Check Helm deployment and Kubernetes pods status.

- **`kubectl` Connection Issues**:
  - Re-run the `configure_kubectl` command to ensure correct configuration.
  - Verify AWS CLI is authenticated and has necessary permissions.

---

## Best Practices

- **Version Control**:
  - Keep Terraform and Helm configurations in a version-controlled repository.
  - Avoid committing sensitive information like passwords and certificates.

- **Security**:
  - Use AWS IAM roles with least privilege required for deployments.
  - Rotate secrets and credentials regularly.

- **Monitoring**:
  - Implement monitoring and logging for Kubernetes and AWS resources to track performance and issues.

- **Infrastructure Management**:
  - Use `terraform plan` to review changes before applying.
  - Regularly update Terraform and Helm to the latest stable versions for security and feature improvements.
