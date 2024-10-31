#!/usr/bin/env bash

# -----------------------------
# Configuration Variables
# -----------------------------

# Fixed Kubernetes namespace for OpenGovernance
KUBE_NAMESPACE="opengovernance"

# Default Kubernetes cluster region for OpenGovernance
DIGITALOCEAN_REGION="nyc3"

# -----------------------------
# Logging Configuration
# -----------------------------

LOGFILE="$HOME/opengovernance_install.log"

# Ensure the log directory exists
mkdir -p "$(dirname "$LOGFILE")"

# Redirect all output to the log file only
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

# Function to display detail messages to both console and log with timestamp, indented with 4 tabs
function echo_detail() {
  local message="$1"
  local indent="                                "  # 32 spaces (4 tabs)
  # Print to console with indentation
  echo_prompt "${indent}${message}"
  # Log detailed message with timestamp
  echo_info "${indent}${message}"
}

# Function to ensure the OpenGovernance Helm repository is added and updated
function ensure_helm_repo() {
    REPO_NAME="opengovernance"
    REPO_URL="https://opengovern.github.io/charts/"

    if ! helm repo list | grep -q "^$REPO_NAME "; then
        echo_detail "Adding Helm repository '$REPO_NAME'."
        helm repo add "$REPO_NAME" "$REPO_URL" >/dev/null 2>&1 || { echo_error "Failed to add Helm repository '$REPO_NAME'."; exit 1; }
    else
        echo_detail "Helm repository '$REPO_NAME' already exists. Skipping addition."
    fi
    echo_detail "Updating Helm repositories."
    helm repo update >/dev/null 2>&1 || { echo_error "Failed to update Helm repositories."; exit 1; }
}

# Function to ensure additional Helm repositories (ingress-nginx and jetstack) are added and updated
function ensure_additional_helm_repos() {
    # Adding ingress-nginx Helm repository
    REPO_NAME="ingress-nginx"
    REPO_URL="https://kubernetes.github.io/ingress-nginx"

    if ! helm repo list | grep -q "^$REPO_NAME "; then
        echo_detail "Adding Helm repository '$REPO_NAME'."
        helm repo add "$REPO_NAME" "$REPO_URL" >/dev/null 2>&1 || { echo_error "Failed to add Helm repository '$REPO_NAME'."; exit 1; }
    else
        echo_detail "Helm repository '$REPO_NAME' already exists. Skipping addition."
    fi

    # Adding jetstack Helm repository
    REPO_NAME="jetstack"
    REPO_URL="https://charts.jetstack.io"

    if ! helm repo list | grep -q "^$REPO_NAME "; then
        echo_detail "Adding Helm repository '$REPO_NAME'."
        helm repo add "$REPO_NAME" "$REPO_URL" >/dev/null 2>&1 || { echo_error "Failed to add Helm repository '$REPO_NAME'."; exit 1; }
    else
        echo_detail "Helm repository '$REPO_NAME' already exists. Skipping addition."
    fi

    # Update Helm repositories
    echo_detail "Updating Helm repositories."
    helm repo update >/dev/null 2>&1 || { echo_error "Failed to update Helm repositories."; exit 1; }
}

# Function to display usage information
function usage() {
  echo_prompt "Usage: $0"
  echo_prompt ""
  echo_prompt "This script interactively guides you through the installation of OpenGovernance."
  echo_prompt "No additional parameters are required."
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

# Function to choose installation type in interactive mode with "?" capability
function choose_install_type() {
  echo_prompt ""
  echo_prompt "Select Installation Type:"
  echo_prompt "1) Install with HTTPS and Hostname (DNS records required after installation)"
  echo_prompt "2) Install with HTTP and Hostname (DNS records required after installation)"
  echo_prompt "3) Basic Install (No Ingress, use port-forwarding)"
  echo_prompt "Press 'q' or 'Q' to exit."

  while true; do
    echo_prompt -n "Enter your choice [Default: 1] (Press '?' for descriptions, 'q' to quit): "
    read -r choice < /dev/tty

    # Handle "?" input to show descriptions
    if [[ "$choice" == "?" ]]; then
      echo_prompt ""
      echo_prompt "Installation Type Descriptions:"
      echo_prompt "1) Install with HTTPS and Hostname: Sets up OpenGovernance with HTTPS enabled and associates it with a specified hostname. Requires DNS records to point to the cluster."
      echo_prompt "2) Install with HTTP and Hostname: Sets up OpenGovernance with HTTP enabled and associates it with a specified hostname. Requires DNS records to point to the cluster."
      echo_prompt "3) Basic Install: Installs OpenGovernance without configuring an Ingress Controller. Access is managed through port-forwarding."
      echo_prompt "Press 'q' or 'Q' to exit."
      echo_prompt ""
      continue  # Re-prompt after displaying descriptions
    fi

    # Handle 'q' or 'Q' to quit
    if [[ "$choice" =~ ^[qQ]$ ]]; then
      echo_info "Exiting the script."
      exit 0
    fi

    # If no choice is made, default to 1
    choice=${choice:-1}

    # Ensure the choice is within 1,2,3
    if ! [[ "$choice" =~ ^[1-3]$ ]]; then
      echo_prompt "Invalid option. Please enter a valid number, '?', or 'q' to quit."
      continue
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
      echo "Install with HTTP and Hostname (DNS records required after installation)"
      ;;
    3)
      echo "Basic Install (No Ingress, use port-forwarding)"
      ;;
    *)
      echo "Unknown"
      ;;
  esac
}

