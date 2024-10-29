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
        if [ "$SILENT_INSTALL" = true ]; then
          if [ -z "$DOMAIN" ]; then
            echo_error "Installation type 1 requires a DOMAIN in silent mode."
            usage
          else
            validate_domain
          fi

          if [ -z "$EMAIL" ]; then
            echo_error "Installation type 1 requires an EMAIL in silent mode."
            usage
          else
            validate_email
          fi
        fi
        ENABLE_HTTPS=true
        ;;
      2)
        # Install without HTTPS
        if [ "$SILENT_INSTALL" = true ]; then
          if [ -z "$DOMAIN" ]; then
            echo_error "Installation type 2 requires a DOMAIN in silent mode."
            usage
          else
            validate_domain
          fi
        fi
        ENABLE_HTTPS=false
        ;;
      3)
        # Minimal Install
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
      exit 0
    else
      echo_info "OpenGovernance pods are not all healthy. Waiting up to 3 minutes for them to become ready."

      local attempts=0
      local max_attempts=6  # 6 attempts * 30 seconds = 3 minutes
      local sleep_time=30

      while [ $attempts -lt $max_attempts ]; do
        unhealthy_pods=$(kubectl get pods -n "$KUBE_NAMESPACE" --no-headers | awk '{print $3}' | grep -v -E 'Running|Completed' || true)
        if [ -z "$unhealthy_pods" ]; then
          echo_primary "OpenGovernance pods are now healthy."
          return 0
        fi
        attempts=$((attempts + 1))
        echo_detail "Waiting for OpenGovernance pods to become healthy... ($attempts/$max_attempts)"
        sleep $sleep_time
      done

      echo_error "OpenGovernance pods are not healthy after waiting for 3 minutes."
      exit 1
    fi
  else
    echo_info "OpenGovernance is not installed."
    return 1
  fi
}

# Function to check if kubectl is connected to a cluster
function check_kubectl_connection() {
  if kubectl cluster-info > /dev/null 2>&1; then
    echo_info "kubectl is connected to a cluster."
  else
    echo_error "kubectl is not connected to a cluster."
    echo_prompt ""
    echo_prompt "OpenGovernance needs kubectl to be configured and connected to a Kubernetes cluster."
    echo_prompt ""
    echo_prompt "Please ensure you have a Kubernetes cluster available and that kubectl is configured to connect to it."
    echo_prompt ""
    exit 1
  fi
}

# Function to check prerequisites
function check_prerequisites() {
  # Check if kubectl is connected to a cluster
  check_kubectl_connection

  # Check if Helm is installed
  if ! command -v helm &> /dev/null; then
    echo_error "Helm is not installed. Please install Helm and try again."
    exit 1
  fi

  echo_info "Checking Prerequisites...Completed"
}

# Function to configure email and domain
function configure_email_and_domain() {
  # Depending on the installation type, prompt for DOMAIN and EMAIL as needed
  case $INSTALL_TYPE in
    1)
      # Install with HTTPS and Hostname
      if [ "$SILENT_INSTALL" = false ]; then
        if [ -z "$DOMAIN" ]; then
          while true; do
            echo_prompt -n "Enter your domain for OpenGovernance: "
            read DOMAIN < /dev/tty
            if [ -z "$DOMAIN" ]; then
              echo_error "Domain is required for installation type 1."
              continue
            fi
            validate_domain
            break
          done
        fi

        if [ -z "$EMAIL" ]; then
          while true; do
            echo_prompt -n "Enter your email for Let's Encrypt: "
            read EMAIL < /dev/tty
            if [ -z "$EMAIL" ]; then
              echo_error "Email is required for installation type 1."
            else
              validate_email
              break
            fi
          done
        fi
      fi
      ;;
    2)
      # Install without HTTPS
      if [ "$SILENT_INSTALL" = false ] && [ -z "$DOMAIN" ]; then
        while true; do
          echo_prompt -n "Enter your domain for OpenGovernance: "
          read DOMAIN < /dev/tty
          if [ -z "$DOMAIN" ]; then
            echo_error "Domain is required for installation type 2."
            continue
          fi
          validate_domain
          break
        done
      fi
      ;;
    3)
      # Minimal Install
      # No DOMAIN or EMAIL required
      ;;
    *)
      echo_error "Unsupported installation type: $INSTALL_TYPE"
      usage
      ;;
  esac
}

