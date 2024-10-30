#!/usr/bin/env bash

# -----------------------------
# Configuration Variables
# -----------------------------

# Default Kubernetes namespace for OpenGovernance
DEFAULT_KUBE_NAMESPACE="opengovernance"

# -----------------------------
# Logging Configuration
# -----------------------------

LOGFILE="$HOME/opengovernance_install.log"

# Ensure the log directory exists
mkdir -p "$(dirname "$LOGFILE")"

# Redirect all output to the log file and console
exec > >(tee -a "$LOGFILE") 2>&1

# Open file descriptor 3 for appending to the log file only
exec 3>> "$LOGFILE"

# -----------------------------
# Function Definitions
# -----------------------------

# Function to display messages directly to the user
function echo_prompt() {
  echo "$@" > /dev/tty
}

# Function to display informational messages to the log with timestamp
function echo_info() {
  local message="$1"
  # Log detailed message with timestamp
  echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $message" >&3
}

# Function to display error messages to console and log with timestamp
function echo_error() {
  local message="$1"
  # Always print concise error message to console
  echo_prompt "Error: $message"
  # Log detailed error message with timestamp
  echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $message" >&3
}

# Function to display primary messages to both console and log with timestamp
function echo_primary() {
  local message="$1"
  # Print to console
  echo_prompt "$message"
  # Log detailed message with timestamp
  echo_info "$message"
}

# Function to display detail messages to both console and log with timestamp, indented with 4 spaces
function echo_detail() {
  local message="$1"
  local indent="    "  # 4 spaces
  # Print to console with indentation
  echo_prompt "${indent}${message}"
  # Log detailed message with timestamp
  echo_info "${indent}${message}"
}

# Function to display usage information
function usage() {
  echo_prompt "Usage: $0 [--silent-install] [-d DOMAIN] [-e EMAIL] [-t INSTALL_TYPE] [--kube-namespace NAMESPACE] [-h|--help]"
  echo_prompt ""
  echo_prompt "Options:"
  echo_prompt "  --silent-install        Run the script in non-interactive mode. DOMAIN and EMAIL must be provided as arguments."
  echo_prompt "  -d, --domain            Specify the domain for OpenGovernance."
  echo_prompt "  -e, --email             Specify the email for Let's Encrypt certificate generation."
  echo_prompt "  -t, --type              Specify the installation type:"
  echo_prompt "                           1) Install with HTTPS and Hostname (DNS records required after installation)"
  echo_prompt "                           2) Install without HTTPS (DNS records required after installation)"
  echo_prompt "                           3) Minimal Install (Access via public IP)"
  echo_prompt "                           Default: 1"
  echo_prompt "  --kube-namespace        Specify the Kubernetes namespace. Default: $DEFAULT_KUBE_NAMESPACE"
  echo_prompt "  -h, --help              Display this help message."
  exit 1
}

# Function to redirect Helm commands to the log only
function helm_quiet() {
  helm "$@" >&3 2>&1
}

# Function to validate the domain
function validate_domain() {
  local domain="$DOMAIN"
  # Simple regex for domain validation
  if [[ "$domain" =~ ^(([a-zA-Z0-9](-*[a-zA-Z0-9])*)\.)+[a-zA-Z]{2,}$ ]]; then
      echo_info "Domain '$domain' is valid."
  else
      echo_error "Invalid domain: '$domain'. Please enter a valid domain."
      exit 1
  fi
}