# Function to detect Kubernetes provider and set context information
function detect_kubernetes_provider_and_set_context() {
    # Initialize NODE_COUNT to "Unknown"
    NODE_COUNT="Unknown"

    local cluster_info
    cluster_info=$(get_cluster_info) || true

    NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ -z "$NODE_COUNT" ]]; then
        NODE_COUNT="Unknown"
    fi

    CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null) || true
    if [[ -n "$CURRENT_CONTEXT" ]]; then
        CURRENT_CLUSTER_NAME=$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$CURRENT_CONTEXT\")].context.cluster}")
        cluster_server=$(kubectl config view -o jsonpath="{.clusters[?(@.name==\"$CURRENT_CLUSTER_NAME\")].cluster.server}")
        cluster_info="$cluster_info $CURRENT_CONTEXT $CURRENT_CLUSTER_NAME $cluster_server"
    fi

    if [[ -z "$cluster_info" ]]; then
        echo_primary "Unable to retrieve cluster information."
        CURRENT_PROVIDER="Unknown"
        return
    fi

    echo_info "Cluster control plane information: $cluster_info"

    case "$cluster_info" in
        *".k8s.ondigitalocean.com"*|*"digitalocean"*|*"do-"*)
            echo_info "Detected DigitalOcean Kubernetes cluster."
            CURRENT_PROVIDER="DigitalOcean"
            ;;
        *)
            echo_info "Unable to identify Kubernetes provider. Treating as Unknown."
            CURRENT_PROVIDER="Unknown"
            ;;
    esac
}

# Function to remove existing kubectl context if connected to any cluster
function remove_existing_kubectl_context() {
  local current_context
  current_context=$(kubectl config current-context 2>/dev/null)

  if [[ -n "$current_context" ]]; then
    echo_primary "Removing current kubectl context: $current_context"
    kubectl config delete-context "$current_context" || { echo_error "Failed to delete context '$current_context'."; exit 1; }
    echo_info "Context '$current_context' removed."
  else
    echo_info "No existing kubectl context found."
  fi
}

# Function to prompt the user for domain and email
function prompt_domain_and_email() {
  # Prompt for domain
  while true; do
    echo_prompt -n "Enter your domain for OpenGovernance: "
    read DOMAIN < /dev/tty
    if [ -z "$DOMAIN" ]; then
      echo_error "Domain is required for installation types 1 and 2."
      continue
    fi
    validate_domain
    break
  done

  # Prompt for email only if HTTPS is enabled
  if [ "$ENABLE_HTTPS" = true ]; then
    while true; do
      echo_prompt -n "Enter your email for Let's Encrypt: "
      read EMAIL < /dev/tty
      if [ -z "$EMAIL" ]; then
        echo_error "Email is required for HTTPS installation."
        continue
      fi
      validate_email
      break
    done
  fi
}

