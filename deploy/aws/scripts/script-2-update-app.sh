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

# Function to retrieve DOMAIN, CERTIFICATE_ARN, LB_DNS, and LISTEN_PORTS from Ingress
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

    # Get Listen Ports from Ingress annotations
    LISTEN_PORTS=$(kubectl get ingress "$INGRESS_NAME" -n "$NAMESPACE" -o jsonpath='{.metadata.annotations.alb\.ingress\.kubernetes\.io/listen-ports}')

    if [[ -z "$LISTEN_PORTS" ]]; then
        echo "Error: Unable to retrieve LISTEN_PORTS from Ingress annotations."
        exit 1
    fi
    echo "Listen Ports: $LISTEN_PORTS"
}

# Function to determine the protocol (http or https) based on listen-ports
determine_protocol() {
    echo "Determining protocol based on Ingress listen ports..."

    # Check if HTTPS is present in the listen ports
    if echo "$LISTEN_PORTS" | grep -q '"HTTPS"'; then
        PROTOCOL="https"
    else
        PROTOCOL="http"
    fi

    echo "Determined Protocol: $PROTOCOL"
}

# Function to check DNS resolution without dig
check_dns_resolution() {
    echo "Checking if $DOMAIN is resolving correctly..."

    # Use nslookup if available, otherwise use host, otherwise use getent
    if command -v nslookup &> /dev/null; then
        RESOLVED=$(nslookup "$DOMAIN" | awk '/name = / {print $NF}' | sed 's/\.$//')
    elif command -v host &> /dev/null; then
        RESOLVED=$(host "$DOMAIN" | awk '/alias for / {print $NF}' | sed 's/\.$//')
    elif command -v getent &> /dev/null; then
        RESOLVED=$(getent hosts "$DOMAIN" | awk '{print $1}')
    else
        echo "Error: No suitable DNS resolution command found (nslookup, host, getent). Please install one."
        return 1
    fi

    if [[ -z "$RESOLVED" ]]; then
        echo "Error: $DOMAIN is not resolving correctly."
        return 1
    fi

    echo "$DOMAIN is resolving to: $RESOLVED"
    echo "Ensure that $DOMAIN is correctly pointing to your Load Balancer or proxy service (e.g., Cloudflare)."

    return 0
}

# Function to check DNS resolution with retries and option to skip
check_dns_resolution_with_retries() {
    local max_attempts=12
    local interval=30
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        echo "Attempt $attempt/$max_attempts: Checking DNS resolution for $DOMAIN..."
        if check_dns_resolution; then
            echo "DNS resolution successful."
            return 0
        else
            echo "DNS resolution failed."
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            echo "Waiting for $interval seconds before retrying..."
            sleep "$interval"
        fi

        ((attempt++))
    done

    echo "DNS resolution for $DOMAIN failed after $max_attempts attempts."

    # Prompt user to skip or exit
    while true; do
        read -p "Do you want to skip DNS resolution check and proceed? (y/N): " choice
        case "$choice" in
            y|Y )
                echo "Skipping DNS resolution check."
                return 0
                ;;
            n|N|"" )
                echo "Exiting script due to DNS resolution failure."
                exit 1
                ;;
            * )
                echo "Invalid input. Please enter 'y' or 'n'."
                ;;
        esac
    done
}

# Function to update Helm release
update_helm_release() {
    echo "Updating Helm release: $HELM_RELEASE with domain: $DOMAIN and protocol: $PROTOCOL"

    helm upgrade "$HELM_RELEASE" "$HELM_CHART" -n "$NAMESPACE" -f <(cat <<EOF
global:
  domain: ${DOMAIN}
dex:
  config:
    issuer: ${PROTOCOL}://${DOMAIN}/dex
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

# Initialize skip DNS check flag
SKIP_DNS_CHECK=0

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-dns-check)
            SKIP_DNS_CHECK=1
            echo "Skipping DNS resolution check as per the '--skip-dns-check' flag."
            shift
            ;;
        *)
            echo "Unknown argument: $1"
            echo "Usage: $0 [--skip-dns-check]"
            exit 1
            ;;
    esac
done

# Ensure required tools are installed
for cmd in aws kubectl helm; do
    check_command "$cmd"
done

# Step 1: Retrieve Ingress details
get_ingress_details

# Step 2: Determine protocol based on Ingress listen ports
determine_protocol

# Step 3: Check DNS resolution if not skipped
if [[ $SKIP_DNS_CHECK -eq 0 ]]; then
    check_dns_resolution_with_retries
else
    echo "DNS resolution check skipped."
fi

# Step 4: Run Helm upgrade
update_helm_release

# Step 5: Restart relevant Kubernetes pods
restart_pods

echo ""
echo "======================================="
echo "Application Update Completed Successfully!"
echo "======================================="
echo "Your service should now be fully operational at https://${DOMAIN}"
echo "======================================="
