#!/bin/bash

set -e

# Default values for EMAIL and DOMAIN
DEFAULT_EMAIL="your-email@example.com"
DEFAULT_DOMAIN="opengovernance.example.io"

# Function to display informational messages
function echo_info() {
  printf "\n\033[1;34m%s\033[0m\n\n" "$1"
}

# Function to display error messages
function echo_error() {
  printf "\n\033[0;31m%s\033[0m\n\n" "$1"
}

# Function to check prerequisites (Step 1)
function check_prerequisites() {
  echo_info "Step 1 of 10: Checking Prerequisites"

  # Check if kubectl is connected to a cluster
  if ! kubectl cluster-info > /dev/null 2>&1; then
    echo_error "Error: kubectl is not connected to a cluster."
    echo "Please configure kubectl to connect to a Kubernetes cluster and try again."
    exit 1
  fi

  # Check if Helm is installed
  if ! command -v helm &> /dev/null; then
    echo_error "Error: Helm is not installed."
    echo "Please install Helm and try again."
    exit 1
  fi
}

# Function to capture DOMAIN and EMAIL variables (Step 2)
function configure_email_and_domain() {
  echo_info "Step 2 of 10: Configuring DOMAIN and EMAIL"

  # Capture DOMAIN if not set or default
  if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "$DEFAULT_DOMAIN" ]; then
    if [ -z "$DOMAIN" ]; then
      echo_info "DOMAIN is not set."
    else
      echo_info "DOMAIN is set to the default value."
    fi
    while true; do
      read -p "Please enter your domain for OpenGovernance: " DOMAIN < /dev/tty
      if [ -z "$DOMAIN" ]; then
        echo_info "No domain entered. Proceeding without a custom domain."
        DOMAIN=""
        break
      fi
      echo "You entered: $DOMAIN"
      read -p "Is this correct? (Y/n): " yn < /dev/tty
      case $yn in
          "" | [Yy]* ) break;;
          [Nn]* ) echo "Let's try again.";;
          * ) echo "Please answer y or n.";;
      esac
    done
  fi

  # Only proceed to capture EMAIL if DOMAIN is set and not empty
  if [ -n "$DOMAIN" ]; then
    # Capture EMAIL if not set
    if [ -z "$EMAIL" ] || [ "$EMAIL" = "$DEFAULT_EMAIL" ]; then
      if [ -z "$EMAIL" ]; then
        echo_info "EMAIL is not set."
      else
        echo_info "EMAIL is set to the default value."
      fi
      while true; do
        read -p "Please enter your email: " EMAIL < /dev/tty
        if [ -z "$EMAIL" ]; then
          echo_error "Email cannot be empty. Please enter a valid email."
          continue
        fi
        echo "You entered: $EMAIL"
        read -p "Is this correct? (Y/n): " yn < /dev/tty
        case $yn in
            "" | [Yy]* ) break;;
            [Nn]* ) echo "Let's try again.";;
            * ) echo "Please answer y or n.";;
        esac
      done
    fi
  else
    EMAIL=""
  fi
}

# Function to check if OpenGovernance is installed and healthy
function check_opengovernance_status() {
  echo_info "Checking if OpenGovernance is installed and healthy."

  APP_INSTALLED=false
  APP_HEALTHY=false

  # Check if app is installed
  if helm ls -n opengovernance | grep opengovernance > /dev/null 2>&1; then
    APP_INSTALLED=true
    echo_info "OpenGovernance is installed. Checking health status."

    # Check if all pods are healthy
    UNHEALTHY_PODS=$(kubectl get pods -n opengovernance --no-headers | awk '{print $1,$3}' | grep -E "CrashLoopBackOff|Error|Failed|Pending|Terminating" || true)
    if [ -z "$UNHEALTHY_PODS" ]; then
      APP_HEALTHY=true
      echo_info "All OpenGovernance pods are healthy."
    else
      echo_error "Detected unhealthy pods:"
      echo "$UNHEALTHY_PODS"
    fi
  else
    echo_info "OpenGovernance is not installed."
  fi
}

# Function to install OpenGovernance with custom domain (Step 3)
function install_opengovernance_with_custom_domain() {
  echo_info "Step 3 of 10: Installing OpenGovernance with custom domain"

  # Add the OpenGovernance Helm repository and update
  helm repo add opengovernance https://opengovern.github.io/charts 2> /dev/null || true
  helm repo update

  # Install OpenGovernance
  echo_info "Note: The Helm installation can take 5-7 minutes to complete. Please be patient."
  helm install -n opengovernance opengovernance \
    opengovernance/opengovernance --create-namespace --timeout=10m \
    -f - <<EOF
global:
  domain: ${DOMAIN}
dex:
  config:
    issuer: https://${DOMAIN}/dex
EOF
  echo_info "OpenGovernance application installation completed."
}

# Function to install OpenGovernance without custom domain (Step 3 alternative)
function install_opengovernance() {
  echo_info "Step 3 of 10: Installing OpenGovernance without custom domain"

  # Add the OpenGovernance Helm repository and update
  helm repo add opengovernance https://opengovern.github.io/charts 2> /dev/null || true
  helm repo update

  # Install OpenGovernance
  echo_info "Note: The Helm installation can take 5-7 minutes to complete. Please be patient."
  helm install -n opengovernance opengovernance \
    opengovernance/opengovernance --create-namespace --timeout=10m
  echo_info "OpenGovernance application installation completed."
}

# [Other functions remain unchanged]

# -----------------------------
# Main Execution Flow
# -----------------------------

check_prerequisites
configure_email_and_domain
check_opengovernance_status

# Decision-making logic

if [ -z "$DOMAIN" ]; then
  # DOMAIN is not set
  echo_info "DOMAIN is not set."
  echo_info "The installation will proceed without a custom domain and HTTPS."
  echo_info "Custom domain and HTTPS can also be configured post-installation."
  echo_info "The script will continue in 10 seconds. Press Ctrl+C to cancel."
  sleep 10
  if [ "$APP_INSTALLED" = false ]; then
    install_opengovernance
  else
    echo_info "OpenGovernance is already installed and healthy. Skipping installation."
  fi
  check_pods_and_jobs
  provide_port_forward_instructions
else
  # DOMAIN is set
  echo_info "DOMAIN is set to: $DOMAIN"
  echo_info "The installation will proceed with this domain in 10 seconds. Press Ctrl+C to cancel."
  sleep 10
  if [ "$APP_INSTALLED" = false ]; then
    install_opengovernance_with_custom_domain
    check_pods_and_jobs
  elif [ "$APP_INSTALLED" = true ] && [ "$APP_HEALTHY" = false ]; then
    echo_info "Reinstalling OpenGovernance due to unhealthy pods."
    # Uninstall and reinstall
    helm uninstall opengovernance -n opengovernance
    kubectl delete namespace opengovernance
    # Wait for namespace deletion
    echo_info "Waiting for namespace 'opengovernance' to be deleted."
    while kubectl get namespace opengovernance > /dev/null 2>&1; do
      sleep 5
    done
    install_opengovernance_with_custom_domain
    check_pods_and_jobs
  else
    echo_info "OpenGovernance is already installed and healthy. Skipping installation."
  fi
  # Proceed with the rest of the steps regardless
  setup_cert_manager_and_issuer
  setup_ingress_controller
  deploy_ingress_resources
  restart_pods
  display_completion_message
fi
