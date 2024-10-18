#!/bin/bash

set -euo pipefail

# -----------------------------
# Configuration Variables
# -----------------------------

# Retrieve the domain name from an external source (environment variable or argument)
# Priority: Command-line argument > Environment variable > Prompt the user
if [[ $# -ge 1 ]]; then
    DOMAIN="$1"
elif [[ -n "${DOMAIN:-}" ]]; then
    DOMAIN="$DOMAIN"
else
    read -p "Enter the domain name (e.g., demo.opengovernance.io): " DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        echo "Error: DOMAIN is not set. Please provide a domain name."
        exit 1
    fi
fi

# Determine AWS region from AWS CLI configuration
REGION=$(aws configure get region)

if [[ -z "$REGION" ]]; then
    echo "Error: AWS region is not set in your AWS CLI configuration."
    echo "Please configure it using 'aws configure' or set the AWS_REGION environment variable."
    exit 1
fi

echo "Using AWS Region: $REGION"

# Kubernetes namespace and Ingress name
NAMESPACE="opengovernance"
INGRESS_NAME="opengovernance-ingress"

# Helm release name and chart repository (used in update-application.sh)
HELM_RELEASE="opengovernance"
HELM_CHART="opengovernance/opengovernance"

# Time between status checks (in seconds)
CHECK_INTERVAL=60

# Maximum number of checks (e.g., 60 checks = ~1 hour)
MAX_CHECKS=60

# -----------------------------
# Function Definitions
# -----------------------------

# Function to request a new ACM certificate
request_certificate() {
    echo "Requesting a new ACM certificate for domain: $DOMAIN"

    # Option A: Replace hyphen with underscore
    REQUEST_OUTPUT=$(aws acm request-certificate \
        --domain-name "$DOMAIN" \
        --validation-method DNS \
        --idempotency-token "deploy_$(date +%Y%m%d%H%M%S)" \
        --region "$REGION")

    # Option B: Remove hyphen entirely
    # REQUEST_OUTPUT=$(aws acm request-certificate \
    #     --domain-name "$DOMAIN" \
    #     --validation-method DNS \
    #     --idempotency-token "deploy$(date +%Y%m%d%H%M%S)" \
    #     --region "$REGION")

    CERTIFICATE_ARN=$(echo "$REQUEST_OUTPUT" | jq -r '.CertificateArn')
    echo "Certificate ARN: $CERTIFICATE_ARN"
}

# Function to retrieve existing ACM certificate ARN
get_certificate_arn() {
    echo "Searching for existing ACM certificates for domain: $DOMAIN"
    CERTIFICATE_ARN=$(aws acm list-certificates \
        --region "$REGION" \
        --query "CertificateSummaryList[?DomainName=='$DOMAIN'].CertificateArn" \
        --output text)

    if [[ -z "$CERTIFICATE_ARN" ]]; then
        echo "No existing ACM certificate found for domain: $DOMAIN"
        CERTIFICATE_ARN=""
    else
        echo "Found existing Certificate ARN: $CERTIFICATE_ARN"
    fi
}

# Function to check certificate status
check_certificate_status() {
    local arn=$1
    STATUS=$(aws acm describe-certificate \
        --certificate-arn "$arn" \
        --region "$REGION" \
        --query "Certificate.Status" \
        --output text)

    echo "Certificate Status: $STATUS"

    echo "$STATUS"
}

# Function to get DNS validation records
get_validation_records() {
    local arn=$1
    echo "Retrieving DNS validation records..."
    VALIDATION_RECORDS=$(aws acm describe-certificate \
        --certificate-arn "$arn" \
        --region "$REGION" \
        --query "Certificate.DomainValidationOptions[].ResourceRecord" \
        --output json)

    echo "Validation Records:"
    echo "$VALIDATION_RECORDS" | jq
    echo ""
    echo "Please create the above CNAME records in your DNS provider to validate the certificate."
}

# Function to create Ingress
create_ingress() {
    echo "Creating or updating Kubernetes Ingress: $INGRESS_NAME in namespace: $NAMESPACE"

    kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  namespace: $NAMESPACE
  name: $INGRESS_NAME
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
    - host: "$DOMAIN"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: nginx-proxy  # Replace with your actual service name if different
                port:
                  number: 80
EOF

    echo "Ingress $INGRESS_NAME has been created/updated."
}

# Function to retrieve Load Balancer DNS Name
get_load_balancer_dns() {
    echo "Retrieving Load Balancer DNS name..."
    LB_DNS=$(kubectl get ingress "$INGRESS_NAME" -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

    if [[ -z "$LB_DNS" ]]; then
        echo "Failed to retrieve Load Balancer DNS. It might not be available yet."
        return 1
    fi

    echo "Load Balancer DNS: $LB_DNS"
    return 0
}

# Function to prompt user to create CNAME record
prompt_cname_creation() {
    echo ""
    echo "==============================="
    echo "CNAME Record Creation Required"
    echo "==============================="
    echo "Please create a CNAME record in your DNS provider with the following details:"

    # Extract CNAME details using jq
    CNAME_HOST=$(echo "$VALIDATION_RECORDS" | jq -r '.[0].Name')
    CNAME_VALUE=$(echo "$VALIDATION_RECORDS" | jq -r '.[0].Value')

    echo "Host/Name: $CNAME_HOST"
    echo "Type: CNAME"
    echo "Value/Points to: $CNAME_VALUE"
    echo "TTL: 300 (or default)"
    echo ""
    echo "After creating the CNAME record, please wait for DNS propagation to complete."
    echo "You can use tools like [DNS Checker](https://dnschecker.org/) to verify the propagation."
}

# Function to wait for ACM certificate to be issued
wait_for_certificate_issuance() {
    local arn=$1
    local attempts=0

    echo "Starting to monitor the certificate status. This may take some time..."

    while [[ $attempts -lt $MAX_CHECKS ]]; do
        STATUS=$(check_certificate_status "$arn")
        if [[ "$STATUS" == "ISSUED" ]]; then
            echo "Certificate is now ISSUED."
            return 0
        elif [[ "$STATUS" == "PENDING_VALIDATION" ]]; then
            echo "Certificate is still PENDING_VALIDATION. Waiting for $CHECK_INTERVAL seconds before retrying..."
            ((attempts++))
            sleep "$CHECK_INTERVAL"
        else
            echo "Certificate status is '$STATUS'. Exiting."
            exit 1
        fi
    done

    echo "Reached maximum number of checks ($MAX_CHECKS). Certificate was not issued within the expected time."
    exit 1
}

# -----------------------------
# Main Execution Flow
# -----------------------------

# Ensure required tools are installed
for cmd in aws jq kubectl dig; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: Required command '$cmd' is not installed."
        exit 1
    fi
done

# Step 1: Check if ACM Certificate exists and its status
get_certificate_arn

if [[ -n "$CERTIFICATE_ARN" ]]; then
    STATUS=$(check_certificate_status "$CERTIFICATE_ARN")
    if [[ "$STATUS" == "ISSUED" ]]; then
        echo "Existing ACM certificate is ISSUED. Proceeding to create/update Ingress."
    elif [[ "$STATUS" == "PENDING_VALIDATION" ]]; then
        echo "Existing ACM certificate is PENDING_VALIDATION."
        get_validation_records "$CERTIFICATE_ARN"
        prompt_cname_creation
        echo "Waiting for ACM certificate to be issued..."
        wait_for_certificate_issuance "$CERTIFICATE_ARN"
    else
        echo "Certificate status is '$STATUS'. Exiting."
        exit 1
    fi
else
    # Step 2: Create ACM Certificate
    request_certificate
    # Retrieve the ARN again if necessary
    get_certificate_arn

    if [[ -z "$CERTIFICATE_ARN" ]]; then
        echo "Error: Failed to retrieve Certificate ARN after requesting."
        exit 1
    fi

    STATUS=$(check_certificate_status "$CERTIFICATE_ARN")

    if [[ "$STATUS" == "PENDING_VALIDATION" ]]; then
        get_validation_records "$CERTIFICATE_ARN"
        prompt_cname_creation
        echo "Waiting for ACM certificate to be issued..."
        wait_for_certificate_issuance "$CERTIFICATE_ARN"
    elif [[ "$STATUS" == "ISSUED" ]]; then
        echo "Certificate is already ISSUED."
    else
        echo "Certificate status is '$STATUS'. Exiting."
        exit 1
    fi
fi

# At this point, the certificate is ISSUED. Proceed to create/update Ingress.

# Step 3: Create or update Ingress
create_ingress

# Step 4: Retrieve Load Balancer DNS
if get_load_balancer_dns; then
    :
else
    echo "Load Balancer DNS not available yet. Proceeding without it."
fi

# Step 5: Save necessary details for update-application.sh
echo "Saving Certificate ARN and Load Balancer DNS to 'ingress_details.env'..."
cat <<EOF > ingress_details.env
DOMAIN="${DOMAIN}"
CERTIFICATE_ARN="${CERTIFICATE_ARN}"
LB_DNS="${LB_DNS:-}"
NAMESPACE="${NAMESPACE}"
INGRESS_NAME="${INGRESS_NAME}"
HELM_RELEASE="${HELM_RELEASE}"
HELM_CHART="${HELM_CHART}"
EOF

echo "Details saved to 'ingress_details.env'."

echo ""
echo "======================================="
echo "Ingress Creation Completed Successfully!"
echo "======================================="
echo "Your service should now be accessible at https://$DOMAIN once all validations are complete."
echo "Next, run 'update-application.sh' to update the Helm release and restart services."
echo "======================================="
```