# Function to validate the email
function validate_email() {
  local email="$EMAIL"
  # Simple regex for email validation
  if [[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
      echo_info "Email '$email' is valid."
  else
      echo_error "Invalid email: '$email'. Please enter a valid email address."
      exit 1
  fi
}

# Function to parse command-line arguments
function parse_args() {
  SILENT_INSTALL=false
  INSTALL_TYPE_SPECIFIED=false  # Flag to check if install type was specified
  KUBE_NAMESPACE="$DEFAULT_KUBE_NAMESPACE"  # Initialize with default

  while [[ "$#" -gt 0 ]]; do
    case $1 in
      --silent-install)
        SILENT_INSTALL=true
        shift
        ;;
      -d|--domain)
        DOMAIN="$2"
        shift 2
        ;;
      -e|--email)
        EMAIL="$2"
        shift 2
        ;;
      -t|--type)
        INSTALL_TYPE="$2"
        INSTALL_TYPE_SPECIFIED=true
        shift 2
        ;;
      --kube-namespace)
        KUBE_NAMESPACE="$2"
        shift 2
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

  if [ "$SILENT_INSTALL" = true ]; then
    if [ "$INSTALL_TYPE_SPECIFIED" = false ]; then
      if [ -n "$DOMAIN" ] && [ -n "$EMAIL" ]; then
        INSTALL_TYPE=1
        ENABLE_HTTPS=true
        echo_info "Silent install: INSTALL_TYPE not specified. DOMAIN and EMAIL provided. Defaulting to Install with HTTPS and Hostname."
      else
        INSTALL_TYPE=3
        ENABLE_HTTPS=false
        echo_info "Silent install: INSTALL_TYPE not specified and DOMAIN/EMAIL not provided. Defaulting to Minimal Install (Access via public IP)."
      fi
    else
      # INSTALL_TYPE was specified
      # Set ENABLE_HTTPS based on INSTALL_TYPE
      case $INSTALL_TYPE in
        1)
          ENABLE_HTTPS=true
          ;;
        2|3)
          ENABLE_HTTPS=false
          ;;
        *)
          echo_error "Invalid installation type: $INSTALL_TYPE"
          usage
          ;;
      esac
    fi
  else
    # Interactive mode

    # If INSTALL_TYPE is specified, set ENABLE_HTTPS accordingly
    if [ "$INSTALL_TYPE_SPECIFIED" = true ]; then
      case $INSTALL_TYPE in
        1)
          ENABLE_HTTPS=true
          ;;
        2|3)
          ENABLE_HTTPS=false
          ;;
        *)
          echo_error "Invalid installation type: $INSTALL_TYPE"
          usage
          ;;
      esac
    fi

    # If INSTALL_TYPE is not specified, default to 1
    INSTALL_TYPE=${INSTALL_TYPE:-1}

    # Validate INSTALL_TYPE
    if ! [[ "$INSTALL_TYPE" =~ ^[1-3]$ ]]; then
      echo_error "Invalid installation type: $INSTALL_TYPE"
      usage
    fi

    # Validate DOMAIN and EMAIL based on INSTALL_TYPE
    case $INSTALL_TYPE in
      1)
        # Install with HTTPS and Hostname
        ENABLE_HTTPS=true
        ;;
      2|3)
        # Install without HTTPS or Minimal Install
        ENABLE_HTTPS=false
        ;;
      *)
        echo_error "Unsupported installation type: $INSTALL_TYPE"
        usage
        ;;
    esac
  fi
}

# Function to choose installation type in interactive mode with "?" capability
function choose_install_type() {
  echo_prompt ""
  echo_prompt "Select Installation Type:"
  echo_prompt "1) Install with HTTPS and Hostname (DNS records required after installation)"
  echo_prompt "2) Install without HTTPS (DNS records required after installation)"
  echo_prompt "3) Minimal Install (Access via public IP)"
  echo_prompt "4) Exit"

  while true; do
    echo_prompt -n "Enter the number corresponding to your choice [Default: 1] (Press '?' to view descriptions): "
    read choice < /dev/tty

    # Handle "?" input to show descriptions
    if [[ "$choice" == "?" ]]; then
      echo_prompt ""
      echo_prompt "Installation Type Descriptions:"
      echo_prompt "1) Install with HTTPS and Hostname: Sets up OpenGovernance with HTTPS enabled and associates it with a specified hostname. Requires DNS records to point to the cluster."
      echo_prompt "2) Install without HTTPS: Deploys OpenGovernance without SSL/TLS encryption. DNS records are still required."
      echo_prompt "3) Minimal Install: Provides access to OpenGovernance via the cluster's public IP without setting up a hostname or HTTPS."
      echo_prompt "4) Exit: Terminates the installation script."
      echo_prompt ""
      continue  # Re-prompt after displaying descriptions
    fi

    # If no choice is made, default to 1
    choice=${choice:-1}

    # Ensure the choice is within 1-4
    if ! [[ "$choice" =~ ^[1-4]$ ]]; then
      echo_prompt "Invalid option. Please enter a number between 1 and 4, or press '?' for descriptions."
      continue
    fi

    # Handle exit option
    if [ "$choice" -eq 4 ]; then
      echo_info "Exiting the script."
      exit 0
    fi

    echo_prompt ""
    case $choice in
      1)
        INSTALL_TYPE=1
        ENABLE_HTTPS=true
        ;;
      2)
        INSTALL_TYPE=2
        ENABLE_HTTPS=false
        ;;
      3)
        INSTALL_TYPE=3
        ENABLE_HTTPS=false
        ;;
      *)
        INSTALL_TYPE=1
        ENABLE_HTTPS=true
        ;;
    esac

    echo_prompt "You selected: $choice) $(get_inline_install_type_description $choice)"
    break
  done

  # Inform user that installation will start shortly
  echo_primary "Installation will start in 5 seconds..."
  sleep 5
}

