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

# Initialize DOMAIN, EMAIL, and INSTALL_TYPE to ensure no dependency on environment variables
DOMAIN=""
EMAIL=""
INSTALL_TYPE=1  # Default installation type

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
  echo "Usage: $0 [-d DOMAIN] [-e EMAIL] [-t INSTALL_TYPE] [--dry-run]"
  echo ""
  echo "Options:"
  echo "  -d, --domain        Specify the domain for OpenGovernance."
  echo "  -e, --email         Specify the email for Let's Encrypt certificate generation."
  echo "  -t, --type          Specify the installation type:"
  echo "                       1) Standard (Custom hostname + SSL)"
  echo "                       2) No HTTPS (Simple install with hostname)"
  echo "                       3) Minimal (Simple install with no hostname)"
  echo "                       4) Barebones (Requires kubectl port forwarding)"
  echo "                       Default: 1"
  echo "  --dry-run           Perform a trial run with no changes made."
  echo "  -h, --help          Display this help message."
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
      -t|--type)
        INSTALL_TYPE="$2"
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

  # Validate INSTALL_TYPE
  if ! [[ "$INSTALL_TYPE" =~ ^[1-4]$ ]]; then
    echo_error "Invalid installation type: $INSTALL_TYPE"
    usage
  fi

  # Validate DOMAIN and EMAIL if they are set via arguments
  case $INSTALL_TYPE in
    1)
      # Standard (Custom hostname + SSL)
      if [ -n "$DOMAIN" ]; then
        validate_domain
      else
        echo_error "Installation type 1 requires a DOMAIN." "$INDENT"
        usage
      fi

      if [ -n "$EMAIL" ]; then
        validate_email
        ENABLE_HTTPS=true
      else
        echo_error "Installation type 1 requires an EMAIL for SSL/TLS setup." "$INDENT"
        usage
      fi
      ;;
    2)
      # No HTTPS (Simple install with hostname)
      if [ -n "$DOMAIN" ]; then
        validate_domain
      else
        echo_error "Installation type 2 requires a DOMAIN." "$INDENT"
        usage
      fi
      ENABLE_HTTPS=false
      ;;
    3)
      # Minimal (Simple install with no hostname)
      ENABLE_HTTPS=false
      ;;
    4)
      # Barebones (Requires kubectl port forwarding)
      ENABLE_HTTPS=false
      ;;
    *)
      echo_error "Unsupported installation type: $INSTALL_TYPE"
      usage
      ;;
  esac
}



