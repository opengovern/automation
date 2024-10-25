#!/bin/bash

set -e

# -----------------------------
# Logging Configuration
# -----------------------------
LOGFILE="$HOME/opengovernance_install.log"

# Ensure the log directory exists
mkdir -p "$(dirname "$LOGFILE")"

# Redirect all output to the log file and the console
exec > >(tee -i "$LOGFILE") 2>&1

# -----------------------------
# Function Definitions
# -----------------------------

# Define the indent string for nested outputs
INDENT="    "

# Function to display informational messages
function echo_info() {
  local message="$1"
  local indent="$2"
  if [ -n "$indent" ]; then
    printf "\n%s\033[1;34m%s\033[0m\n\n" "$indent" "$message"
  else
    printf "\n\033[1;34m%s\033[0m\n\n" "$message"
  fi
}

# Function to display error messages
function echo_error() {
  local message="$1"
  local indent="$2"
  if [ -n "$indent" ]; then
    printf "\n%s\033[0;31m%s\033[0m\n\n" "$indent" "$message"
  else
    printf "\n\033[0;31m%s\033[0m\n\n" "$message"
  fi
}

# Function to display usage information
function usage() {
  echo "Usage: $0 [-d DOMAIN] [-e EMAIL] [--dry-run]"
  echo ""
  echo "Options:"
  echo "  -d, --domain    Specify the domain for OpenGovernance."
  echo "  -e, --email     Specify the email for Let's Encrypt certificate generation."
  echo "  --dry-run       Perform a trial run with no changes made."
  echo "  -h, --help      Display this help message."
  exit 1
}

# Function to validate email format
function validate_email() {
  local email_regex="^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"
  if [[ ! "$EMAIL" =~ $email_regex ]]; then
    echo_error "Invalid email format: $EMAIL"
    exit 1
  fi
}

# Function to validate domain format
function validate_domain() {
  local domain_regex="^(([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)\.)+[A-Za-z]{2,}$"
  if [[ ! "$DOMAIN" =~ $domain_regex ]]; then
    echo_error "Invalid domain format: $DOMAIN"
    exit 1
  fi
}

# Function to parse command-line arguments
function parse_args() {
  DRY_RUN=false
  while [[ "$#" -gt 0 ]]; do
    case $1 in
      -d|--domain)
        DOMAIN="$2"
        shift 2
        ;;
      -e|--email)
        EMAIL="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      -h|--help)
        usage
        ;;
      *)
        echo_error "Unknown parameter passed: $1"
        usage
        ;;
    esac
  done

  # Validate DOMAIN and EMAIL if they are set
  if [ -n "$DOMAIN" ]; then
    validate_domain
  fi

  if [ -n "$EMAIL" ]; then
    validate_email
  fi
}

# Function to check prerequisites (Step 1)
function check_prerequisites() {
  echo_info "Step 1 of 10: Checking Prerequisites"

  # Check if kubectl is connected to a cluster
  if ! kubectl cluster-info > /dev/null 2>&1; then
    echo_error "Error: kubectl is not connected to a cluster." "$INDENT"
    echo "Please configure kubectl to connect to a Kubernetes cluster and try again."
    exit 1
  else
    echo_info "kubectl is connected to a cluster." "$INDENT"
  fi

  # Check if Helm is installed
  if ! command -v helm &> /dev/null; then
    echo_error "Error: Helm is not installed." "$INDENT"
    echo "Please install Helm and try again."
    exit 1
  else
    echo_info "Helm is installed." "$INDENT"
  fi

  # Check if there are at least three ready nodes
  READY_NODES=$(kubectl get nodes --no-headers | grep -c ' Ready ')
  if [ "$READY_NODES" -lt 3 ]; then
    echo_error "Error: At least three Kubernetes nodes must be ready. Currently, $READY_NODES node(s) are ready." "$INDENT"
    exit 1
  else
    echo_info "There are $READY_NODES ready nodes." "$INDENT"
  fi
}

