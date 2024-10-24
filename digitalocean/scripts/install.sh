#!/bin/bash

set -e

# Function to display informational messages
function echo_info() {
  printf "\n\033[1;34m%s\033[0m\n\n" "$1"
}

# Function to display error messages
function echo_error() {
  printf "\n\033[0;31m%s\033[0m\n\n" "$1"
}

# Initialize variables
DOMAIN=""
EMAIL=""
ENABLE_HTTPS=false

# Parse command-line arguments
for arg in "$@"
do
    case $arg in
        --hostname=*)
        DOMAIN="${arg#*=}"
        shift
        ;;
        --email-for-http-cert=*)
        EMAIL="${arg#*=}"
        shift
        ;;
        *)
        # Unknown option
        ;;
    esac
done

# Function to capture DOMAIN and EMAIL variables (Step 2)
function configure_email_and_domain() {
  echo_info "Step 2 of 10: Configuring DOMAIN and EMAIL"

  # If DOMAIN is not set, prompt the user
  if [ -z "$DOMAIN" ]; then
    while true; do
      read -p "Please enter your domain for OpenGovernance (or press Enter to skip): " DOMAIN < /dev/tty
      if [ -z "$DOMAIN" ]; then
        echo_info "No domain entered."
        break
      fi
      echo "You entered: $DOMAIN"
      read -p "Is this correct? (Y/n): " yn < /dev/tty
      case $yn in
          "" | [Yy]* ) break;;
          [Nn]* ) echo "Let's try again."
                  DOMAIN=""
                  ;;
          * ) echo "Please answer y or n.";;
      esac
    done
  fi

  # Only proceed to capture EMAIL if DOMAIN is set and not empty
  if [ -n "$DOMAIN" ]; then
    if [ -z "$EMAIL" ]; then
      while true; do
        read -p "Please enter your email for HTTPS certificate (or press Enter to skip): " EMAIL < /dev/tty
        if [ -z "$EMAIL" ]; then
          echo_info "No email entered."
          break
        fi
        echo "You entered: $EMAIL"
        read -p "Is this correct? (Y/n): " yn < /dev/tty
        case $yn in
            "" | [Yy]* ) break;;
            [Nn]* ) echo "Let's try again."
                    EMAIL=""
                    ;;
            * ) echo "Please answer y or n.";;
        esac
      done
    fi
  else
    EMAIL=""
  fi
}

# [Include all other functions from your script here, unchanged]

# -----------------------------
# Main Execution Flow
# -----------------------------

check_prerequisites
configure_email_and_domain
check_opengovernance_status

# Adjusted the installation logic based on the presence of DOMAIN and EMAIL
function run_installation_logic() {
  if [ -z "$DOMAIN" ]; then
    # Install without custom domain
    echo_info "Installing OpenGovernance without custom domain."
    echo_info "The installation will start in 10 seconds. Press Ctrl+C to cancel."
    sleep 10
    install_opengovernance
    check_pods_and_jobs

    # Attempt to set up Ingress Controller and related resources
    set +e  # Temporarily disable exit on error
    setup_ingress_controller
    DEPLOY_SUCCESS=true

    deploy_ingress_resources || DEPLOY_SUCCESS=false
    perform_helm_upgrade_no_custom_domain || DEPLOY_SUCCESS=false
    restart_pods || DEPLOY_SUCCESS=false
    set -e  # Re-enable exit on error

    if [ "$DEPLOY_SUCCESS" = true ]; then
      display_completion_message
    else
      provide_port_forward_instructions
    fi
  elif [ -n "$DOMAIN" ] && [ -n "$EMAIL" ]; then
    # Install with custom domain and HTTPS
    ENABLE_HTTPS=true
    echo_info "Installing OpenGovernance with custom domain: $DOMAIN and HTTPS"
    echo_info "The installation will start in 10 seconds. Press Ctrl+C to cancel."
    sleep 10
    install_opengovernance_with_custom_domain_with_https
    check_pods_and_jobs
    setup_ingress_controller
    setup_cert_manager_and_issuer
    deploy_ingress_resources
    restart_pods
    display_completion_message
  elif [ -n "$DOMAIN" ] && [ -z "$EMAIL" ]; then
    # Install with custom domain and without HTTPS
    ENABLE_HTTPS=false
    echo_info "No email provided."
    echo_info "Proceeding with installation with custom domain without HTTPS in 10 seconds. Press Ctrl+C to cancel."
    sleep 10
    install_opengovernance_with_custom_domain_no_https
    check_pods_and_jobs
    setup_ingress_controller
    deploy_ingress_resources
    restart_pods
    display_completion_message
  else
    # Should not reach here
    echo_error "Unexpected condition in run_installation_logic."
    exit 1
  fi
}

# Start the installation logic
run_installation_logic