# Function to check prerequisites
function check_prerequisites() {
  echo_info "Checking Prerequisites"

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

# Function to clean up failed OpenGovernance installation
function cleanup_failed_install() {
  echo_error "OpenGovernance installation failed. Initiating cleanup..." "$INDENT"
  echo_info "Cleaning up failed installation in 10 seconds..." "$INDENT"

  # Countdown timer
  for i in {10..1}; do
    echo_info "Cleaning up in $i seconds..." "$INDENT"
    sleep 1
  done

  # Uninstall the Helm release
  echo_info "Uninstalling OpenGovernance Helm release..." "$INDENT"
  helm uninstall opengovernance -n opengovernance || echo_error "Failed to uninstall Helm release." "$INDENT"

  # Delete the namespace
  echo_info "Deleting 'opengovernance' namespace..." "$INDENT"
  kubectl delete namespace opengovernance || echo_error "Failed to delete namespace." "$INDENT"

  echo_info "Cleanup of failed OpenGovernance installation completed." "$INDENT"
}

# Function to check if OpenGovernance is installed
function check_opengovernance_installation() {
  echo_info "Checking OpenGovernance Installation"

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
  elif [ "$helm_release_status" == "failed" ]; then
    echo_error "Error: OpenGovernance is installed but not in 'deployed' state (current status: $helm_release_status)." "$INDENT"
    cleanup_failed_install
    APP_INSTALLED=false
    return 1
  else
    echo_error "Error: OpenGovernance is in an unexpected state ('$helm_release_status'). Attempting cleanup..." "$INDENT"
    cleanup_failed_install
    APP_INSTALLED=false
    return 1
  fi
}

# Function to check OpenGovernance health status
function check_opengovernance_health() {
  echo_info "Checking OpenGovernance Health Status"

  # Check if the 'opengovernance' namespace exists
  if ! kubectl get namespace opengovernance > /dev/null 2>&1; then
    echo_error "Namespace 'opengovernance' does not exist." "$INDENT"
    APP_HEALTHY=false
    return 1
  fi

  # Check the health of the OpenGovernance deployment
  local unhealthy_pods
  # Extract the STATUS column (3rd column) and exclude 'Running' and 'Completed'
  unhealthy_pods=$(kubectl get pods -n opengovernance --no-headers | awk '{print $3}' | grep -v -E 'Running|Completed' || true)

  if [ -z "$unhealthy_pods" ]; then
    echo_info "All OpenGovernance pods are healthy." "$INDENT"
    APP_HEALTHY=true
  else
    echo_error "Some OpenGovernance pods are not healthy." "$INDENT"
    kubectl get pods -n opengovernance
    APP_HEALTHY=false
  fi
}

# Function to check OpenGovernance configuration
function check_opengovernance_config() {
  echo_info "Checking OpenGovernance Configuration"

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
  if [[ "$CURRENT_DOMAIN" == "og.app.domain" || -z "$CURRENT_DOMAIN" ]]; then
    custom_host_name=false
  elif [[ "$CURRENT_DOMAIN" =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]]; then
    custom_host_name=true
  fi

  # Retrieve redirect Uris
  redirect_uris=$(echo "$ENV_VARS" | grep -o '"name":"METADATA_DEX_PUBLIC_CLIENT_REDIRECT_URIS","value":"[^"]*"' | awk -F'"' '{print $8}')

  # Check if the primary domain is present in the redirect Uris
  if echo "$redirect_uris" | grep -q "$CURRENT_DOMAIN"; then
    dex_configuration_ok=true
  fi

  # Enhanced SSL configuration check
  if [[ "$custom_host_name" == true ]] && \
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
  echo_info "Configuration Check Results:"
  echo_info "  Custom Hostname: $custom_host_name" "$INDENT$INDENT"
  echo_info "  App Configured Hostname: $CURRENT_DOMAIN" "$INDENT$INDENT"
  echo_info "  Dex Configuration OK: $dex_configuration_ok" "$INDENT$INDENT"
  echo_info "  SSL/TLS Configured in Ingress: $ssl_configured" "$INDENT$INDENT"

  # Export variables for use in other functions
  export custom_host_name
  export ssl_configured
  export CURRENT_DOMAIN
}

# Function to check OpenGovernance readiness
function check_opengovernance_readiness() {
  echo_info "Checking OpenGovernance Readiness"

  # Check the readiness of all pods in the 'opengovernance' namespace
  local not_ready_pods
  # Extract the STATUS column (3rd column) and exclude 'Running' and 'Completed'
  not_ready_pods=$(kubectl get pods -n opengovernance --no-headers | awk '{print $3}' | grep -v -E 'Running|Completed' || true)

  if [ -z "$not_ready_pods" ]; then
    echo_info "All OpenGovernance pods are ready." "$INDENT"
    return 0
  else
    echo_error "Some OpenGovernance pods are not healthy." "$INDENT"
    kubectl get pods -n opengovernance
    return 1
  fi
}

# Function to check pods and migrator jobs
function check_pods_and_jobs() {
  local attempts=0
  local max_attempts=12  # 12 attempts * 30 seconds = 6 minutes
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

# Function to configure email and domain
function configure_email_and_domain() {
  echo_info "Configuring DOMAIN and EMAIL"

  # Depending on the installation type, prompt for DOMAIN and EMAIL as needed
  case $INSTALL_TYPE in
    1)
      # Standard (Custom hostname + SSL)
      if [ -z "$DOMAIN" ]; then
        while true; do
          echo ""
          echo "Enter your domain for OpenGovernance (required for custom hostname)."
          read -p "Domain: " DOMAIN < /dev/tty
          if [ -z "$DOMAIN" ]; then
            echo_error "Domain is required for installation type 1." "$INDENT"
            continue
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

      if [ -z "$EMAIL" ]; then
        while true; do
          echo ""
          echo "Enter your email for HTTPS/TLS setup and Let's Encrypt certificate issuance."
          echo "This email is secure and private. You can change it later."
          read -p "Email: " EMAIL < /dev/tty
          if [ -z "$EMAIL" ]; then
            echo_error "Email is required for installation type 1." "$INDENT"
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
      fi
      ;;
    2)
      # No HTTPS (Simple install with hostname)
      if [ -z "$DOMAIN" ]; then
        while true; do
          echo ""
          echo "Enter your domain for OpenGovernance (required for hostname)."
          read -p "Domain: " DOMAIN < /dev/tty
          if [ -z "$DOMAIN" ]; then
            echo_error "Domain is required for installation type 2." "$INDENT"
            continue
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
      ;;
    3)
      # Minimal (Simple install with no hostname)
      # No DOMAIN or EMAIL required
      echo_info "Minimal installation selected. No DOMAIN or EMAIL required." "$INDENT"
      ;;
    4)
      # Barebones (Requires kubectl port forwarding)
      # No DOMAIN or EMAIL required
      echo_info "Barebones installation selected. No DOMAIN or EMAIL required." "$INDENT"
      ;;
    *)
      echo_error "Unsupported installation type: $INSTALL_TYPE"
      usage
      ;;
  esac
}