# Function to create a DigitalOcean Kubernetes cluster
function create_digitalocean_cluster() {
    while true; do
        echo_prompt -n "Enter the name for the new DigitalOcean Kubernetes cluster: "
        read -r new_cluster_name < /dev/tty

        # Check if the cluster name is empty
        if [[ -z "$new_cluster_name" ]]; then
            echo_error "Cluster name cannot be empty. Please enter a valid name."
            continue
        fi

        # Check if the cluster name already exists
        if doctl kubernetes cluster get "$new_cluster_name" >/dev/null 2>&1; then
            echo_error "A Kubernetes cluster named '$new_cluster_name' already exists. Please choose a different name."
            continue
        fi

        # Optional: Validate cluster name format
        if [[ ! "$new_cluster_name" =~ ^[a-z0-9-]+$ ]]; then
            echo_error "Invalid cluster name format. Use only lowercase letters, numbers, and hyphens."
            continue
        fi

        # Prompt to change the default region
        echo_primary "Current default region is '$DIGITALOCEAN_REGION'."
        echo_prompt -n "Do you wish to change the region? (y/n, auto-proceeds with 'n' in 30 seconds): "
        read -t 30 -r change_region < /dev/tty || change_region="n"  # Default to "n" if timeout occurs

        # Set change_region to "n" if input is empty or explicitly "n"
        if [[ -z "$change_region" || "$change_region" =~ ^([nN])$ ]]; then
            change_region="n"
        fi

        # If user chooses "y" to change the region, display available regions
        if [[ "$change_region" =~ ^([yY])$ ]]; then
            # Retrieve available regions
            echo_info "Fetching available DigitalOcean regions..."
            AVAILABLE_REGIONS=$(doctl kubernetes options regions | awk 'NR>1 {print $1}')

            if [[ -z "$AVAILABLE_REGIONS" ]]; then
                echo_error "Failed to retrieve available regions. Please ensure 'doctl' is authenticated and has the necessary permissions."
                exit 1
            fi

            echo_primary "Available Regions:"
            echo "$AVAILABLE_REGIONS" | nl -w2 -s'. '

            while true; do
                echo_prompt -n "Enter the desired region from the above list [Default: $DIGITALOCEAN_REGION]: "
                read -r input_region < /dev/tty

                # Use default if input is empty
                if [[ -z "$input_region" ]]; then
                    selected_region="$DIGITALOCEAN_REGION"
                else
                    selected_region="$input_region"
                fi

                # Validate the selected region
                if echo "$AVAILABLE_REGIONS" | grep -qw "$selected_region"; then
                    DIGITALOCEAN_REGION="$selected_region"
                    echo_info "Region set to '$DIGITALOCEAN_REGION'."
                    break
                else
                    echo_error "Invalid region selection. Please choose a region from the available list."
                fi
            done
        else
            echo_info "Using default region '$DIGITALOCEAN_REGION'."
        fi

        # Confirm the details
        echo_primary "Creating DigitalOcean Kubernetes cluster '$new_cluster_name' in region '$DIGITALOCEAN_REGION'..."
        echo_primary "This step may take 3-5 minutes."

        # Create the cluster
        if doctl kubernetes cluster create "$new_cluster_name" --region "$DIGITALOCEAN_REGION" \
            --node-pool "name=main-pool;size=g-4vcpu-16gb-intel;count=3" --wait; then
            echo_info "Cluster '$new_cluster_name' created successfully."
        else
            echo_error "Failed to create cluster '$new_cluster_name'. Please try again."
            continue
        fi

        # Save kubeconfig for the cluster
        if ! doctl kubernetes cluster kubeconfig save "$new_cluster_name"; then
            echo_error "Failed to retrieve kubeconfig for cluster '$new_cluster_name'."
            exit 1
        fi

        # Update the global cluster name variable
        KUBE_CLUSTER_NAME="$new_cluster_name"

        # Execute the DigitalOcean post-install configuration script
        echo_primary "Fetching and executing the post-install configuration script for DigitalOcean."
        curl -sL https://raw.githubusercontent.com/opengovern/deploy-opengovernance/main/digitalocean/scripts/post-install-config.sh | bash
        echo_primary "Post-install configuration for DigitalOcean executed successfully."

        # Exit the loop after successful creation and installation
        break
    done
}

