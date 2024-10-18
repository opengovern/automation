#!/bin/bash

set -euo pipefail

# -----------------------------
# Configuration Variables
# -----------------------------

# Define the Kubernetes namespace and Ingress name
NAMESPACE="opengovernance"
INGRESS_NAME="opengovernance-ingress"

# Helm release name and chart repository
HELM_RELEASE="opengovernance"
HELM_CHART="opengovernance/opengovernance"

# -----------------------------
# Function Definitions
# -----------------------------

# Function to check if a command exists
check_command() {
    local cmd=$1
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: Required command '$cmd' is not installed."
        exit 1
    fi
}

# Function to retrieve DOMAIN, CERTIFICATE_ARN, and LB_DNS from Ingress
get_ingress_details() {
    echo "Retrieving Ingress details from Kubernetes..."

    # Get DOMAIN from the Ingress rules
    DOMAIN=$(kubectl get ingress "$INGRESS_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.rules[0].host}')
    
    if [[ -z "$DOMAIN" ]]; then
        echo "Error: Unable to retrieve DOMAIN from Ingress rules."
        exit 1
    fi
    echo "DOMAIN: $DOMAIN"

    # Get CERTIFICATE_ARN from Ingress annotations
    CERTIFICATE_ARN=$(kubectl get ingress "$INGRESS_NAME" -n "$NAMESPACE" -o jsonpath='{.metadata.annotations.alb\.ingress\.kubernetes\.io/certificate-arn}')
    
    if [[ -z "$CERTIFICATE_ARN" ]]; then
        echo "Error: Unable to retrieve CERTIFICATE_ARN from Ingress annotations."
        exit 1
    fi
    echo "CERTIFICATE_ARN: $CERTIFICATE_ARN"

    # Get Load Balancer DNS from Ingress status
    LB_DNS=$(kubectl get ingress "$INGRESS_NAME" -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    
    if [[ -z "$LB_DNS" ]]; then
        echo "Error: Load Balancer DNS not available yet. Ensure Ingress is properly deployed."
        exit 1
    fi
    echo "Load Balancer DNS: $LB_DNS"
}

# Function to check CNAME resolution without dig
check_cname_resolution() {
    echo "Checking if CNAME for $DOMAIN is resolving correctly..."

    # Use nslookup if available, otherwise use host, otherwise use getent
    if command -v nslookup &> /dev/null; then
        CNAME=$(nslookup "$DOMAIN" | awk '/canonical name = / {print $NF}' | sed 's/\.$//')
    elif command -v host &> /dev/null; then
        CNAME=$(host "$DOMAIN" | awk '/alias for / {print $NF}' | sed 's/\.$//')
    elif command -v getent &> /dev/null; then
        CNAME=$(getent hosts "$DOMAIN" | awk '{print $1}')
    else
        echo "Error: No suitable DNS resolution command found (nslookup, host, getent). Please install one."
        exit 1
    fi

    if [[ -z "$CNAME" ]]; then
        echo "Error: CNAME for $DOMAIN is not resolving correctly."
        exit 1
    fi

    if [[ "$CNAME" != "$LB_DNS" ]]; then
        echo "Error: CNAME for $DOMAIN does not match Load Balancer DNS."
        echo "Expected: $LB_DNS, Found: $CNAME"
        exit 1
    fi

    echo "CNAME for $DOMAIN is correctly resolving to $CNAME"
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

    # Restart nginx-proxy pods
    kubectl delete pods -l app=nginx-proxy -n "$NAMESPACE"

    # Restart dex pods
    kubectl delete pods -l app.kubernetes.io/name=dex -n "$NAMESPACE"

    echo "Pods are restarting..."
}

# -----------------------------
# Main Execution Flow
# -----------------------------

# Ensure required tools are installed
for cmd in aws kubectl helm; do
    check_command "$cmd"
done

# Step 1: Retrieve Ingress details
get_ingress_details

# Step 2: Check CNAME resolution
check_cname_resolution

# Step 3: Run Helm upgrade
update_helm_release

# Step 4: Restart relevant Kubernetes pods
restart_pods

echo ""
echo "======================================="
echo "Application Update Completed Successfully!"
echo "======================================="
echo "Your service should now be fully operational at https://$DOMAIN"
echo "======================================="