# Function to install or upgrade OpenGovernance
function install_opengovernance() {
  echo_info "Installing or Upgrading OpenGovernance"

  # Add the OpenGovernance Helm repository and update
  if ! helm repo list | grep -qw opengovernance; then
    helm repo add opengovernance https://opengovern.github.io/charts
    echo_info "Added OpenGovernance Helm repository." "$INDENT"
  else
    echo_info "OpenGovernance Helm repository already exists. Skipping add." "$INDENT"
  fi
  helm repo update

  if [ "$APP_INSTALLED" = false ]; then
    echo_info "Installing OpenGovernance via Helm." "$INDENT"

    # Determine the issuer based on installation type
    case $INSTALL_TYPE in
      1)
        # Standard (Custom hostname + SSL)
        ISSUER="https://${DOMAIN}/dex"
        ;;
      2)
        # No HTTPS (Simple install with hostname)
        ISSUER="http://${DOMAIN}/dex"
        ;;
      3)
        # Minimal (Simple install with no hostname)
        ISSUER="http://localhost/dex"
        ;;
      4)
        # Barebones (Requires kubectl port forwarding)
        ISSUER="http://${INGRESS_EXTERNAL_IP}/dex"
        ;;
      *)
        echo_error "Unsupported installation type: $INSTALL_TYPE"
        exit 1
        ;;
    esac

    # Set DOMAIN based on INSTALL_TYPE
    if [ "$INSTALL_TYPE" -eq 4 ]; then
      DOMAIN="$INGRESS_EXTERNAL_IP"
    fi

    if [ "$DRY_RUN" = true ]; then
      helm install opengovernance opengovernance/opengovernance -n opengovernance --create-namespace --timeout=10m \
        --dry-run \
        -f - <<EOF
global:
  domain: ${DOMAIN}
dex:
  config:
    issuer: ${ISSUER}
EOF
    else
      helm install opengovernance opengovernance/opengovernance -n opengovernance --create-namespace --timeout=10m \
        -f - <<EOF
global:
  domain: ${DOMAIN}
dex:
  config:
    issuer: ${ISSUER}
EOF
    fi

    echo_info "OpenGovernance application installation completed." "$INDENT"
  else
    echo_info "OpenGovernance is already installed. Checking for necessary upgrades or configurations." "$INDENT"

    # Fetch current Helm values
    CURRENT_HELM_VALUES=$(helm get values opengovernance -n opengovernance --output yaml)

    # Determine if desired domain or HTTPS settings differ from current
    DESIRED_DOMAIN="$DOMAIN"
    DESIRED_ENABLE_HTTPS="$ENABLE_HTTPS"

    # Extract current domain from Helm values
    CURRENT_DOMAIN_HELM=$(echo "$CURRENT_HELM_VALUES" | grep -E '^\s*domain:' | awk '{print $2}')

    # Extract current issuer from Helm values
    CURRENT_ISSUER_HELM=$(echo "$CURRENT_HELM_VALUES" | grep -E '^\s*issuer:' | awk '{print $2}')

    # Determine desired issuer based on installation type
    case $INSTALL_TYPE in
      1)
        # Standard (Custom hostname + SSL)
        DESIRED_ISSUER="https://${DOMAIN}/dex"
        ;;
      2)
        # No HTTPS (Simple install with hostname)
        DESIRED_ISSUER="http://${DOMAIN}/dex"
        ;;
      3)
        # Minimal (Simple install with no hostname)
        DESIRED_ISSUER="http://localhost/dex"
        ;;
      4)
        # Barebones (Requires kubectl port forwarding)
        DESIRED_ISSUER="http://${INGRESS_EXTERNAL_IP}/dex"
        ;;
      *)
        echo_error "Unsupported installation type: $INSTALL_TYPE"
        exit 1
        ;;
    esac

    # Check if domain or issuer needs to be updated
    if [ "$DESIRED_DOMAIN" != "$CURRENT_DOMAIN_HELM" ] || [ "$DESIRED_ISSUER" != "$CURRENT_ISSUER_HELM" ]; then
      echo_info "Detected changes in DOMAIN or HTTPS configuration. Upgrading OpenGovernance via Helm." "$INDENT"

      if [ "$DRY_RUN" = true ]; then
        helm upgrade opengovernance opengovernance/opengovernance -n opengovernance --timeout=10m \
          --dry-run \
          -f - <<EOF