# Function to check prerequisites and handle cluster creation if necessary
function check_prerequisites() {
  # Remove any existing kubectl context
  remove_existing_kubectl_context

  # Check if doctl is installed
  CLI_NAME="doctl"
  if command -v "$CLI_NAME" &> /dev/null; then
      echo_info "$CLI_NAME is installed."
  else
      echo_error "$CLI_NAME is not installed."
      echo_primary "Please install $CLI_NAME and configure it before proceeding."
      echo_prompt ""
      echo_prompt "You can install doctl by following the instructions here:"
      echo_prompt "  https://docs.digitalocean.com/reference/doctl/how-to/install/"
      echo_prompt ""
      exit 1
  fi

  # Check if doctl is configured
  if doctl account get > /dev/null 2>&1; then
      echo_info "$CLI_NAME is configured."
  else
      echo_error "$CLI_NAME is not configured properly."
      echo_primary "Please configure $CLI_NAME before proceeding."
      exit 1
  fi

  # Create a new DigitalOcean cluster
  create_digitalocean_cluster

  # Detect the current Kubernetes provider
  detect_kubernetes_provider_and_set_context

  if [[ "$CURRENT_PROVIDER" != "DigitalOcean" ]]; then
      echo_error "kubectl is not connected to a DigitalOcean-managed Kubernetes cluster after cluster creation."
      exit 1
  fi

  # Check if Helm is installed
  if ! command -v helm &> /dev/null; then
    echo_error "Helm is not installed. Please install Helm and try again."
    exit 1
  fi

  # Check if there are at least three ready nodes
  check_ready_nodes

  echo_info "Checking Prerequisites...Completed"
}

# Function to check if there are at least three ready nodes, retrying every 30 seconds for up to 5 minutes
function check_ready_nodes() {
  local attempts=0
  local max_attempts=10  # 10 attempts * 30 seconds = 5 minutes
  local sleep_time=30

  while [ $attempts -lt $max_attempts ]; do
    READY_NODES=$(kubectl get nodes --no-headers | grep -c ' Ready ')
    if [ "$READY_NODES" -ge 3 ]; then
      echo_info "Required nodes are ready. ($READY_NODES nodes)"
      return 0
    fi

    attempts=$((attempts + 1))
    echo_detail "Waiting for nodes to become ready... ($attempts/$max_attempts)"
    sleep $sleep_time
  done

  echo_error "At least three Kubernetes nodes must be ready, but only $READY_NODES node(s) are ready after 5 minutes."
  exit 1
}

# Function to check OpenGovernance health status
function check_opengovernance_health() {
  # Check the health of the OpenGovernance deployment
  local unhealthy_pods
  # Extract the STATUS column (3rd column) and exclude 'Running' and 'Completed'
  unhealthy_pods=$(kubectl get pods -n "$KUBE_NAMESPACE" --no-headers | awk '{print $3}' | grep -v -E 'Running|Completed' || true)

  if [ -z "$unhealthy_pods" ]; then
    APP_HEALTHY=true
  else
    echo_error "Some OpenGovernance pods are not healthy."
    kubectl get pods -n "$KUBE_NAMESPACE"
    APP_HEALTHY=false
  fi
}

# Function to check OpenGovernance readiness
function check_opengovernance_readiness() {
  # Check the readiness of all pods in the specified namespace
  local not_ready_pods
  # Extract the STATUS column (3rd column) and exclude 'Running' and 'Completed'
  not_ready_pods=$(kubectl get pods -n "$KUBE_NAMESPACE" --no-headers | awk '{print $3}' | grep -v -E 'Running|Completed' || true)

  if [ -z "$not_ready_pods" ]; then
    APP_HEALTHY=true
  else
    echo_error "Some OpenGovernance pods are not healthy."
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

# Function to install OpenGovernance (handles both HTTPS and HTTP with Ingress)
function install_opengovernance() {
  local install_type="$1"  # Expected to be 1, 2, or 3

  case "$install_type" in
    1)
      local use_https=true
      ;;
    2)
      local use_https=false
      ;;
    3)
      local use_https=false
      ;;
    *)
      echo_error "Unsupported installation type: $install_type"
      exit 1
      ;;
  esac

  if [ "$use_https" = true ]; then
    echo_primary "Proceeding with OpenGovernance installation with HTTPS and Hostname. (Expected time: 7-10 minutes)"
  else
    if [ "$install_type" -eq 3 ]; then
      echo_primary "Proceeding with OpenGovernance Basic Install (No Ingress). (Expected time: 7-10 minutes)"
    else
      echo_primary "Proceeding with OpenGovernance installation with HTTP and Hostname. (Expected time: 7-10 minutes)"
    fi
  fi

  # Ensure OpenGovernance Helm repository is added and updated
  ensure_helm_repo

  # Ensure additional Helm repositories are added and updated
  ensure_additional_helm_repos

  # Prepare Helm values based on installation type
  if [ "$use_https" = true ]; then
    HELM_VALUES=$(cat <<EOF
global:
  domain: ${DOMAIN}
dex:
  config:
    issuer: https://${DOMAIN}/dex
EOF
)
  else
    HELM_VALUES=$(cat <<EOF
global:
  domain: ${DOMAIN:-localhost}
dex:
  config:
    issuer: http://${DOMAIN:-localhost}/dex
EOF
)
  fi

  # Perform Helm installation with appropriate configuration
  echo_detail "Performing Helm installation with custom configuration."

  helm_quiet install opengovernance opengovernance/opengovernance -n "$KUBE_NAMESPACE" --create-namespace --timeout=10m --wait \
    -f - <<< "$HELM_VALUES"

  if [ $? -ne 0 ]; then
    echo_error "Helm installation failed."
    return 1
  fi

  echo_detail "OpenGovernance installation completed."
  echo_detail "Application Installed successfully."

  return 0
}