# Function to check if OpenGovernance is installed (Step 2)
function check_opengovernance_installation() {
  echo_info "Step 2 of 10: Checking OpenGovernance Installation"

  # Check if the OpenGovernance Helm repository is added
  if ! helm repo list | grep -qw "opengovernance"; then
    echo_error "Error: OpenGovernance Helm repo is not added." "$INDENT"
    APP_INSTALLED=false
    return 1
  fi

  # Check if the OpenGovernance release is installed
  if ! helm ls -n opengovernance | grep -qw opengovernance; then
    echo_error "Error: OpenGovernance is not installed in the cluster." "$INDENT"
    APP_INSTALLED=false
    return 1
  fi

  # Check if the OpenGovernance release is in a deployed state
  local helm_release_status
  helm_release_status=$(helm list -n opengovernance --filter '^opengovernance$' -o json | grep -o '"status":"[^"]*"' | awk -F':' '{print $2}' | tr -d '"')

  if [ "$helm_release_status" == "deployed" ]; then
    echo_info "OpenGovernance is installed and in 'deployed' state." "$INDENT"
    APP_INSTALLED=true
    return 0
  else
    echo_error "Error: OpenGovernance is installed but not in 'deployed' state (current status: $helm_release_status)." "$INDENT"
    APP_INSTALLED=true
    return 1
  fi
}

# Function to check OpenGovernance health status (Step 3)
function check_opengovernance_health() {
  echo_info "Step 3 of 10: Checking OpenGovernance Health Status"

  # Check the health of the OpenGovernance deployment
  local unhealthy_pods
  unhealthy_pods=$(kubectl get pods -n opengovernance --no-headers | grep -v -E 'Running|Completed|Succeeded')

  if [ -z "$unhealthy_pods" ]; then
    echo_info "All OpenGovernance pods are healthy." "$INDENT"
    APP_HEALTHY=true
  else
    echo_error "Some OpenGovernance pods are unhealthy." "$INDENT"
    echo "$unhealthy_pods"
    APP_HEALTHY=false
  fi
}