global:
  domain: ${DESIRED_DOMAIN}
dex:
  config:
    issuer: ${DESIRED_ISSUER}
EOF
      else
        helm upgrade opengovernance opengovernance/opengovernance -n opengovernance --timeout=10m \
          -f - <<EOF
global:
  domain: ${DESIRED_DOMAIN}
dex:
  config:
    issuer: ${DESIRED_ISSUER}
EOF
      fi

      echo_info "OpenGovernance application upgrade completed." "$INDENT"
    else
      echo_info "No changes detected in DOMAIN or HTTPS configuration. Skipping Helm upgrade." "$INDENT"
    fi
  fi
}

# Function to set up Ingress Controller
function setup_ingress_controller() {
  echo_info "Setting up Ingress Controller."

  # Define the namespace for ingress-nginx (Keeping it in opengovernance namespace)
  local INGRESS_NAMESPACE="opengovernance"

  # Check if the namespace exists, if not, create it
  if ! kubectl get namespace "$INGRESS_NAMESPACE" > /dev/null 2>&1; then
    kubectl create namespace "$INGRESS_NAMESPACE"
    echo_info "Created namespace $INGRESS_NAMESPACE." "$INDENT"
  fi

  # Handle existing ClusterRole ingress-nginx
  if kubectl get clusterrole ingress-nginx > /dev/null 2>&1; then
    # Check the current release namespace annotation
    CURRENT_RELEASE_NAMESPACE=$(kubectl get clusterrole ingress-nginx -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-namespace}' 2>/dev/null || true)
    if [ "$CURRENT_RELEASE_NAMESPACE" != "$INGRESS_NAMESPACE" ]; then
      echo_info "ClusterRole 'ingress-nginx' exists with release namespace '$CURRENT_RELEASE_NAMESPACE'. Deleting to avoid conflicts." "$INDENT"
      kubectl delete clusterrole ingress-nginx
      kubectl delete clusterrolebinding ingress-nginx
    fi
  fi

  # Check if ingress-nginx is already installed in the opengovernance namespace
  if helm ls -n "$INGRESS_NAMESPACE" | grep -qw ingress-nginx; then
    echo_info "Ingress Controller already installed in the $INGRESS_NAMESPACE namespace. Skipping installation." "$INDENT"
  else
    echo_info "Installing ingress-nginx via Helm in the $INGRESS_NAMESPACE namespace." "$INDENT"
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
    helm repo update
    helm install ingress-nginx ingress-nginx/ingress-nginx -n "$INGRESS_NAMESPACE" --create-namespace
    echo_info "Ingress Controller installed in the $INGRESS_NAMESPACE namespace." "$INDENT"

    # Wait for ingress-nginx controller to obtain an external IP (up to 6 minutes)
    wait_for_ingress_ip "$INGRESS_NAMESPACE"
  fi
}

# Function to wait for ingress-nginx controller to obtain an external IP
function wait_for_ingress_ip() {
  local namespace="$1"
  local timeout=360  # 6 minutes
  local interval=30
  local elapsed=0

  echo_info "Waiting for ingress-nginx controller to obtain an external IP (up to 6 minutes)."

  while [ $elapsed -lt $timeout ]; do
    EXTERNAL_IP=$(kubectl get svc ingress-nginx-controller -n "$namespace" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

    if [ -n "$EXTERNAL_IP" ]; then
      echo_info "Ingress-nginx controller has been assigned external IP: $EXTERNAL_IP" "$INDENT"
      export INGRESS_EXTERNAL_IP="$EXTERNAL_IP"
      return 0
    fi

    echo_info "Ingress-nginx controller does not have an external IP yet. Retrying in $interval seconds..." "$INDENT"
    sleep $interval
    elapsed=$((elapsed + interval))
  done

  echo_error "Ingress-nginx controller did not obtain an external IP within 6 minutes." "$INDENT"
  exit 1
}

# Function to deploy ingress resources
function deploy_ingress_resources() {
  echo_info "Deploying Ingress Resources."

  case $INSTALL_TYPE in
    1)
      # Standard (Custom hostname + SSL)
      echo_info "Deploying Ingress with a custom hostname and HTTPS." "$INDENT"

      cat <<EOF | kubectl apply -n opengovernance -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: opengovernance-ingress
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt" # Ensure this matches your ClusterIssuer name
    nginx.ingress.kubernetes.io/ssl-redirect: "true" # Enforce HTTPS
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - ${DOMAIN}
      secretName: opengovernance-tls # TLS secret managed by Cert-Manager
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
      # No HTTPS (Simple install with hostname)
      echo_info "Deploying Ingress with a custom hostname and HTTP." "$INDENT"

      cat <<EOF | kubectl apply -n opengovernance -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: opengovernance-ingress
  annotations:
    kubernetes.io/ingress.class: "nginx"
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
      # Minimal (Simple install with no hostname)
      echo_info "Deploying Ingress without a custom hostname (default settings)." "$INDENT"

      cat <<EOF | kubectl apply -n opengovernance -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: opengovernance-ingress
  annotations:
    kubernetes.io/ingress.class: "nginx"
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
    4)
      # Barebones (Requires kubectl port forwarding)
      echo_info "Barebones installation selected. Skipping Ingress deployment." "$INDENT"
      ;;
    *)
      echo_error "Unsupported installation type: $INSTALL_TYPE" "$INDENT"
      exit 1
      ;;
  esac

  echo_info "Ingress resources deployed." "$INDENT"

  # Optional: Verify Ingress is correctly configured
  if [ "$INSTALL_TYPE" -ne 4 ]; then
    kubectl get ingress opengovernance-ingress -n opengovernance
  fi
}