# Function to check OpenGovernance readiness
function check_opengovernance_readiness() {
  # Check the readiness of all pods in the specified namespace
  local not_ready_pods
  not_ready_pods=$(kubectl get pods -n "$KUBE_NAMESPACE" --no-headers | awk '{print $2}' | grep -v '^1/1$' || true)

  if [ -z "$not_ready_pods" ]; then
    APP_HEALTHY=true
  else
    echo_error "Some OpenGovernance pods are not ready."
    kubectl get pods -n "$KUBE_NAMESPACE"
    APP_HEALTHY=false
  fi
}

# Function to check pods and migrator jobs
function check_pods_and_jobs() {
  echo_detail "Waiting for application to be ready..."

  local attempts=0
  local max_attempts=12  # 12 attempts * 30 seconds = 6 minutes
  local sleep_time=30

  while [ $attempts -lt $max_attempts ]; do
    check_opengovernance_readiness
    if [ "$APP_HEALTHY" = true ]; then
      return 0
    fi
    attempts=$((attempts + 1))
    echo_detail "Waiting for pods to become ready... ($attempts/$max_attempts)"
    sleep $sleep_time
  done

  echo_error "OpenGovernance did not become ready within expected time."
  exit 1
}

# Function to install OpenGovernance with HTTPS
function install_opengovernance_with_https() {
  echo_primary "Proceeding with OpenGovernance installation with HTTPS. (Expected time: 7-10 minutes)"

  # Add Helm repository and update
  echo_detail "Adding OpenGovernance Helm repository."
  helm_quiet repo add opengovernance https://opengovern.github.io/charts || true
  helm_quiet repo update

  # Perform Helm installation with custom configuration
  echo_detail "Performing installation with custom configuration."

  helm_quiet install opengovernance opengovernance/opengovernance -n "$KUBE_NAMESPACE" --create-namespace --timeout=10m --wait \
    -f - <<EOF
global:
  domain: ${DOMAIN}
dex:
  config:
    issuer: https://${DOMAIN}/dex
EOF

  echo_detail "OpenGovernance installation with HTTPS completed."
  echo_detail "Application Installed successfully."
}

# Function to install OpenGovernance without HTTPS
function install_opengovernance_with_hostname_only() {
  echo_primary "Proceeding with OpenGovernance installation without HTTPS. (Expected time: 7-10 minutes)"

  # Add Helm repository and update
  echo_detail "Adding OpenGovernance Helm repository."
  helm_quiet repo add opengovernance https://opengovern.github.io/charts || true
  helm_quiet repo update

  # Perform Helm installation with custom configuration
  echo_detail "Performing installation with custom configuration."

  helm_quiet install opengovernance opengovernance/opengovernance -n "$KUBE_NAMESPACE" --create-namespace --timeout=10m --wait \
    -f - <<EOF
global:
  domain: ${DOMAIN}
dex:
  config:
    issuer: http://${DOMAIN}/dex
EOF

  echo_detail "OpenGovernance installation without HTTPS completed."
  echo_detail "Application Installed successfully."
}