# Function to get inline installation type description
function get_inline_install_type_description() {
  local type="$1"
  case $type in
    1)
      echo "Install with HTTPS and Hostname (DNS records required after installation)"
      ;;
    2)
      echo "Install without HTTPS (DNS records required after installation)"
      ;;
    3)
      echo "Minimal Install (Access via public IP)"
      ;;
    *)
      echo "Unknown"
      ;;
  esac
}

# Function to check if OpenGovernance is installed and healthy
function check_opengovernance_installation() {
  # Check if OpenGovernance is installed
  if helm ls -n "$KUBE_NAMESPACE" | grep -qw opengovernance; then
    echo_info "OpenGovernance is installed."

    # Now check if it's healthy
    local unhealthy_pods
    unhealthy_pods=$(kubectl get pods -n "$KUBE_NAMESPACE" --no-headers | awk '{print $3}' | grep -v -E 'Running|Completed' || true)

    if [ -z "$unhealthy_pods" ]; then
      echo_primary "OpenGovernance is already installed and healthy."

      # Prompt the user to decide whether to reconfigure
      if [ "$SILENT_INSTALL" = true ]; then
        # In silent mode, proceed to reconfigure
        echo_info "Proceeding to reconfigure OpenGovernance as per provided parameters."
        return 1  # Return 1 to indicate that installation should proceed
      else
        echo_prompt -n "Do you want to reconfigure OpenGovernance with the new parameters? (yes/no): "
        read RECONFIGURE < /dev/tty
        if [[ "$RECONFIGURE" =~ ^([yY][eE][sS]|[yY])$ ]]; then
          return 1  # Return 1 to indicate that installation should proceed
        else
          echo_primary "Exiting the script without making changes."
          exit 0
        fi
      fi
    else
      echo_info "OpenGovernance pods are not all healthy. Proceeding to reconfigure."
      return 1  # Return 1 to indicate that installation should proceed
    fi
  else
    echo_info "OpenGovernance is not installed."
    return 1  # Return 1 to indicate that installation should proceed
  fi
}

# (Include other necessary functions here)

# Function to run installation logic
function run_installation_logic() {
  # Check if OpenGovernance is installed
  if check_opengovernance_installation; then
    # OpenGovernance is not installed, proceed with installation
    echo_info "OpenGovernance is not installed. Proceeding with installation."
  else
    # OpenGovernance is installed, proceed with reconfiguration
    echo_info "Proceeding to reconfigure OpenGovernance."
  fi

  # If not in silent mode and INSTALL_TYPE was not specified, prompt for installation type
  if [ "$SILENT_INSTALL" = false ] && [ "$INSTALL_TYPE_SPECIFIED" = false ]; then
    echo_detail "Starting interactive installation type selection..."
    choose_install_type
  fi

  # Configure email and domain based on installation type
  configure_email_and_domain

  # If installation type requires Ingress external IP (Minimal Install)
  if [ "$INSTALL_TYPE" -eq 3 ]; then
    # Set up Ingress Controller to get the external IP
    setup_ingress_controller
  fi

  # Run Helm upgrade with appropriate parameters
  helm_upgrade_opengovernance

  # Wait for pods to be ready
  check_pods_and_jobs

  # Set up Ingress Controller (if not already set up)
  if [ "$INSTALL_TYPE" -ne 3 ]; then
    setup_ingress_controller
  fi

  # Deploy Ingress resources
  deploy_ingress_resources

  # If HTTPS is enabled, set up Cert-Manager and Issuer
  if [ "$ENABLE_HTTPS" = true ]; then
    setup_cert_manager_and_issuer
  fi

  # Restart Pods
  restart_pods

  # Display completion message
  display_completion_message
}

# (Include other necessary functions here)

# -----------------------------
# Main Execution Flow
# -----------------------------

parse_args "$@"
check_prerequisites
run_installation_logic