# Function to set up Cert-Manager and Issuer for Let's Encrypt
function setup_cert_manager_and_issuer() {
  echo_info "Setting up Cert-Manager and Issuer for Let's Encrypt."

  # Function to check if Cert-Manager is installed in any namespace
  function is_cert_manager_installed() {
    echo_info "Checking if Cert-Manager is installed in any namespace..." "$INDENT"

    # Check if there are any Helm releases with the name "cert-manager"
    if helm list -A | grep -qw "cert-manager"; then
      echo_info "Cert-Manager is already installed via Helm in the following namespaces:" "$INDENT"
      helm list -A | grep "cert-manager" | awk '{print $1, "in namespace", $2}'
      return 0
    fi

    # Check if cert-manager namespace exists and has relevant deployments
    if kubectl get namespaces | grep -qw "cert-manager"; then
      echo_info "Cert-Manager namespace exists. Checking for Cert-Manager deployments..." "$INDENT"
      
      # Check if there are cert-manager deployments
      if kubectl get deployments -n cert-manager | grep -q "cert-manager"; then
        echo_info "Cert-Manager components are installed in the 'cert-manager' namespace." "$INDENT"
        return 0
      fi
    fi

    echo_info "Cert-Manager is not installed in any namespace." "$INDENT"
    return 1
  }

  # Function to wait for the ClusterIssuer to be ready
  function wait_for_clusterissuer_ready() {
    local max_attempts=10
    local sleep_time=30
    local attempts=0

    echo_info "Waiting for ClusterIssuer 'letsencrypt' to become ready (timeout 5 minutes)..." "$INDENT"

    while [ $attempts -lt $max_attempts ]; do
      local ready_status=$(kubectl get clusterissuer letsencrypt -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")

      if [ "$ready_status" == "True" ]; then
        echo_info "ClusterIssuer 'letsencrypt' is ready." "$INDENT"
        return 0
      fi

      attempts=$((attempts + 1))
      echo_info "ClusterIssuer 'letsencrypt' not ready yet. Checking again in $sleep_time seconds... (Attempt $attempts/$max_attempts)" "$INDENT"
      sleep $sleep_time
    done

    echo_error "ClusterIssuer 'letsencrypt' did not become ready within the expected time." "$INDENT"
    exit 1
  }

  # Check if Cert-Manager is already installed
  if is_cert_manager_installed; then
    echo_info "Cert-Manager already installed. Skipping installation." "$INDENT"
  else
    echo_info "Installing Cert-Manager via Helm in the opengovernance namespace." "$INDENT"
    helm repo add jetstack https://charts.jetstack.io
    helm repo update
    helm install cert-manager jetstack/cert-manager --namespace opengovernance --create-namespace --version v1.11.0 --set installCRDs=true
    echo_info "Cert-Manager installed in the opengovernance namespace." "$INDENT"
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

  echo_info "ClusterIssuer for Let's Encrypt created." "$INDENT"

  # Wait for ClusterIssuer to be ready
  wait_for_clusterissuer_ready
}

# Function to restart pods
function restart_pods() {
  echo_info "Restarting OpenGovernance Pods to Apply Changes."

  # Restart only the specified deployments
  kubectl rollout restart deployment nginx-proxy -n opengovernance
  kubectl rollout restart deployment opengovernance-dex -n opengovernance

  echo_info "Pods restarted successfully." "$INDENT"
}

# Function to set up barebones install
function install_barebones_install() {
  echo_info "Performing Barebones Install of OpenGovernance."

  # Install with default configuration without custom parameters
  if [ "$DRY_RUN" = true ]; then
    helm install -n opengovernance opengovernance opengovernance/opengovernance --create-namespace --timeout=10m --dry-run
  else
    helm install -n opengovernance opengovernance opengovernance/opengovernance --create-namespace --timeout=10m
  fi

  echo_info "Barebones Install completed." "$INDENT"

  # Attempt to set up port-forwarding
  set +e  # Temporarily disable exit on error
  if kubectl port-forward -n opengovernance svc/nginx-proxy 8080:80; then
    echo_error "OpenGovernance is running. Access it at http://localhost:8080"
    echo "To sign in, use the following default credentials:"
    echo "  Username: admin@opengovernance.io"
    echo "  Password: password"
    echo "Open http://localhost:8080/ in your browser and sign in."
  else
    provide_port_forward_instructions
  fi
  set -e  # Re-enable exit on error
}

# Function to install no HTTPS install (Simple install with hostname)
function install_no_https_install() {
  echo_info "Performing No HTTPS Install of OpenGovernance."

  # Install with simple configuration without SSL
  if [ "$DRY_RUN" = true ]; then
    helm install opengovernance opengovernance/opengovernance -n opengovernance --create-namespace --timeout=10m \
      --dry-run \
      -f - <<EOF
global:
  domain: ${DOMAIN}
dex:
  config:
    issuer: http://${DOMAIN}/dex
EOF
  else
    helm install opengovernance opengovernance/opengovernance -n opengovernance --create-namespace --timeout=10m \
      -f - <<EOF
global:
  domain: ${DOMAIN}
dex:
  config:
    issuer: http://${DOMAIN}/dex
EOF
  fi

  echo_info "No HTTPS Install completed." "$INDENT"
}

# Function to install minimal install (Simple install with no hostname)
function install_minimal_install() {
  echo_info "Performing Minimal Install of OpenGovernance."

  # Install with minimal configuration without hostname
  if [ "$DRY_RUN" = true ]; then
    helm install opengovernance opengovernance/opengovernance -n opengovernance --create-namespace --timeout=10m \
      --dry-run \
      -f - <<EOF
global:
  domain: ""
dex:
  config:
    issuer: http://localhost/dex
EOF
  else
    helm install opengovernance opengovernance/opengovernance -n opengovernance --create-namespace --timeout=10m \
      -f - <<EOF
global:
  domain: ""
dex:
  config:
    issuer: http://localhost/dex
EOF
  fi

  echo_info "Minimal Install completed." "$INDENT"
}

# Function to provide port-forward instructions
function provide_port_forward_instructions() {
  echo_error "OpenGovernance is running but not accessible via Ingress."
  echo "You can access it using port-forwarding as follows:"
  echo "kubectl port-forward -n opengovernance service/nginx-proxy 8080:80"
  echo "Then, access it at http://localhost:8080"
  echo ""
  echo "To sign in, use the following default credentials:"
  echo "  Username: admin@opengovernance.io"
  echo "  Password: password"
}

# Function to display completion message with protocol, DNS instructions, and default login details
function display_completion_message() {
  echo_info "Installation Complete"

  # Determine the protocol (http or https)
  local protocol="http"
  if [ "$ENABLE_HTTPS" = true ]; then
    protocol="https"
  fi

  echo ""
  echo "-----------------------------------------------------"
  echo "OpenGovernance has been successfully installed and configured."
  echo ""
  if [ "$INSTALL_TYPE" -ne 3 ] && [ "$INSTALL_TYPE" -ne 4 ]; then
    echo "Access your OpenGovernance instance at: ${protocol}://${DOMAIN}"
  elif [ "$INSTALL_TYPE" -eq 4 ]; then
    echo "Access your OpenGovernance instance at: ${protocol}://${INGRESS_EXTERNAL_IP}"
  else
    echo "Access your OpenGovernance instance using the external IP: ${INGRESS_EXTERNAL_IP}"
  fi
  echo ""
  echo "To sign in, use the following default credentials:"
  echo "  Username: admin@opengovernance.io"
  echo "  Password: password"
  echo ""

  # DNS A record setup instructions if domain is configured and not minimal
  if [ -n "$DOMAIN" ] && [ "$INSTALL_TYPE" -ne 3 ]; then
    echo "To ensure proper access to your instance, please verify or set up the following DNS A records:"
    echo ""
    echo "  Domain: ${DOMAIN}"
    echo "  Record Type: A"
    echo "  Value: ${INGRESS_EXTERNAL_IP}"
    echo ""
    echo "Note: It may take some time for DNS changes to propagate."
  fi

  # If Ingress is not properly configured or it's a Barebones install, provide port-forward instructions
  if [ "$DEPLOY_SUCCESS" = false ] || [ "$INSTALL_TYPE" -eq 4 ]; then
    provide_port_forward_instructions
  fi

  echo "-----------------------------------------------------"
}

# Helper function to get installation type description
function get_install_type_description() {
  local type="$1"
  case $type in
    1) echo "Standard (Custom hostname + SSL)" ;;
    2) echo "No HTTPS (Simple install with hostname)" ;;
    3) echo "Minimal (Simple install with no hostname)" ;;
    4) echo "Barebones (Requires Port-Forwarding)" ;;
    5) echo "Exit" ;;
    *) echo "Unknown" ;;
  esac
}

