# SOP: Deploying OpenGovernance on AWS with HTTPS Using Terraform and Helm

This Standard Operating Procedure (SOP) provides streamlined, step-by-step instructions to deploy the OpenGovernance platform on AWS. The deployment leverages Terraform for infrastructure provisioning and Helm for application deployment. Additionally, it covers setting up an Application Load Balancer (ALB) with HTTPS using AWS Certificate Manager (ACM), configuring Kubernetes Ingress via `kubectl`, and updating DNS records.

---

## Prerequisites

Ensure the following tools and configurations are in place before proceeding:

- **Git**: For cloning repositories.
- **Terraform**: For Infrastructure as Code (IaC) deployments.
- **AWS CLI**: For interacting with AWS services.
- **kubectl**: For managing Kubernetes clusters.
- **Helm**: For deploying applications on Kubernetes.
- **AWS Account**: With permissions to create necessary resources.
- **Domain Name**: Owned and managed via a DNS provider.
- **AWS Credentials**: Configured with sufficient permissions.

---

## Overview

The deployment process is organized into three main steps:

1. **Create the Kubernetes Cluster**
2. **Install the OpenGovernance Application**
3. **Set Up HTTPS and Load Balancer**

---

## Steps

### 1. Create the Kubernetes Cluster

#### **A. Clone the Terraform Repository**

1. **Clone the Repository and Navigate to EKS Directory:**

    ```sh
    git clone https://github.com/opengovern/deployment-automation.git
    cd deployment-automation/eks
    ```

#### **B. Configure Terraform Variables**

1. **Create a `terraform.tfvars` File:**

    ```sh
    cat <<EOF > terraform.tfvars
    region                = "us-east-1"                 # e.g., "us-east-1"
    environment           = "production"                # e.g., "staging" or "production"
    domain_name           = "your.domain.com"           # Your domain name
    certificate_arn       = "arn:aws:acm:your-region:account-id:certificate/certificate-id"
    rds_master_username   = "your-db-username"
    rds_master_password   = "your-db-password"           # Use a secure password
    rds_instance_class    = "db.m6i.large"               # e.g., "db.m6i.large"
    rds_allocated_storage = 20                           # Adjust as needed
    eks_instance_types    = ["m6in.xlarge"]              # e.g., ["m6in.xlarge"]
    EOF
    ```

    **Note:**
    - Replace placeholders with actual values.
    - Ensure sensitive information like `rds_master_password` is handled securely and not committed to version control.

#### **C. Deploy Infrastructure with Terraform**

1. **Initialize Terraform:**

    ```sh
    terraform init
    ```

2. **Validate the Configuration (Optional):**

    ```sh
    terraform validate
    ```

3. **Plan the Deployment (Optional):**

    ```sh
    terraform plan
    ```

4. **Apply the Terraform Configuration:**

    ```sh
    terraform apply
    ```

5. **Confirm the Deployment:**

    When prompted, type `yes` to proceed.

    ```
    Do you want to perform these actions?
      Terraform will perform the actions described above.
      Only 'yes' will be accepted to approve.
    
      Enter a value: yes
    ```

---

### 2. Install the OpenGovernance Application

#### **A. Configure `kubectl` Access**

1. **Retrieve and Execute the `kubectl` Configuration Command:**

    ```sh
    eval "$(terraform output -raw configure_kubectl)"
    ```

2. **Verify Cluster Access:**

    ```sh
    kubectl get nodes
    ```

    You should see a list of nodes in your EKS cluster.

#### **B. Add the OpenGovernance Helm Repository**

1. **Add and Update Helm Repositories:**

    ```sh
    helm repo add opengovernance https://opengovern.github.io/charts
    helm repo update
    ```

#### **C. Deploy the OpenGovernance Application**

1. **Install OpenGovernance in the `opengovernance` Namespace:**

    ```sh
    helm install opengovernance opengovernance/opengovernance \
      -n opengovernance --create-namespace \
      --timeout 10m
    ```

2. **Verify the Deployment:**

    ```sh
    helm status opengovernance -n opengovernance
    kubectl get pods -n opengovernance
    ```

    Ensure all pods are running without issues.

---

### 3. Set Up HTTPS and Load Balancer

#### **A. Obtain an ACM Certificate**

##### **Option A: Via AWS Console**

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

8. **Wait for Validation:**

    - ACM will validate the domain once the DNS records propagate.

9. **Record the Certificate ARN:**

    - After validation, note down the **Certificate ARN** from the ACM console.

##### **Option B: Via AWS CLI**

1. **Request an ACM Certificate:**

    Replace `your.domain.com` with your actual domain name and `your-region` with the desired AWS region.

    ```sh
    aws acm request-certificate \
      --domain-name your.domain.com \
      --validation-method DNS \
      --idempotency-token deploy-2024 \
      --region your-region
    ```

    **Example:**

    ```sh
    aws acm request-certificate \
      --domain-name example.opengovernance.io \
      --validation-method DNS \
      --idempotency-token deploy-2024 \
      --region us-east-1
    ```

2. **Retrieve the Certificate ARN and DNS Validation Records:**

    ```sh
    CERTIFICATE_ARN=$(aws acm list-certificates --region your-region --query "CertificateSummaryList[?DomainName=='your.domain.com'].CertificateArn" --output text)
    echo "Certificate ARN: $CERTIFICATE_ARN"

    VALIDATION_RECORDS=$(aws acm describe-certificate --certificate-arn $CERTIFICATE_ARN --region your-region --query "Certificate.DomainValidationOptions[].ResourceRecord" --output json)
    echo "Validation Records: $VALIDATION_RECORDS"
    ```