# Function to check OpenGovernance configuration (Step 4)
function check_opengovernance_config() {
  echo_info "Step 4 of 10: Checking OpenGovernance Configuration"

  # Initialize variables
  custom_host_name=false
  dex_configuration_ok=false
  ssl_configured=false

  # Retrieve the app hostname by looking up the environment variables
  ENV_VARS=$(kubectl get deployment metadata-service -n opengovernance \
    -o jsonpath='{.spec.template.spec.containers[0].env[*]}')

  # Extract the primary domain from the environment variables
  CURRENT_DOMAIN=$(echo "$ENV_VARS" | grep -o '"name":"METADATA_PRIMARY_DOMAIN_URL","value":"[^"]*"' | awk -F'"' '{print $8}')

  # Determine if it's a custom hostname or not
  if [[ $CURRENT_DOMAIN == "og.app.domain" || -z $CURRENT_DOMAIN ]]; then
    custom_host_name=false
  elif [[ $CURRENT_DOMAIN =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]]; then
    custom_host_name=true
  fi

  # Retrieve redirect Uris
  redirect_uris=$(echo "$ENV_VARS" | grep -o '"name":"METADATA_DEX_PUBLIC_CLIENT_REDIRECT_URIS","value":"[^"]*"' | awk -F'"' '{print $8}')

  # Check if the primary domain is present in the redirect Uris
  if echo "$redirect_uris" | grep -q "$CURRENT_DOMAIN"; then
    dex_configuration_ok=true
  fi

  # Enhanced SSL configuration check
  if [[ $custom_host_name == true ]] && \
     echo "$redirect_uris" | grep -q "https://$CURRENT_DOMAIN"; then

    if kubectl get ingress opengovernance-ingress -n opengovernance &> /dev/null; then
      # Use kubectl describe to get Ingress details
      INGRESS_DETAILS=$(kubectl describe ingress opengovernance-ingress -n opengovernance)

      # Check for TLS configuration in the Ingress specifically for the CURRENT_DOMAIN
      if echo "$INGRESS_DETAILS" | grep -q "tls:" && echo "$INGRESS_DETAILS" | grep -q "host: $CURRENT_DOMAIN"; then

        # Check if the Ingress Controller has an assigned external IP
        INGRESS_EXTERNAL_IP=$(kubectl get svc ingress-nginx-controller -n opengovernance -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
        if [ -n "$INGRESS_EXTERNAL_IP" ]; then
          ssl_configured=true
        fi
      fi
    fi
  fi

  # Output results
  echo_info "Configuration Check Results:" "$INDENT"
  echo_info "Custom Hostname: $custom_host_name" "$INDENT$INDENT"
  echo_info "App Configured Hostname: $CURRENT_DOMAIN" "$INDENT$INDENT"
  echo_info "Dex Configuration OK: $dex_configuration_ok" "$INDENT$INDENT"
  echo_info "SSL/TLS Configured in Ingress: $ssl_configured" "$INDENT$INDENT"

  # Export variables for use in other functions
  export custom_host_name
  export ssl_configured
  export CURRENT_DOMAIN
}

# Function to check OpenGovernance readiness (Step 5)
function check_opengovernance_readiness() {
  echo_info "Step 5 of 10: Checking OpenGovernance Readiness"

  # Check the readiness of all pods in the 'opengovernance' namespace
  local not_ready_pods
  not_ready_pods=$(kubectl get pods -n opengovernance --no-headers | awk '{print $2}' | grep -v -E '([0-9]+)/\1')

  if [ -z "$not_ready_pods" ]; then
    echo_info "All OpenGovernance pods are ready." "$INDENT"
    return 0
  else
    echo_error "Some OpenGovernance pods are not ready." "$INDENT"
    kubectl get pods -n opengovernance
    return 1
  fi
}

# Function to check pods and migrator jobs (Simplified)
function check_pods_and_jobs() {
  local attempts=0
  local max_attempts=10
  local sleep_time=30

  while [ $attempts -lt $max_attempts ]; do
    if check_opengovernance_readiness; then
      return 0
    fi
    attempts=$((attempts + 1))
    echo_info "Retrying in $sleep_time seconds... (Attempt $attempts/$max_attempts)" "$INDENT"
    sleep $sleep_time
  done

  echo_error "OpenGovernance did not become ready within expected time." "$INDENT"
  exit 1
}

# Function to configure email and domain (Step 6)
function configure_email_and_domain() {
  echo_info "Step 6 of 10: Configuring DOMAIN and EMAIL"

  # Capture DOMAIN if not set via arguments
  if [ -z "$DOMAIN" ]; then
    while true; do
      echo ""
      echo "Enter your domain for OpenGovernance (required for custom hostname)."
      read -p "Domain (or press Enter to skip): " DOMAIN < /dev/tty
      if [ -z "$DOMAIN" ]; then
        echo_info "No domain entered. Skipping domain configuration." "$INDENT"
        break
      fi
      echo "You entered: $DOMAIN"
      read -p "Is this correct? (Y/n): " yn < /dev/tty
      case $yn in
          "" | [Yy]* )
              validate_domain
              break
              ;;
          [Nn]* )
              echo "Let's try again."
              DOMAIN=""
              ;;
          * )
              echo "Please answer y or n.";;
      esac
    done
  fi

  # Proceed to capture EMAIL if DOMAIN is set and user chooses SSL
  if [ -n "$DOMAIN" ]; then
    # Determine if EMAIL was provided via arguments or not
    if [ -n "$EMAIL" ]; then
      # If EMAIL is provided, assume SSL setup
      ENABLE_HTTPS=true
      echo_info "Email provided. Proceeding with SSL/TLS setup." "$INDENT"
    else
      # Ask the user if they want to set up SSL/TLS
      echo ""
      echo "Do you want to set up SSL/TLS with Let's Encrypt?"
      select yn in "Yes" "No"; do
        case $yn in
            Yes )
                ENABLE_HTTPS=true
                # Capture EMAIL
                while true; do
                  echo "Enter your email for HTTPS certificate generation via Let's Encrypt."
                  read -p "Email: " EMAIL < /dev/tty
                  if [ -z "$EMAIL" ]; then
                    echo_error "Email is required for SSL/TLS setup." "$INDENT"
                  else
                    echo "You entered: $EMAIL"
                    read -p "Is this correct? (Y/n): " yn < /dev/tty
                    case $yn in
                        "" | [Yy]* )
                            validate_email
                            break
                            ;;
                        [Nn]* )
                            echo "Let's try again."
                            EMAIL=""
                            ;;
                        * )
                            echo "Please answer y or n.";;
                    esac
                  fi
                done
                break
                ;;
            No )
                ENABLE_HTTPS=false
                break
                ;;
            * ) echo "Please select 1 or 2.";;
        esac
      done
    fi
  else
    EMAIL=""
    ENABLE_HTTPS=false
  fi
}

