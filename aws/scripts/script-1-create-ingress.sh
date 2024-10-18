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
CHECK_INTERVAL_CERT=60      # For certificate status
CHECK_INTERVAL_LB=20        # For Load Balancer DNS
CHECK_COUNT_CERT=60        # Maximum number of certificate checks (~1 hour)
CHECK_COUNT_LB=6            # Maximum number of Load Balancer DNS checks (~120 seconds)

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

    # Option B: Remove hyphen entirely (Uncomment if preferred)
    # REQUEST_OUTPUT=$(aws acm request-certificate \
    #     --domain-name "$DOMAIN" \
    #     --validation-method DNS \
    #     --idempotency-token "deploy$(date +%Y%m%d%H%M%S)" \
    #     --region "$REGION")

    CERTIFICATE_ARN=$(echo "$REQUEST_OUTPUT" | jq -r '.CertificateArn')
    if [[ -z "$CERTIFICATE_ARN" || "$CERTIFICATE_ARN" == "null" ]]; then
        echo "Error: Failed to retrieve Certificate ARN after requesting."
        exit 1
    fi
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

# Function to retrieve Load Balancer DNS Name with polling
get_load_balancer_dns() {
    echo "Retrieving Load Balancer DNS name..."
    local attempt=1
    while [[ $attempt -le $CHECK_COUNT_LB ]]; do
        LB_DNS=$(kubectl get ingress "$INGRESS_NAME" -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)

        if [[ -n "$LB_DNS" ]]; then
            echo "Load Balancer DNS: $LB_DNS"
            return 0
        else
            echo "Attempt $attempt/$CHECK_COUNT_LB: Load Balancer DNS not available yet. Waiting for $CHECK_INTERVAL_LB seconds..."
            ((attempt++))
            sleep "$CHECK_INTERVAL_LB"
        fi
    done

    echo "Failed to retrieve Load Balancer DNS after $CHECK_COUNT_LB attempts."
    echo "Please check your Kubernetes Ingress resource manually."
    echo ""
    return 1
}

# Function to prompt user to create CNAME records for certificate validation
prompt_cname_validation_creation() {
    echo ""
    echo "==============================="
    echo "CNAME Record Creation Required"
    echo "==============================="
    echo "Please create the following CNAME records in your DNS provider to validate the certificate:"
    echo ""

    # Iterate over each validation record and display details
    echo "$VALIDATION_RECORDS" | jq -c '.[]' | while read -r RECORD; do
        CNAME_HOST=$(echo "$RECORD" | jq -r '.Name')
        CNAME_VALUE=$(echo "$RECORD" | jq -r '.Value')

        # Remove trailing dot for user-friendliness, if present
        CNAME_HOST="${CNAME_HOST%.}"
        CNAME_VALUE="${CNAME_VALUE%.}"

        echo "Host/Name: $CNAME_HOST"
        echo "Type: CNAME"
        echo "Value/Points to: $CNAME_VALUE"
        echo "TTL: 300 (or default)"
        echo ""
    done

    echo "After creating the CNAME records, please wait for DNS propagation to complete."
    echo "You can use tools like [DNS Checker](https://dnschecker.org/) to verify the propagation."
    read -p "Press Enter to continue after creating the CNAME records..."
}

# Function to prompt user to create CNAME records for domain mapping
prompt_cname_domain_creation() {
    echo ""
    echo "==============================="
    echo "CNAME Record Creation Required"
    echo "==============================="
    echo "Please create the following CNAME record in your DNS provider to map your domain to the Load Balancer:"
    echo ""

    echo "Host/Name: $DOMAIN"
    echo "Type: CNAME"
    echo "Value/Points to: $LB_DNS"
    echo "TTL: 300 (or default)"
    echo ""

    echo "After creating the CNAME record, your service should be accessible at https://$DOMAIN"
    echo ""
}

# Function to wait for ACM certificate to be issued
wait_for_certificate_issuance() {
    local arn=$1
    local attempts=0

    echo "Starting to monitor the certificate status. This may take some time..."

    while [[ $attempts -lt $CHECK_COUNT_CERT ]]; do
        STATUS=$(check_certificate_status "$arn")
        echo "Certificate Status: $STATUS"

        if [[ "$STATUS" == "ISSUED" ]]; then
            echo "Certificate is now ISSUED."
            return 0
        elif [[ "$STATUS" == "PENDING_VALIDATION" ]]; then
            echo "Certificate is still PENDING_VALIDATION. Waiting for $CHECK_INTERVAL_CERT seconds before retrying..."
            ((attempts++))
            sleep "$CHECK_INTERVAL_CERT"
        else
            echo "Certificate status is '$STATUS'. Exiting."
            exit 1
        fi
    done

    echo "Reached maximum number of checks ($CHECK_COUNT_CERT). Certificate was not issued within the expected time."
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
    echo "Certificate Status: $STATUS"
    if [[ "$STATUS" == "ISSUED" ]]; then
        echo "Existing ACM certificate is ISSUED. Proceeding to create/update Ingress."
    elif [[ "$STATUS" == "PENDING_VALIDATION" ]]; then
        echo "Existing ACM certificate is PENDING_VALIDATION."
        get_validation_records "$CERTIFICATE_ARN"
        prompt_cname_validation_creation
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
    echo "Certificate Status: $STATUS"

    if [[ "$STATUS" == "PENDING_VALIDATION" ]]; then
        get_validation_records "$CERTIFICATE_ARN"
        prompt_cname_validation_creation
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

# Step 4: Retrieve Load Balancer DNS with polling
echo "Ingress Creation Completed Successfully!"
echo "Your service should now be accessible at https://$DOMAIN once all validations are complete."
echo "Next, run 'update-application.sh' to update the Helm release and restart services."
echo "======================================="

# Check Load Balancer DNS every 20 seconds for up to 120 seconds
attempt=1
max_attempts=6
interval=20

while [[ $attempt -le $max_attempts ]]; do
    echo "Checking if Load Balancer DNS is available (Attempt $attempt/$max_attempts)..."
    LB_DNS=$(kubectl get ingress "$INGRESS_NAME" -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)

    if [[ -n "$LB_DNS" ]]; then
        echo "Load Balancer DNS is available: $LB_DNS"
        echo ""
        echo "==============================="
        echo "CNAME Record Creation Required"
        echo "==============================="
        echo "Please create the following CNAME record in your DNS provider to map your domain to the Load Balancer:"
        echo ""
        echo "Host/Name: $DOMAIN"
        echo "Type: CNAME"
        echo "Value/Points to: $LB_DNS"
        echo "TTL: 300 (or default)"
        echo ""
        echo "After creating the CNAME record, your service should be accessible at https://$DOMAIN"
        echo ""
        break
    else
        echo "Load Balancer DNS not available yet. Waiting for $interval seconds before retrying..."
        ((attempt++))
        sleep "$interval"
    fi
done

if [[ -z "$LB_DNS" ]]; then
    echo "Load Balancer DNS was not available after $max_attempts attempts."
    echo "Please check your Kubernetes Ingress resource manually and ensure the Load Balancer is provisioned correctly."
    echo ""
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
echo "Next, run 'script-2-restart-app.sh' to update the Helm release and restart services."