3. **Add DNS CNAME Records:**

    - Log in to your DNS provider.
    - Create the CNAME records as specified in the `VALIDATION_RECORDS` output.

4. **Wait for Validation:**

    - ACM will validate the domain once the DNS records propagate.

5. **Confirm Certificate Issuance:**

    ```sh
    aws acm describe-certificate --certificate-arn $CERTIFICATE_ARN --region your-region
    ```

    Ensure the `Status` is `ISSUED`.

#### **B. Export Domain Name and Certificate ARN as Environment Variables**

1. **Set Environment Variables:**

    ```sh
    export DOMAIN_NAME="your.domain.com"
    export CERTIFICATE_ARN="arn:aws:acm:your-region:account-id:certificate/certificate-id"
    ```

    **Ensure you replace the placeholders with your actual domain and certificate ARN.**

#### **C. Configure Kubernetes Ingress with HTTPS**

1. **Create the Ingress Resource Using Environment Variables:**

    Use a heredoc to define and apply the Ingress YAML, injecting environment variables for `DOMAIN_NAME` and `CERTIFICATE_ARN`:

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
                    name: nginx-proxy  # Replace with actual service name if different
                    port:
                      number: 80
    EOF
    ```

2. **Verify Ingress Creation:**

    ```sh
    kubectl get ingress opengovernance-ingress -n opengovernance
    ```

    You should see the Ingress status with the Load Balancer details.

#### **D. Create DNS CNAME Record**

1. **Retrieve the Load Balancer DNS Name:**

    ```sh
    LB_DNS=$(kubectl get ingress opengovernance-ingress -n opengovernance -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    echo "Load Balancer DNS: $LB_DNS"
    ```

2. **Add a CNAME Record:**

    - **Log in to Your DNS Provider:**
      
      Access your DNS management console (e.g., Route 53, GoDaddy, etc.).

    - **Create a CNAME Record:**
      
      - **Host/Name**: `your.domain.com` (replace with your actual domain).
      - **Type**: `CNAME`.
      - **Value/Points to**: `$LB_DNS`.
      - **TTL**: Set to default or as desired.

    - **Save the Record:**
      
      Apply the changes and wait for DNS propagation (can take a few minutes to hours).

3. **Verify DNS Propagation:**

    Use tools like `dig` or online DNS checkers to verify that the CNAME record is correctly pointing to the Load Balancer.

    ```sh
    dig your.domain.com CNAME
    ```

---

### 4. Accessing the OpenGovernance Platform

Once DNS propagation is complete, access OpenGovernance via your domain:

```sh
https://your.domain.com
```

**Note:** Ensure you replace `your.domain.com` with your actual domain name.

---

## Cleanup

To remove all deployed resources, run the following command:

```sh
terraform destroy
```

When prompted, type `yes` to confirm:

```
Do you really want to destroy all resources?
  Terraform will destroy all your managed infrastructure, as shown above.
  There is no undo. Only 'yes' will be accepted to confirm.

  Enter a value: yes
```

**Caution:** This action deletes all resources managed by Terraform. Ensure you no longer need them before proceeding.

---

## Troubleshooting

- **ACM Certificate Not Validated:**
  - Ensure DNS CNAME records for validation are correctly added.
  - Wait for DNS propagation and certificate status to update.

- **Ingress Not Creating Load Balancer:**
  - Verify Ingress annotations and ensure the AWS ALB Ingress Controller is deployed.
  - Check Kubernetes events for errors:
    ```sh
    kubectl describe ingress opengovernance-ingress -n opengovernance
    ```

- **Cannot Access OpenGovernance:**
  - Confirm DNS CNAME records are correctly pointing to the Load Balancer.
  - Ensure the Load Balancer is active and serving traffic.
  - Check Helm deployment and Kubernetes pods status.

- **`kubectl` Connection Issues:**
  - Re-run the `kubectl` configuration command to ensure correct setup.
  - Verify AWS CLI is authenticated and has necessary permissions.

- **Helm Deployment Issues:**
  - If the Helm installation fails, check the pod logs for errors:
    ```sh
    kubectl logs -n opengovernance <pod-name>
    ```

---

## Best Practices

- **Version Control:**
  - Keep Terraform and Helm configurations in a version-controlled repository.
  - Avoid committing sensitive information like passwords and certificates.

- **Security:**
  - Use AWS IAM roles with least privilege required for deployments.
  - Rotate secrets and credentials regularly.
  - Securely manage secrets and sensitive data using tools like AWS Secrets Manager or Kubernetes Secrets.

- **Monitoring:**
  - Implement monitoring and logging for Kubernetes and AWS resources to track performance and issues.

- **Infrastructure Management:**
  - Use `terraform plan` to review changes before applying.
  - Regularly update Terraform and Helm to the latest stable versions for security and feature improvements.

---

## Summary

By following this SOP, you have successfully:

1. **Created the Kubernetes Cluster:**
   - Deployed AWS infrastructure, including an EKS cluster using Terraform.

2. **Installed the OpenGovernance Application:**
   - Configured `kubectl` access and deployed OpenGovernance via Helm.

3. **Set Up HTTPS and Load Balancer:**
   - Obtained an ACM certificate, configured Kubernetes Ingress with HTTPS, and updated DNS records to point your domain to the Load Balancer.

You can now access the OpenGovernance platform securely via your domain.

---

**Remember**: Always adhere to your organization's security policies and best practices when deploying and managing infrastructure and applications.