# Function to install OpenGovernance (Step 7)
function install_opengovernance() {
  echo_info "Step 7 of 10: Installing OpenGovernance"

  # Add the OpenGovernance Helm repository and update
  if ! helm repo list | grep -qw opengovernance; then
    helm repo add opengovernance https://opengovern.github.io/charts
    echo_info "Added OpenGovernance Helm repository." "$INDENT"
  else
    echo_info "OpenGovernance Helm repository already exists. Skipping add." "$INDENT"
  fi
  helm repo update

  # Install OpenGovernance
  echo_info "Note: The Helm installation can take 5-7 minutes to complete. Please be patient." "$INDENT"

  # Determine the issuer based on SSL configuration
  if [ "$ENABLE_HTTPS" = true ]; then
    ISSUER="https://${DOMAIN}/dex"
  else
    ISSUER="http://${DOMAIN}/dex"
  fi

  if [ "$DRY_RUN" = true ]; then
    helm install -n opengovernance opengovernance \
      opengovernance/opengovernance --create-namespace --timeout=10m \
      --dry-run \
      -f - <<EOF
global:
  domain: ${DOMAIN}
dex:
  config:
    issuer: ${ISSUER}
EOF
  else
    helm install -n opengovernance opengovernance \
      opengovernance/opengovernance --create-namespace --timeout=10m \
      -f - <<EOF
global:
  domain: ${DOMAIN}
dex:
  config:
    issuer: ${ISSUER}
EOF
  fi

  echo_info "OpenGovernance application installation completed." "$INDENT"
}

# Function to check for newer Helm chart and perform upgrade if necessary (modified)
function check_and_perform_upgrade() {
  echo_info "Checking for newer 'opengovernance' Helm chart version"

  # Ensure the Helm repository is updated
  helm repo update

  # Get the latest chart version available for 'opengovernance'
  latest_chart_version=$(helm search repo opengovernance/opengovernance --devel -o json | grep -o '"version":"[^"]*"' | awk -F':' '{print $2}' | tr -d '"')

  # Get the currently deployed chart version of 'opengovernance'
  current_chart_version=$(helm list -n opengovernance --filter '^opengovernance$' -o json | grep -o '"chart":"[^"]*"' | awk -F':' '{print $2}' | awk -F'"' '{print $2}' | awk -F'-' '{print $2}')

  if [ "$latest_chart_version" != "$current_chart_version" ]; then
    echo_info "A newer 'opengovernance' chart version is available: $latest_chart_version (current: $current_chart_version)" "$INDENT"

    echo "The 'opengovernance' application will be upgraded to the latest version in 10 seconds."
    echo "Press Ctrl+C to cancel the upgrade."

    for i in {10..1}; do
      echo -ne "Upgrading in $i seconds...\r"
      sleep 1
    done
    echo

    # Perform the Helm upgrade
    perform_helm_upgrade

    # Continue with the rest of the steps
  else
    echo_info "You are already using the latest 'opengovernance' chart version: $current_chart_version" "$INDENT"
  fi
}

# Function to perform Helm upgrade (Step 10)
function perform_helm_upgrade() {
  echo_info "Performing Helm Upgrade with New Configuration"

  if [ -z "$DOMAIN" ]; then
    echo_error "Error: DOMAIN is not set." "$INDENT"
    exit 1
  fi

  echo_info "Upgrading OpenGovernance Helm release with domain: $DOMAIN" "$INDENT"

  # Add the OpenGovernance Helm repository and update (if not already added)
  if ! helm repo list | grep -qw opengovernance; then
    helm repo add opengovernance https://opengovern.github.io/charts
    echo_info "Added OpenGovernance Helm repository." "$INDENT"
  else
    echo_info "OpenGovernance Helm repository already exists. Skipping add." "$INDENT"
  fi
  helm repo update

  # Determine the issuer based on SSL configuration
  if [ "$ENABLE_HTTPS" = true ]; then
    ISSUER="https://${DOMAIN}/dex"
  else
    ISSUER="http://${DOMAIN}/dex"
  fi

  if [ "$DRY_RUN" = true ]; then
    helm upgrade -n opengovernance opengovernance \
      opengovernance/opengovernance --timeout=10m --dry-run \
      -f - <<EOF
global:
  domain: "${DOMAIN}"
  debugMode: true
dex:
  config:
    issuer: "${ISSUER}"
EOF
  else
    helm upgrade -n opengovernance opengovernance \
      opengovernance/opengovernance --timeout=10m \
      -f - <<EOF
global:
  domain: "${DOMAIN}"
  debugMode: true
dex:
  config:
    issuer: "${ISSUER}"
EOF
  fi

  echo_info "Helm upgrade completed successfully." "$INDENT"
}