# Function to install OpenGovernance with public IP (Minimal Install)
function install_opengovernance_with_public_ip() {
  echo_primary "Proceeding with Minimal Install of OpenGovernance. (Expected time: 7-10 minutes)"

  # a. Install Ingress Controller and wait for external IP
  setup_ingress_controller

  # b. Perform Helm installation with external IP as domain and issuer
  echo_detail "Performing installation with external IP as domain and issuer."

  helm_quiet repo add opengovernance https://opengovern.github.io/charts || true
  helm_quiet repo update

  helm_quiet install opengovernance opengovernance/opengovernance -n "$KUBE_NAMESPACE" --create-namespace --timeout=10m --wait \
    -f - <<EOF
global:
  domain: ${INGRESS_EXTERNAL_IP}
dex:
  config:
    issuer: http://${INGRESS_EXTERNAL_IP}/dex
EOF

  echo_detail "OpenGovernance installation with public IP completed."
  echo_detail "Application Installed successfully."

  # c. Check if the application is running
  check_pods_and_jobs

  # d. Deploy Ingress resources without host and TLS
  deploy_ingress_resources

  # e. Re-check if the application is running
  check_pods_and_jobs

  # f. Restart Dex and NGINX services by restarting their pods
  restart_pods

  echo_detail "Minimal Install of OpenGovernance completed."
}

# Function to set up Ingress Controller
function setup_ingress_controller() {
  echo_primary "Setting up Ingress Controller. (Expected time: 2-5 minutes)"

  # Check if the namespace exists, if not, create it
  if ! kubectl get namespace "$KUBE_NAMESPACE" > /dev/null 2>&1; then
    kubectl create namespace "$KUBE_NAMESPACE"
    echo_detail "Created namespace $KUBE_NAMESPACE."
  fi

  # Handle existing ClusterRole ingress-nginx
  if kubectl get clusterrole ingress-nginx > /dev/null 2>&1; then
    # Check the current release namespace annotation
    CURRENT_RELEASE_NAMESPACE=$(kubectl get clusterrole ingress-nginx -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-namespace}' 2>/dev/null || true)
    if [ "$CURRENT_RELEASE_NAMESPACE" != "$KUBE_NAMESPACE" ]; then
      echo_detail "Deleting conflicting ClusterRole 'ingress-nginx'."
      kubectl delete clusterrole ingress-nginx
      kubectl delete clusterrolebinding ingress-nginx
    fi
  fi

  # Check if ingress-nginx is already installed in the specified namespace
  if helm_quiet ls -n "$KUBE_NAMESPACE" | grep -qw ingress-nginx; then
    echo_detail "Ingress Controller already installed. Skipping installation."
  else
    echo_detail "Installing ingress-nginx via Helm."
    helm_quiet repo add ingress-nginx https://kubernetes.github.io/ingress-nginx || true
    helm_quiet repo update
    helm_quiet install ingress-nginx ingress-nginx/ingress-nginx -n "$KUBE_NAMESPACE" --create-namespace --wait
    echo_detail "Ingress Controller installed."

    # Wait for ingress-nginx controller to obtain an external IP (up to 6 minutes)
    wait_for_ingress_ip "$KUBE_NAMESPACE"
  fi
}

# Function to wait for ingress-nginx controller to obtain an external IP
function wait_for_ingress_ip() {
  local namespace="$1"
  local timeout=360  # 6 minutes
  local interval=30
  local elapsed=0

  echo_primary "Waiting for Ingress Controller to obtain an external IP... (Expected time: 2-5 minutes)"

  while [ $elapsed -lt $timeout ]; do
    EXTERNAL_IP=$(kubectl get svc ingress-nginx-controller -n "$namespace" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

    if [ -n "$EXTERNAL_IP" ]; then
      echo_detail "Ingress Controller external IP obtained: $EXTERNAL_IP"
      export INGRESS_EXTERNAL_IP="$EXTERNAL_IP"
      return 0
    fi

    echo_detail "Ingress Controller not ready yet. Retrying in $interval seconds..."
    sleep $interval
    elapsed=$((elapsed + interval))
  done

  echo_error "Ingress Controller did not obtain an external IP within the expected time."
  exit 1
}

# Function to deploy ingress resources
function deploy_ingress_resources() {
  case $INSTALL_TYPE in
    1)
      # Install with HTTPS and Hostname
      echo_primary "Deploying Ingress with HTTPS. (Expected time: 1-3 minutes)"
      ;;
    2)
      # Install without HTTPS
      echo_primary "Deploying Ingress without HTTPS."
      ;;
    3)
      # Minimal Install
      echo_primary "Deploying Ingress without a custom hostname."
      ;;
    *)
      echo_error "Unsupported installation type: $INSTALL_TYPE"
      exit 1
      ;;
  esac

  # Deploy Ingress based on installation type
  case $INSTALL_TYPE in
    1)
      # Install with HTTPS and Hostname
      cat <<EOF | kubectl apply -n "$KUBE_NAMESPACE" -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: opengovernance-ingress
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - ${DOMAIN}
      secretName: opengovernance-tls
  rules:
    - host: ${DOMAIN}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: nginx-proxy
                port:
                  number: 80
