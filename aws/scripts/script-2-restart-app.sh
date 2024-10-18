#!/bin/bash

set -euo pipefail

# -----------------------------
# Configuration Variables
# -----------------------------

# Load variables from ingress_details.env
if [[ -f "ingress_details.env" ]]; then
    source ingress_details.env
else
    echo "Error: 'ingress_details.env' file not found. Please run 'create-ingress.sh' first."
    exit 1
fi

# -----------------------------
# Function Definitions
# -----------------------------

# Function to wait for certificate to be issued
wait_for_certificate() {
    echo "Waiting for ACM certificate to be issued..."
    while true; do
        CURRENT_STATUS=$(aws acm describe-certificate --certificate-arn "$CERTIFICATE_ARN" --region "$REGION" --query "Certificate.Status" --output text)
        echo "Current certificate status: $CURRENT_STATUS"
        if [[ "$CURRENT_STATUS" == "ISSUED" ]]; then
            echo "Certificate has been issued."
            break
        elif [[ "$CURRENT_STATUS" == "PENDING_VALIDATION" ]]; then
            echo "Certificate is still pending validation. Waiting for 60 seconds before checking again..."
            sleep 60
        else
            echo "Certificate is in an unexpected state: $CURRENT_STATUS. Exiting."
            exit 1
        fi
    done
}

# Function to update Helm release
update_helm_release() {
    echo "Updating Helm release: $HELM_RELEASE with domain: $DOMAIN"
    
    helm upgrade "$HELM_RELEASE" "$HELM_CHART" -n "$NAMESPACE" -f <(cat <<EOF
global:
  domain: ${DOMAIN}
dex:
  config:
    issuer: https://${DOMAIN}/dex
EOF
)
    echo "Helm release $HELM_RELEASE has been updated."
}

# Function to restart Kubernetes pods
restart_pods() {
    echo "Restarting relevant Kubernetes pods to apply changes..."
    
    kubectl delete pods -l app=nginx-proxy -n "$NAMESPACE"
    kubectl delete pods -l app.kubernetes.io/name=dex -n "$NAMESPACE"
    
    echo "Pods are restarting..."
}

# -----------------------------
# Main Execution Flow
# -----------------------------

# Ensure required tools are installed
for cmd in aws kubectl helm; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: Required command '$cmd' is not installed."
        exit 1
    fi
done

# Step 6.1: Wait for certificate to be issued
wait_for_certificate

# Step 6.2: Update Helm release
update_helm_release

# Step 6.3: Restart relevant Kubernetes pods
restart_pods

echo ""
echo "======================================="
echo "Application Update Completed Successfully!"
echo "======================================="
echo "Your service should now be fully operational at https://$DOMAIN"
echo "======================================="