# [Rest of the script remains the same, adjusted as per modifications]

# Function to run installation logic
function run_installation_logic() {
  # Check if app is installed
  if ! check_opengovernance_installation; then
    # App is not installed, proceed to install
    echo_info "OpenGovernance is not installed."
    configure_email_and_domain
    install_opengovernance
    check_pods_and_jobs

    # Attempt to set up Ingress Controller and related resources
    set +e  # Temporarily disable exit on error
    setup_ingress_controller
    DEPLOY_SUCCESS=true

    deploy_ingress_resources || DEPLOY_SUCCESS=false
    if [ "$ENABLE_HTTPS" = true ]; then
      setup_cert_manager_and_issuer || DEPLOY_SUCCESS=false
    fi
    perform_helm_upgrade || DEPLOY_SUCCESS=false
    restart_pods || DEPLOY_SUCCESS=false
    set -e  # Re-enable exit on error

    if [ "$DEPLOY_SUCCESS" = true ]; then
      display_completion_message
    else
      provide_port_forward_instructions
    fi
  else
    # App is installed, check health
    check_opengovernance_health

    if [ "$APP_HEALTHY" = false ]; then
      # App has health issues, proceed to upgrade if newer 'opengovernance' chart is available
      configure_email_and_domain
      check_and_perform_upgrade
      check_pods_and_jobs
      setup_ingress_controller

      if [ "$ENABLE_HTTPS" = true ]; then
        setup_cert_manager_and_issuer
      fi

      deploy_ingress_resources
      restart_pods
      display_completion_message
    else
      # App is healthy
      check_opengovernance_config

      if [ -n "$DOMAIN" ] && [ "$CURRENT_DOMAIN" != "$DOMAIN" ]; then
        echo_info "Provided DOMAIN differs from the current configuration."
        echo_info "Proceeding to upgrade OpenGovernance with new DOMAIN settings."

        if [ -n "$EMAIL" ]; then
          ENABLE_HTTPS=true
        else
          ENABLE_HTTPS=false
        fi

        perform_helm_upgrade
        check_pods_and_jobs
        setup_ingress_controller

        if [ "$ENABLE_HTTPS" = true ]; then
          setup_cert_manager_and_issuer
        fi

        deploy_ingress_resources
        restart_pods
        display_completion_message

      elif [ "$custom_host_name" == "true" ] && [ "$ssl_configured" == "true" ]; then
        echo_info "OpenGovernance is fully configured with custom hostname and SSL/TLS."
      else
        # Existing logic for handling other cases
        echo ""
        echo "OpenGovernance is installed but not fully configured."
        echo "Please select an option to proceed:"
        PS3="Enter the number corresponding to your choice: "
        options=("Barebones Install (Requires Port-Forwarding)" "Simple Install" "Standard Install with HTTPS" "Exit")
        select opt in "${options[@]}"; do
          case $REPLY in
            1)
              ENABLE_HTTPS=false
              install_barebones_install
              check_pods_and_jobs
              provide_port_forward_instructions
              break
              ;;
            2)
              ENABLE_HTTPS=false
              configure_email_and_domain
              install_simple_install
              check_pods_and_jobs
              setup_ingress_controller
              deploy_ingress_resources
              perform_helm_upgrade
              restart_pods
              display_completion_message
              break
              ;;
            3)
              ENABLE_HTTPS=true
              configure_email_and_domain
              perform_helm_upgrade
              check_pods_and_jobs
              setup_ingress_controller
              setup_cert_manager_and_issuer
              deploy_ingress_resources
              restart_pods
              display_completion_message
              break
              ;;
            4)
              echo_info "Exiting the script."
              exit 0
              ;;
            *)
              echo "Invalid option. Please enter 1, 2, 3, or 4."
              ;;
          esac
        done
      fi
    fi
  fi
}

# -----------------------------
# Main Execution Flow
# -----------------------------

parse_args "$@"
check_prerequisites
run_installation_logic