# Function to setup Cert-Manager and Issuer, and setup Ingress Controller with IP wait
function setup_cert_manager_ingress_controller() {
  echo_primary "Setting up Cert-Manager and Ingress Controller. (Expected time: 3-7 minutes)"

  # Setup Cert-Manager and Issuer
  setup_cert_manager_and_issuer

  # Setup Ingress Controller and wait for external IP
  setup_ingress_controller_with_ip_wait
}

# Function to setup Cert-Manager and Issuer
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
    return 1
  }

  # Check if Cert-Manager is already installed
  if is_cert_manager_installed; then
    echo_detail "Cert-Manager is already installed. Skipping installation."
  else
    echo_detail "Installing Cert-Manager via Helm."
    helm_quiet install cert-manager jetstack/cert-manager -n cert-manager --create-namespace --version v1.11.0 --set installCRDs=true --wait || { echo_error "Failed to install Cert-Manager."; return 1; }
    echo_detail "Cert-Manager installed."
  fi

  # Apply ClusterIssuer for Let's Encrypt only if HTTPS is enabled
  if [ "$ENABLE_HTTPS" = true ]; then
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
  else
    echo_detail "HTTPS is not enabled. Skipping ClusterIssuer setup."
  fi
}

# Function to setup Ingress Controller and wait for external IP
function setup_ingress_controller_with_ip_wait() {
  echo_primary "Setting up Ingress Controller and waiting for external IP. (Expected time: 2-5 minutes)"

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
    helm_quiet install ingress-nginx ingress-nginx/ingress-nginx -n "$KUBE_NAMESPACE" --create-namespace --wait || { echo_error "Failed to install ingress-nginx."; return 1; }
    echo_detail "Ingress Controller installed."
  fi

  # Wait for ingress-nginx controller to obtain an external IP (up to 6 minutes) only if Ingress is used
  if [ "$INSTALL_TYPE" -eq 1 ] || [ "$INSTALL_TYPE" -eq 2 ]; then
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
  return 1
}

# Function to deploy Ingress resources
# Now accepts a parameter to determine HTTPS or HTTP
function deploy_ingress_resources() {
  local use_https="$1"

  if [ "$use_https" = true ]; then
    echo_primary "Deploying Ingress with HTTPS. (Expected time: 1-3 minutes)"
    INGRESS_YAML=$(cat <<EOF
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
)
  else
    echo_primary "Deploying Ingress without TLS. (Expected time: 1-3 minutes)"
    INGRESS_YAML=$(cat <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: opengovernance-ingress
spec:
  ingressClassName: nginx
  rules:
    - host: ${DOMAIN:-localhost}
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
)
  fi

  echo_detail "Applying Ingress configuration."
  echo "$INGRESS_YAML" | kubectl apply -n "$KUBE_NAMESPACE" -f - || { echo_error "Failed to deploy Ingress resources."; return 1; }

  echo_detail "Ingress resources deployed."
  return 0
}