EOF
      ;;
    2)
      # Install without HTTPS
      cat <<EOF | kubectl apply -n "$KUBE_NAMESPACE" -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: opengovernance-ingress
spec:
  ingressClassName: nginx
  rules:
    - host: ${DOMAIN}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: nginx-proxy
                port:
                  number: 80
EOF
      ;;
    3)
      # Minimal Install
      cat <<EOF | kubectl apply -n "$KUBE_NAMESPACE" -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: opengovernance-ingress
spec:
  ingressClassName: nginx
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: nginx-proxy
                port:
                  number: 80
EOF
      ;;
  esac

  echo_detail "Ingress resources deployed."
}

# Function to set up Cert-Manager and Let's Encrypt ClusterIssuer
function setup_cert_manager_and_issuer() {
  echo_primary "Setting up Cert-Manager and Let's Encrypt Issuer. (Expected time: 1-2 minutes)"

  # Function to check if Cert-Manager is installed
  function is_cert_manager_installed() {
    if helm_quiet list -A | grep -qw "cert-manager"; then
      return 0
    fi

    if kubectl get namespace cert-manager > /dev/null 2>&1 && kubectl get deployments -n cert-manager | grep -q "cert-manager"; then
      return 0
    fi

    return 1
  }

  # Function to wait for the ClusterIssuer to be ready
  function wait_for_clusterissuer_ready() {
    local max_attempts=10
    local sleep_time=30
    local attempts=0

    echo_detail "Waiting for ClusterIssuer 'letsencrypt' to become ready..."

    while [ $attempts -lt $max_attempts ]; do
      local ready_status
      ready_status=$(kubectl get clusterissuer letsencrypt -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")

      if [ "$ready_status" == "True" ]; then
        echo_detail "ClusterIssuer 'letsencrypt' is ready."
        return 0
      fi

      attempts=$((attempts + 1))
      echo_detail "ClusterIssuer not ready yet. Retrying in $sleep_time seconds... ($attempts/$max_attempts)"
      sleep $sleep_time
    done

    echo_error "ClusterIssuer 'letsencrypt' did not become ready within the expected time."
    exit 1
  }

  # Check if Cert-Manager is already installed
  if is_cert_manager_installed; then
    echo_detail "Cert-Manager is already installed. Skipping installation."
  else
    echo_detail "Installing Cert-Manager via Helm."
    helm_quiet repo add jetstack https://charts.jetstack.io || true
    helm_quiet repo update
    helm_quiet install cert-manager jetstack/cert-manager -n cert-manager --create-namespace --version v1.11.0 --set installCRDs=true --wait
    echo_detail "Cert-Manager installed."
  fi

  # Apply ClusterIssuer for Let's Encrypt
  kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${EMAIL}
    privateKeySecretRef:
      name: letsencrypt-private-key
    solvers:
    - http01:
        ingress:
          class: nginx
EOF

  echo_detail "ClusterIssuer for Let's Encrypt created."

  # Wait for ClusterIssuer to be ready
  wait_for_clusterissuer_ready
}

# Function to restart pods
function restart_pods() {
  echo_primary "Restarting OpenGovernance Pods to Apply Changes."

  # Restart only the specified deployments
  kubectl rollout restart deployment nginx-proxy -n "$KUBE_NAMESPACE"
  kubectl rollout restart deployment opengovernance-dex -n "$KUBE_NAMESPACE"

  echo_detail "Pods restarted successfully."
}

# Function to perform Helm upgrade with appropriate parameters
function helm_upgrade_opengovernance() {
  echo_primary "Upgrading OpenGovernance via Helm with appropriate parameters."

  # Add Helm repository and update
  echo_detail "Adding OpenGovernance Helm repository."
  helm_quiet repo add opengovernance https://opengovern.github.io/charts || true
  helm_quiet repo update

  # Perform Helm upgrade with custom configuration
  echo_detail "Performing Helm upgrade with custom configuration."

  case $INSTALL_TYPE in
    1)
      # Install with HTTPS and Hostname
      helm_quiet upgrade opengovernance opengovernance/opengovernance -n "$KUBE_NAMESPACE" --install --timeout=10m --wait \
        -f - <<EOF
global:
  domain: ${DOMAIN}
dex:
  config:
    issuer: https://${DOMAIN}/dex
EOF
      ;;
    2)
      # Install without HTTPS
      helm_quiet upgrade opengovernance opengovernance/opengovernance -n "$KUBE_NAMESPACE" --install --timeout=10m --wait \
        -f - <<EOF