# Function to run installation logic
function run_installation_logic() {
  # Check if app is installed
  if ! check_opengovernance_installation; then
    # App is not installed, proceed to install
    echo_info "OpenGovernance is not installed."

    # Configure email and domain based on installation type
    configure_email_and_domain

    # Perform installation based on installation type
    case $INSTALL_TYPE in
      1)
        install_opengovernance  # Standard Install
        ;;
      2)
        install_no_https_install  # No HTTPS Install
        ;;
      3)
        install_minimal_install  # Minimal Install
        ;;
      4)
        install_barebones_install  # Barebones Install
        ;;
      *)
        echo_error "Unsupported installation type: $INSTALL_TYPE"
        exit 1
        ;;
    esac

    check_pods_and_jobs

    # Attempt to set up Ingress Controller and related resources
    set +e  # Temporarily disable exit on error
    if [ "$INSTALL_TYPE" -ne 4 ] && [ "$INSTALL_TYPE" -ne 3 ]; then
      setup_ingress_controller
      DEPLOY_SUCCESS=true

      deploy_ingress_resources || DEPLOY_SUCCESS=false
      if [ "$ENABLE_HTTPS" = true ]; then
        setup_cert_manager_and_issuer || DEPLOY_SUCCESS=false
      fi
      restart_pods || DEPLOY_SUCCESS=false
    elif [ "$INSTALL_TYPE" -eq 3 ]; then
      # Minimal install: Use external IP as domain and perform helm upgrade after obtaining external IP
      setup_ingress_controller
      DEPLOY_SUCCESS=true

      deploy_ingress_resources || DEPLOY_SUCCESS=false
      restart_pods || DEPLOY_SUCCESS=false

      # Perform helm upgrade with external IP as domain
      if [ "$DEPLOY_SUCCESS" = true ]; then
        echo_info "Performing Helm upgrade with external IP as domain." "$INDENT"
        DOMAIN="$INGRESS_EXTERNAL_IP"
        install_opengovernance
        restart_pods
      fi
    else
      DEPLOY_SUCCESS=false
    fi
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
      install_opengovernance
      check_pods_and_jobs
      if [ "$INSTALL_TYPE" -ne 4 ] && [ "$INSTALL_TYPE" -ne 3 ]; then
        setup_ingress_controller
      fi

      if [ "$ENABLE_HTTPS" = true ]; then
        setup_cert_manager_and_issuer
      fi

      if [ "$INSTALL_TYPE" -ne 4 ] && [ "$INSTALL_TYPE" -ne 3 ]; then
        deploy_ingress_resources
      fi

      restart_pods
      display_completion_message
    else
      # App is healthy
      check_opengovernance_config

      if [ -n "$DOMAIN" ]; then
        if [ "$CURRENT_DOMAIN" != "$DOMAIN" ]; then
          echo_info "Provided DOMAIN differs from the current configuration."
          echo_info "Proceeding to upgrade OpenGovernance with new DOMAIN settings."

          install_opengovernance
          check_pods_and_jobs
          if [ "$INSTALL_TYPE" -ne 4 ] && [ "$INSTALL_TYPE" -ne 3 ]; then
            setup_ingress_controller
          fi

          if [ "$ENABLE_HTTPS" = true ]; then
            setup_cert_manager_and_issuer
          fi

          if [ "$INSTALL_TYPE" -ne 4 ] && [ "$INSTALL_TYPE" -ne 3 ]; then
            deploy_ingress_resources
          fi
          restart_pods
          display_completion_message

        elif [ "$ENABLE_HTTPS" = true ] && [ "$ssl_configured" != "true" ]; then
          echo_info "SSL/TLS is not configured. Proceeding to configure SSL/TLS with Let's Encrypt."

          install_opengovernance
          check_pods_and_jobs
          if [ "$INSTALL_TYPE" -ne 4 ] && [ "$INSTALL_TYPE" -ne 3 ]; then
            setup_ingress_controller
          fi
          setup_cert_manager_and_issuer
          if [ "$INSTALL_TYPE" -ne 4 ] && [ "$INSTALL_TYPE" -ne 3 ]; then
            deploy_ingress_resources
          fi
          restart_pods
          display_completion_message

        elif [ "$custom_host_name" == "true" ] && [ "$ssl_configured" == "true" ]; then
          echo_info "OpenGovernance is fully configured with custom hostname and SSL/TLS."
        else
          # Existing logic for handling other cases
          echo ""
          echo "OpenGovernance is installed but not fully configured."
          echo "Please select an option to proceed:"
          echo "1) Standard (Custom hostname + SSL)"
          echo "2) No HTTPS (Simple install with hostname)"
          echo "3) Minimal (Simple install with no hostname)"
          echo "4) Barebones (Requires Port-Forwarding)"
          echo "5) Exit"

          # Default to 1 if no input is provided within a timeout (e.g., 10 seconds)
          read -t 10 -p "Enter the number corresponding to your choice [Default: 1]: " choice < /dev/tty || choice=1

          # If no choice is made, default to 1
          choice=${choice:-1}

          # Ensure the choice is within 1-5
          if ! [[ "$choice" =~ ^[1-5]$ ]]; then
            echo "Invalid option. Defaulting to 1) Standard Install."
            choice=1
          fi

          # Bold the selection
          echo ""
          echo -e "You selected: \033[1m$choice) $(get_install_type_description $choice)\033[0m"

          case $choice in
            1)
              ENABLE_HTTPS=true
              echo "You selected Standard Install. Please provide your domain and email."
              configure_email_and_domain
              install_opengovernance
              ;;
            2)
              ENABLE_HTTPS=false
              echo "You selected No HTTPS Install. Please provide your domain."
              configure_email_and_domain
              install_no_https_install
              ;;
            3)
              ENABLE_HTTPS=false
              echo "You selected Minimal Install. Using external IP as domain."
              # No need to configure domain or email
              install_minimal_install
              ;;
            4)
              ENABLE_HTTPS=false
              echo "You selected Barebones Install. Skipping Ingress setup."
              install_barebones_install
              ;;
            5)
              echo_info "Exiting the script."
              exit 0
              ;;
            *)
              echo "Invalid option. Defaulting to 1) Standard Install."
              ENABLE_HTTPS=true
              configure_email_and_domain
              install_opengovernance
              ;;
          esac

          check_pods_and_jobs

          # Attempt to set up Ingress Controller and related resources based on installation type
          set +e  # Temporarily disable exit on error
          if [ "$choice" -ne 4 ] && [ "$choice" -ne 3 ]; then
            setup_ingress_controller
            DEPLOY_SUCCESS=true

            deploy_ingress_resources || DEPLOY_SUCCESS=false
            if [ "$ENABLE_HTTPS" = true ]; then
              setup_cert_manager_and_issuer || DEPLOY_SUCCESS=false
            fi
            restart_pods || DEPLOY_SUCCESS=false
          elif [ "$choice" -eq 3 ]; then
            # Minimal install: Use external IP as domain and perform helm upgrade after obtaining external IP
            setup_ingress_controller
            DEPLOY_SUCCESS=true

            deploy_ingress_resources || DEPLOY_SUCCESS=false
            restart_pods || DEPLOY_SUCCESS=false

            # Perform helm upgrade with external IP as domain
            if [ "$DEPLOY_SUCCESS" = true ]; then
              echo_info "Performing Helm upgrade with external IP as domain." "$INDENT"
              DOMAIN="$INGRESS_EXTERNAL_IP"
              install_opengovernance
              restart_pods
            fi
          else
            DEPLOY_SUCCESS=false
          fi
          set -e  # Re-enable exit on error

          if [ "$DEPLOY_SUCCESS" = true ]; then
            display_completion_message
          else
            provide_port_forward_instructions
          fi
        fi
      fi
    fi
  fi
}

# -----------------------------
# Main Execution Flow
# -----------------------------

# Detect if the script is running in an interactive terminal
if [ -t 0 ]; then
  INTERACTIVE=true
else
  INTERACTIVE=false
fi

parse_args "$@"
check_prerequisites
run_installation_logic