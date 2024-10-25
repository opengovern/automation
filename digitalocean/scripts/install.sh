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
    ENABLE_HTTPS=true
  else
    ENABLE_HTTPS=false
  fi
}

# Function to check prerequisites (Step 1)
function check_prerequisites() {
  echo_info "Step 1 of 12: Checking Prerequisites"

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
  echo_info "Step 2 of 12: Checking OpenGovernance Installation"

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
  echo_info "Step 3 of 12: Checking OpenGovernance Health Status"

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

# Function to check OpenGovernance configuration (Step 4)
function check_opengovernance_config() {
  echo_info "Step 4 of 12: Checking OpenGovernance Configuration"

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
  echo_info "Step 5 of 12: Checking OpenGovernance Readiness"

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

# Function to check pods and migrator jobs (Step 6)
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

# Function to configure email and domain (Step 7)
function configure_email_and_domain() {
  echo_info "Step 7 of 12: Configuring DOMAIN and EMAIL"

  # If DOMAIN is not set, prompt the user
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

  # If EMAIL is not set but required (when DOMAIN is set and HTTPS is desired)
  if [ -n "$DOMAIN" ] && [ "$ENABLE_HTTPS" = true ] && [ -z "$EMAIL" ]; then
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
  fi
}

# Function to install or upgrade OpenGovernance (Step 8)
function install_opengovernance() {
  echo_info "Step 8 of 12: Installing or Upgrading OpenGovernance"

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

    # Determine the issuer based on SSL configuration
    if [ "$ENABLE_HTTPS" = true ]; then
      ISSUER="https://${DOMAIN}/dex"
    else
      ISSUER="http://${DOMAIN}/dex"
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

    # Determine desired issuer
    if [ "$ENABLE_HTTPS" = true ]; then
      DESIRED_ISSUER="https://${DOMAIN}/dex"
    else
      DESIRED_ISSUER="http://${DOMAIN}/dex"
    fi

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

# Function to set up Ingress Controller (Step 9)
function setup_ingress_controller() {
  echo_info "Step 9 of 12: Setting up Ingress Controller."

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

# Function to wait for ingress-nginx controller to obtain an external IP (Issue 2)
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
      return 0
    fi

    echo_info "Ingress-nginx controller does not have an external IP yet. Retrying in $interval seconds..." "$INDENT"
    sleep $interval
    elapsed=$((elapsed + interval))
  done

  echo_error "Ingress-nginx controller did not obtain an external IP within 6 minutes." "$INDENT"
  exit 1
}

# Function to deploy ingress resources (Step 10)
function deploy_ingress_resources() {
  echo_info "Step 10 of 12: Deploying Ingress Resources."

  # Define the Ingress resource
  cat <<EOF | kubectl apply -n opengovernance -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: opengovernance-ingress
  annotations:
    kubernetes.io/ingress.class: "nginx"
    cert-manager.io/cluster-issuer: "letsencrypt"
spec:
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
            name: opengovernance-service
            port:
              number: 80
EOF

  echo_info "Ingress resources deployed." "$INDENT"

  # Optional: Verify Ingress is correctly configured
  kubectl get ingress opengovernance-ingress -n opengovernance
}

# Function to set up Cert-Manager and Issuer for Let's Encrypt (Step 11)
function setup_cert_manager_and_issuer() {
  echo_info "Step 11 of 12: Setting up Cert-Manager and Issuer for Let's Encrypt."

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
    return 1
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


# Function to wait for ClusterIssuer to be ready (Issue 3)
function wait_for_clusterissuer_ready() {
  local timeout=300  # 5 minutes
  local interval=30
  local elapsed=0

  echo_info "Waiting for ClusterIssuer 'letsencrypt' to be ready (up to 5 minutes)."

  while [ $elapsed -lt $timeout ]; do
    ISSUER_READY=$(kubectl get clusterissuer letsencrypt -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)

    if [ "$ISSUER_READY" == "True" ]; then
      echo_info "ClusterIssuer 'letsencrypt' is ready." "$INDENT"
      return 0
    fi

    echo_info "ClusterIssuer 'letsencrypt' is not ready yet. Retrying in $interval seconds..." "$INDENT"
    sleep $interval
    elapsed=$((elapsed + interval))
  done

  echo_error "ClusterIssuer 'letsencrypt' did not become ready within 5 minutes." "$INDENT"
  exit 1
}

# Function to restart pods (Step 12)
function restart_pods() {
  echo_info "Step 12 of 12: Restarting OpenGovernance Pods to Apply Changes."

  # Restart only the specified deployments
  kubectl rollout restart deployment nginx-proxy -n opengovernance
  kubectl rollout restart deployment opengovernance-dex -n opengovernance

  echo_info "Pods restarted successfully." "$INDENT"
}

# Function to install barebones install (Assumed Implementation)
function install_barebones_install() {
  echo_info "Performing Barebones Install of OpenGovernance."

  # Install with minimal configuration
  if [ "$DRY_RUN" = true ]; then
    helm install opengovernance opengovernance/opengovernance -n opengovernance --create-namespace --timeout=10m \
      --dry-run \
      -f - <<EOF
global:
  domain: og.app.domain
dex:
  config:
    issuer: http://og.app.domain/dex
EOF
  else
    helm install opengovernance opengovernance/opengovernance -n opengovernance --create-namespace --timeout=10m \
      -f - <<EOF
global:
  domain: og.app.domain
dex:
  config:
    issuer: http://og.app.domain/dex
EOF
  fi

  echo_info "Barebones Install completed." "$INDENT"
}

# Function to install simple install (Assumed Implementation)
function install_simple_install() {
  echo_info "Performing Simple Install of OpenGovernance."

  # Install with simple configuration
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

  echo_info "Simple Install completed." "$INDENT"
}

# Function to install standard install with HTTPS (Assumed Implementation)
function install_standard_install() {
  echo_info "Performing Standard Install of OpenGovernance with HTTPS."

  # Install with HTTPS configuration
  if [ "$DRY_RUN" = true ]; then
    helm install opengovernance opengovernance/opengovernance -n opengovernance --create-namespace --timeout=10m \
      --dry-run \
      -f - <<EOF
global:
  domain: ${DOMAIN}
dex:
  config:
    issuer: https://${DOMAIN}/dex
EOF
  else
    helm install opengovernance opengovernance/opengovernance -n opengovernance --create-namespace --timeout=10m \
      -f - <<EOF
global:
  domain: ${DOMAIN}
dex:
  config:
    issuer: https://${DOMAIN}/dex
EOF
  fi

  echo_info "Standard Install with HTTPS completed." "$INDENT"
}

# Function to display completion message with protocol, DNS instructions, and default login details
function display_completion_message() {
  echo_info "Step 13 of 13: Installation Complete"

  # Determine the protocol (http or https)
  local protocol="http"
  if [ "$ENABLE_HTTPS" = true ]; then
    protocol="https"
  fi

  echo ""
  echo "-----------------------------------------------------"
  echo "OpenGovernance has been successfully installed and configured."
  echo ""
  echo "Access your OpenGovernance instance at: ${protocol}://${DOMAIN}"
  echo ""
  echo "To sign in, use the following default credentials:"
  echo "  Username: admin@opengovernance.io"
  echo "  Password: password"
  echo ""

  # DNS A record setup instructions if domain is configured
  if [ -n "$DOMAIN" ]; then
    echo "To ensure proper access to your instance, please verify or set up the following DNS A records:"
    echo ""
    echo "  Domain: ${DOMAIN}"
    echo "  Record Type: A"
    echo "  Value: [External IP address assigned to your ingress controller]"
    echo ""
    echo "Note: It may take some time for DNS changes to propagate."
  fi

  # If Ingress is not properly configured, provide port-forward instructions
  if [ "$DEPLOY_SUCCESS" = false ]; then
    provide_port_forward_instructions
  fi

  echo "-----------------------------------------------------"
}

# Function to provide port-forward instructions
function provide_port_forward_instructions() {
  echo_error "OpenGovernance is running but not accessible via Ingress."
  echo "You can access it using port-forwarding as follows:"
  echo "kubectl port-forward -n opengovernance service/opengovernance-service 8080:80"
  echo "Then, access it at http://localhost:8080"
  echo ""
  echo "To sign in, use the following default credentials:"
  echo "  Username: admin@opengovernance.io"
  echo "  Password: password"
}


# Function to check and perform upgrade if needed
function check_and_perform_upgrade() {
  echo_info "Checking for OpenGovernance chart updates."

  helm repo update

  if helm search repo opengovernance/opengovernance | grep -q "opengovernance"; then
    echo_info "Newer OpenGovernance chart version available. Proceeding with upgrade." "$INDENT"
    # The actual upgrade is handled in install_opengovernance based on helm get values
    install_opengovernance
  else
    echo_info "OpenGovernance is already at the latest version." "$INDENT"
  fi
}

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

      if [ -n "$DOMAIN" ]; then
        if [ "$CURRENT_DOMAIN" != "$DOMAIN" ]; then
          echo_info "Provided DOMAIN differs from the current configuration."
          echo_info "Proceeding to upgrade OpenGovernance with new DOMAIN settings."

          install_opengovernance
          check_pods_and_jobs
          setup_ingress_controller

          if [ "$ENABLE_HTTPS" = true ]; then
            setup_cert_manager_and_issuer
          fi

          deploy_ingress_resources
          restart_pods
          display_completion_message

        elif [ "$ENABLE_HTTPS" = true ] && [ "$ssl_configured" != "true" ]; then
          echo_info "SSL/TLS is not configured. Proceeding to configure SSL/TLS with Let's Encrypt."

          install_opengovernance
          check_pods_and_jobs
          setup_ingress_controller
          setup_cert_manager_and_issuer
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
                restart_pods
                display_completion_message
                break
                ;;
              3)
                ENABLE_HTTPS=true
                configure_email_and_domain
                install_standard_install
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
      else
        echo_info "No domain provided and OpenGovernance is running with default settings."
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
