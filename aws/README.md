# Deploying OpenGovernance on AWS with HTTPS Using Terraform and Helm

This Standard Operating Procedure (SOP) provides streamlined, step-by-step instructions to deploy the OpenGovernance platform on AWS. The deployment leverages **Terraform** for infrastructure provisioning and **Helm** for application deployment. Additionally, it covers setting up an **Application Load Balancer (ALB)** with **HTTPS** using **AWS Certificate Manager (ACM)**, configuring **Kubernetes Ingress** via `kubectl`, and updating **DNS** records.

---

## Prerequisites

Ensure the following tools and configurations are in place before proceeding:

- **Git**: For cloning repositories.
- **Terraform**: For Infrastructure as Code (IaC) deployments.
- **AWS CLI**: For interacting with AWS services.
- **kubectl**: For managing Kubernetes clusters.
- **Helm**: For deploying applications on Kubernetes.
- **AWS Account**: With permissions to create necessary resources.
- **Domain Name**: `demo.opengovernance.io` owned and managed via a DNS provider.
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
    git clone https://github.com/opengovern/deploy-to-cloud.git
    cd deploy-to-cloud/eks
    ```

#### **B. Deploy Infrastructure with Terraform**

1. **Initialize Terraform:**

    Initialize the Terraform working directory to download necessary providers and modules.

    ```sh
    terraform init
    ```

2. **Apply the Terraform Configuration with Specified Region:**

    Deploy the infrastructure by specifying only the AWS region. Other variables will use their default values as defined in `variables.tf`.

    ```sh
    terraform apply -var="region=us-east-1"
    ```

3. **Confirm the Deployment:**

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

    Configure `kubectl` to interact with your newly created EKS cluster using Terraform's output.

    ```sh
    eval "$(terraform output -raw configure_kubectl)"
    ```

2. **Verify Cluster Access:**

    Ensure `kubectl` can communicate with the cluster.

    ```sh
    kubectl get nodes
    ```

    **Expected Output:**

    ```
    NAME                                           STATUS   ROLES    AGE   VERSION
    ip-XXX-XXX-XXX-XXX.us-east-1.compute.internal Ready    <none>   ...   ...
    ```

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

    **Ensure all pods are in the `Running` state.**

---

### 3. Set Up HTTPS and Load Balancer

#### **A. Obtain an ACM Certificate**

To enable HTTPS, you need an SSL/TLS certificate through AWS Certificate Manager (ACM).

##### **Option A: Via AWS Console**

1. **Access AWS Certificate Manager:**

    Navigate to the [AWS Certificate Manager console](https://console.aws.amazon.com/acm/home).

2. **Request a Public Certificate:**

    - Click **Request a certificate**.
    - Choose **Request a public certificate**.
    - Click **Request a certificate**.

3. **Add Domain Names:**

    - Enter your domain name: `demo.opengovernance.io`.
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

    ```sh
    aws acm request-certificate \
      --domain-name demo.opengovernance.io \
      --validation-method DNS \
      --idempotency-token deploy-2024 \
      --region us-east-1
    ```

2. **Retrieve the Certificate ARN and DNS Validation Records:**

    ```sh
    CERTIFICATE_ARN=$(aws acm list-certificates --region us-east-1 --query "CertificateSummaryList[?DomainName=='demo.opengovernance.io'].CertificateArn" --output text)
    echo "Certificate ARN: $CERTIFICATE_ARN"

    VALIDATION_RECORDS=$(aws acm describe-certificate --certificate-arn $CERTIFICATE_ARN --region us-east-1 --query "Certificate.DomainValidationOptions[].ResourceRecord" --output json)
    echo "Validation Records: $VALIDATION_RECORDS"
    ```

3. **Add DNS CNAME Records:**

    - Log in to your DNS provider.
    - Create the CNAME records as specified in the `VALIDATION_RECORDS` output.

4. **Wait for Validation:**

    - ACM will validate the domain once the DNS records propagate.

5. **Confirm Certificate Issuance:**

    ```sh
    aws acm describe-certificate --certificate-arn $CERTIFICATE_ARN --region us-east-1
    ```

    **Ensure the `Status` is `ISSUED`.**

#### **B. Export Domain Name and Certificate ARN as Environment Variables**

1. **Set Environment Variables:**

    ```sh
    export DOMAIN_NAME="demo.opengovernance.io"
    export CERTIFICATE_ARN="arn:aws:acm:us-east-1:account-id:certificate/certificate-id"
    ```

    **Ensure you replace `arn:aws:acm:us-east-1:account-id:certificate/certificate-id` with your actual Certificate ARN.**

#### **C. Configure Kubernetes Ingress with HTTPS**

1. **Create the Ingress Resource Using Environment Variables:**

    Use a heredoc to define and apply the Ingress YAML, injecting environment variables for `DOMAIN_NAME` and `CERTIFICATE_ARN`.

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

    **Expected Output:**

    ```
    NAME                        CLASS   HOSTS               ADDRESS                                             PORTS   AGE
    opengovernance-ingress      alb     demo.opengovernance.io k8s-openg-overprov-1234567890.us-east-1.elb.amazonaws.com   80, 443   ...
    ```

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

      - **Host/Name**: `demo.opengovernance.io`
      - **Type**: `CNAME`
      - **Value/Points to**: `$LB_DNS`
      - **TTL**: Set to default or as desired.

    - **Save the Record:**

      Apply the changes and wait for DNS propagation (can take a few minutes to hours).

3. **Verify DNS Propagation:**

    Use tools like `dig` or online DNS checkers to verify that the CNAME record is correctly pointing to the Load Balancer.

    ```sh
    dig demo.opengovernance.io CNAME
    ```

    **Expected Output:**

    ```
    ;; ANSWER SECTION:
    demo.opengovernance.io. 300 IN  CNAME k8s-openg-overprov-1234567890.us-east-1.elb.amazonaws.com.
    ```

---

## Cleanup

To remove all deployed resources, run the following command:

```sh
terraform destroy -var="region=us-east-1"
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
  - Check Helm deployment and Kubernetes pods status:

    ```sh
    helm status opengovernance -n opengovernance
    kubectl get pods -n opengovernance
    ```

- **`kubectl` Connection Issues:**
  - Re-run the `kubectl` configuration command to ensure correct setup.
  - Verify AWS CLI is authenticated and has necessary permissions.

- **Helm Deployment Issues:**
  - If the Helm installation fails, check the pod logs for errors:

    ```sh
    kubectl logs -n opengovernance <pod-name>
    ```