global:
  domain: ${DOMAIN}
dex:
  config:
    issuer: http://${DOMAIN}/dex
EOF
      ;;
    3)
      # Minimal Install
      helm_quiet upgrade opengovernance opengovernance/opengovernance -n "$KUBE_NAMESPACE" --install --timeout=10m --wait \
        -f - <<EOF
global:
  domain: ${INGRESS_EXTERNAL_IP}
dex:
  config:
    issuer: http://${INGRESS_EXTERNAL_IP}/dex
EOF
      ;;
    *)
      echo_error "Unsupported installation type: $INSTALL_TYPE"
      exit 1
      ;;
  esac

  echo_detail "Helm upgrade completed."
}

# Function to display completion message with protocol, DNS instructions, and default login details
function display_completion_message() {
  # Determine the protocol (http or https)
  local protocol="http"
  if [ "$ENABLE_HTTPS" = true ]; then
    protocol="https"
  fi

  echo_primary "Installation Complete"

  echo_prompt ""
  echo_prompt "-----------------------------------------------------"
  echo_prompt "OpenGovernance has been successfully installed and configured."
  echo_prompt ""
  if [ "$INSTALL_TYPE" -ne 3 ]; then
    echo_prompt "Access your OpenGovernance instance at: ${protocol}://${DOMAIN}"
  else
    echo_prompt "Access your OpenGovernance instance using the public IP: ${INGRESS_EXTERNAL_IP}"
  fi
  echo_prompt ""
  echo_prompt "To sign in, use the following default credentials:"
  echo_prompt "  Username: admin@opengovernance.io"
  echo_prompt "  Password: password"
  echo_prompt ""

  # DNS A record setup instructions if domain is configured and not minimal
  if [ -n "$DOMAIN" ] && [ "$INSTALL_TYPE" -ne 3 ]; then
    echo_prompt "To ensure proper access to your instance, please verify or set up the following DNS A records:"
    echo_prompt ""
    echo_prompt "  Domain: ${DOMAIN}"
    echo_prompt "  Record Type: A"
    echo_prompt "  Value: ${INGRESS_EXTERNAL_IP}"
    echo_prompt ""
    echo_prompt "Note: It may take some time for DNS changes to propagate."
  fi

  echo_prompt "-----------------------------------------------------"
}

# Function to run installation logic
function run_installation_logic() {
  # Check if OpenGovernance is installed
  if ! check_opengovernance_installation; then
    # OpenGovernance is not installed, proceed with installation
    echo_info "OpenGovernance is not installed. Proceeding with installation."

    # If not in silent mode, prompt for installation type
    if [ "$SILENT_INSTALL" = false ]; then
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
  fi
}

# -----------------------------
# Main Execution Flow
# -----------------------------

parse_args "$@"
check_prerequisites
run_installation_logic
