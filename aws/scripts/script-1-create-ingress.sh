#!/bin/bash

set -euo pipefail

# -----------------------------
# Configuration Variables
# -----------------------------

# Set your desired domain name
DOMAIN="demo.opengovernance.io"

# AWS region where ACM certificate is managed
REGION="us-east-1"

# Kubernetes namespace and Ingress name
NAMESPACE="opengovernance"
INGRESS_NAME="opengovernance-ingress"

# Helm release name and chart repository (used in update-application.sh)
HELM_RELEASE="opengovernance"
HELM_CHART="opengovernance/opengovernance"

# -----------------------------
# Function Definitions
# -----------------------------

# Function to request a new ACM certificate
request_certificate() {
    echo "Requesting a new ACM certificate for domain: $DOMAIN"
    REQUEST_OUTPUT=$(aws acm request-certificate \
        --domain-name "$DOMAIN" \
        --validation-method DNS \
        --idempotency-token "deploy-$(date +%Y%m%d%H%M%S)" \
        --region "$REGION")
    
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
    
    if [[ "$STATUS" == "PENDING_VALIDATION" ]]; then
        echo "Certificate is pending validation."
        get_validation_records "$arn"
        exit 0
    elif [[ "$STATUS" != "ISSUED" ]]; then
        echo "Certificate status is '$STATUS'. Exiting."
        exit 1
    else
        echo "Certificate is valid and issued."
    fi
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
        exit 1
    fi
    
    echo "Load Balancer DNS: $LB_DNS"
}

# Function to prompt user to create CNAME record
prompt_cname_creation() {
    echo ""
    echo "==============================="
    echo "CNAME Record Creation Required"
    echo "==============================="
    echo "Please create a CNAME record in your DNS provider with the following details:"
    echo "Host/Name: $DOMAIN"
    echo "Type: CNAME"
    echo "Value/Points to: $LB_DNS"
    echo "TTL: 300 (or default)"
    echo ""
    echo "After creating the CNAME record, please wait for DNS propagation to complete."
    echo "You can use tools like DNS Checker to verify the propagation."
    read -p "Press Enter to continue after creating the CNAME record..."
}

# Function to verify DNS propagation
verify_dns_propagation() {
    echo "Verifying DNS propagation for CNAME record..."
    while true; do
        # Attempt to resolve the CNAME
        RESOLVED=$(dig +short CNAME "$DOMAIN" @8.8.8.8)
        if [[ "$RESOLVED" == "$LB_DNS." ]]; then
            echo "CNAME record successfully propagated."
            break
        else
            echo "CNAME record not propagated yet. Retrying in 30 seconds..."
            sleep 30
        fi
    done
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
    check_certificate_status "$CERTIFICATE_ARN"
else
    # Step 2: Create ACM Certificate
    request_certificate
    CERTIFICATE_ARN=$(aws acm list-certificates \
        --region "$REGION" \
        --query "CertificateSummaryList[?DomainName=='$DOMAIN'].CertificateArn" \
        --output text)
fi

# At this point, CERTIFICATE_ARN should be set and valid
# Proceed only if the certificate is issued
# Note: If the certificate was pending validation, the script would have exited earlier

# Step 3: Load the Certificate ARN (already loaded as CERTIFICATE_ARN)

# Step 4: Create or update Ingress
create_ingress

# Ensure Ingress creation is complete by checking the Load Balancer DNS
get_load_balancer_dns

# Step 5: Create DNS CNAME records
prompt_cname_creation

# Optionally verify DNS propagation automatically
verify_dns_propagation

# --------------------------------
# Save necessary details for update-application.sh
# --------------------------------

# Export variables to a file for the next script
echo "Saving Certificate ARN and Load Balancer DNS to 'ingress_details.env'..."
cat <<EOF > ingress_details.env
DOMAIN="${DOMAIN}"
CERTIFICATE_ARN="${CERTIFICATE_ARN}"
LB_DNS="${LB_DNS}"
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