# Function to provide port-forward instructions based on conditions
# Merged into display_completion
function display_completion() {
  local install_type="$1"
  local protocol="http"

  if [[ "$install_type" -eq 1 ]]; then
    protocol="https"
  elif [[ "$install_type" -eq 2 ]]; then
    protocol="http"
  elif [[ "$install_type" -eq 3 ]]; then
    protocol="http"
  fi

  echo_primary "Installation Complete"

  echo_prompt ""
  echo_prompt "-----------------------------------------------------"
  echo_prompt "OpenGovernance has been successfully installed and configured."
  echo_prompt ""
  
  if [ "$install_type" -eq 1 ] || [ "$install_type" -eq 2 ]; then
    echo_prompt "Access your OpenGovernance instance at: ${protocol}://${DOMAIN}"
  elif [ "$install_type" -eq 3 ]; then
    echo_prompt "Access your OpenGovernance instance at: ${protocol}://localhost:8080"
  fi
  echo_prompt ""
  echo_prompt "To sign in, use the following default credentials:"
  echo_prompt "  Username: admin@opengovernance.io"
  echo_prompt "  Password: password"
  echo_prompt ""

  # DNS A record setup instructions if domain is configured and Ingress is used
  if [ -n "$DOMAIN" ] && ([ "$install_type" -eq 1 ] || [ "$install_type" -eq 2 ]); then
    echo_prompt "To ensure proper access to your instance, please verify or set up the following DNS A records:"
    echo_prompt ""
    echo_prompt "  Domain: ${DOMAIN}"
    echo_prompt "  Record Type: A"
    echo_prompt "  Value: ${INGRESS_EXTERNAL_IP}"
    echo_prompt ""
    echo_prompt "Note: It may take some time for DNS changes to propagate."
  fi

  # Provide port-forward instructions if Ingress is not properly configured or it's a Basic Install
  if ([ "$install_type" -eq 1 ] || [ "$install_type" -eq 2 ]) && [ -z "$INGRESS_EXTERNAL_IP" ]; then
    echo_error "Ingress Controller is not properly configured."
    echo_prompt "You can access OpenGovernance using port-forwarding as follows:"
    echo_prompt "kubectl port-forward -n $KUBE_NAMESPACE service/nginx-proxy 8080:80"
    echo_prompt "Then, access it at http://localhost:8080"
    echo_prompt ""
    echo_prompt "To sign in, use the following default credentials:"
    echo_prompt "  Username: admin@opengovernance.io"
    echo_prompt "  Password: password"
  elif [ "$install_type" -eq 3 ]; then
    echo_prompt "You can access OpenGovernance using port-forwarding as follows:"
    echo_prompt "kubectl port-forward -n $KUBE_NAMESPACE service/nginx-proxy 8080:80"
    echo_prompt "Then, access it at http://localhost:8080"
    echo_prompt ""
    echo_prompt "To sign in, use the following default credentials:"
    echo_prompt "  Username: admin@opengovernance.io"
    echo_prompt "  Password: password"
  fi

  echo_prompt "-----------------------------------------------------"
}

# Function to run installation logic
function run_installation_logic() {
  # Prompt for installation type
  choose_install_type

  # If Install Type 1 or 2, prompt for domain and email as needed
  if [ "$INSTALL_TYPE" -eq 1 ] || [ "$INSTALL_TYPE" -eq 2 ]; then
    prompt_domain_and_email
  fi

  # Perform installation based on INSTALL_TYPE
  if [ "$INSTALL_TYPE" -eq 1 ] || [ "$INSTALL_TYPE" -eq 2 ]; then
    setup_cert_manager_ingress_controller
    install_opengovernance "$INSTALL_TYPE" || { 
      if [ "$INSTALL_TYPE" -eq 1 ]; then
        echo_error "HTTPS installation failed. Proceeding with HTTP installation."
        # Attempt HTTP installation for Type 1
        ENABLE_HTTPS=false
        install_opengovernance 2 || { 
          echo_error "HTTP installation also failed. Exiting."
          exit 1 
        }
      elif [ "$INSTALL_TYPE" -eq 2 ]; then
        echo_error "HTTP installation failed. Exiting."
        exit 1 
      fi
    }
    deploy_ingress_resources "$ENABLE_HTTPS"
    check_pods_and_jobs
    DEPLOY_SUCCESS=true
  elif [ "$INSTALL_TYPE" -eq 3 ]; then
    # Basic Install does not require HTTPS setup
    install_opengovernance 3 || { 
      echo_error "Basic installation failed."
      exit 1 
    }
    deploy_ingress_resources false
    check_pods_and_jobs
    DEPLOY_SUCCESS=true
  else
    echo_error "Unsupported installation type: $INSTALL_TYPE"
    exit 1
  fi

  # Display completion message or provide port-forward instructions
  if [ "$DEPLOY_SUCCESS" = true ]; then
    display_completion "$INSTALL_TYPE"
  else
    echo_error "Deployment was not successful."
    exit 1
  fi
}

# -----------------------------
# Main Execution Flow
# -----------------------------

check_prerequisites
run_installation_logic
