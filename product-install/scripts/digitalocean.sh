#!/usr/bin/env bash

# -----------------------------
# Script Configuration
# -----------------------------

# Enable strict mode
set -euo pipefail

# Trap for unexpected exits
trap 'echo_error "Script terminated unexpectedly."; exit 1' INT TERM HUP

# -----------------------------
# Configuration Variables
# -----------------------------

# Default Kubernetes namespace for OpenGovernance
KUBE_NAMESPACE="opengovernance"

# Default Kubernetes cluster name for OpenGovernance
DEFAULT_CLUSTER_NAME="opengovernance"

# Default DigitalOcean Kubernetes cluster region for OpenGovernance
DEFAULT_REGION="nyc3"

# Initialize DIGITALOCEAN_REGION with DEFAULT_REGION to prevent unbound variable error
DIGITALOCEAN_REGION="$DEFAULT_REGION"

# -----------------------------
# Logging Configuration
# -----------------------------

# Set DEBUG_MODE based on environment variable; default to false
DEBUG_MODE="${DEBUG_MODE:-false}"  # Helm operates in debug mode
LOGFILE="$HOME/.opengovernance/install.log"
DEBUG_LOGFILE="$HOME/.opengovernance/helm_debug.log"

# Create the log directories and files if they don't exist
LOGDIR="$(dirname "$LOGFILE")"
DEBUG_LOGDIR="$(dirname "$DEBUG_LOGFILE")"
mkdir -p "$LOGDIR" || { echo "Failed to create log directory at $LOGDIR."; exit 1; }
mkdir -p "$DEBUG_LOGDIR" || { echo "Failed to create debug log directory at $DEBUG_LOGDIR."; exit 1; }
touch "$LOGFILE" "$DEBUG_LOGFILE" || { echo "Failed to create log files."; exit 1; }

# -----------------------------
# Common Functions
# -----------------------------

# Function to display messages directly to the user
echo_prompt() {
    local no_newline=false

    # Check if the first argument is '-n'
    if [[ "$1" == "-n" ]]; then
        no_newline=true
        shift  # Remove '-n' from the arguments
    fi

    if $no_newline; then
        # Print without a newline
        printf "%s" "$*" > /dev/tty
    else
        # Print with a newline
        printf "%s\n" "$*" > /dev/tty
    fi
}

# Function to display informational messages to the log with timestamp
echo_info() {
    local message="$1"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    if [ "$DEBUG_MODE" = "true" ]; then
        printf "[DEBUG] %s\n" "$message" > /dev/tty
    fi
    printf "%s [INFO] %s\n" "$timestamp" "$message" >> "$LOGFILE"
}

# Function to display primary messages to both console and log with timestamp
echo_primary() {
    local message="$1"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    printf "%s\n" "$message" > /dev/tty
    printf "%s [INFO] %s\n" "$timestamp" "$message" >> "$LOGFILE"
}

# Function to display error messages to console and log with timestamp
echo_error() {
    local message="$1"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    printf "Error: %s\n" "$message" > /dev/tty
    printf "%s [ERROR] %s\n" "$timestamp" "$message" >> "$LOGFILE"
}

# Function to display detail messages with indentation
echo_detail() {
    local message="$1"
    local indent="    "  # 4 spaces
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    printf "%s\n" "${indent}${message}" > /dev/tty
    printf "%s [INFO] %s\n" "$timestamp" "${indent}${message}" >> "$LOGFILE"
}

# Function to run helm install commands with a timeout of 15 minutes
helm_install_with_timeout() {
    helm install "$@" --timeout=15m 2>&1 | tee -a "$DEBUG_LOGFILE" >> "$LOGFILE"
}

# Function to check if a command exists
check_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo_error "Required command '$cmd' is not installed."
        exit 1
    else
        echo_info "Command '$cmd' is installed."
    fi
}

# Function to ensure Helm repository is added and updated
ensure_helm_repo() {
    local REPO_NAME="$1"
    local REPO_URL="$2"

    if ! helm repo list | grep -q "^$REPO_NAME[[:space:]]"; then
        echo_detail "Adding Helm repository '$REPO_NAME'."
        helm repo add "$REPO_NAME" "$REPO_URL" >/dev/null 2>&1 || {
            echo_error "Failed to add Helm repository '$REPO_NAME'."
            exit 1
        }
    else
        echo_detail "Helm repository '$REPO_NAME' already exists. Skipping addition."
    fi
    echo_detail "Updating Helm repositories."
    helm repo update >/dev/null 2>&1 || {
        echo_error "Failed to update Helm repositories."
        exit 1
    }
}

# Function to ensure additional Helm repositories (ingress-nginx and jetstack) are added and updated
ensure_additional_helm_repos() {
    # Adding ingress-nginx Helm repository
    ensure_helm_repo "ingress-nginx" "https://kubernetes.github.io/ingress-nginx"

    # Adding jetstack Helm repository
    ensure_helm_repo "jetstack" "https://charts.jetstack.io"
}

# Function to check prerequisites
check_prerequisites() {
    local REQUIRED_COMMANDS=("kubectl" "helm" "jq" "curl" "doctl")

    echo_info "Checking for required tools..."

    # Check if each command is installed
    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        check_command "$cmd"
    done

    echo_info "All required tools are installed."

    # Ensure Helm repositories are added and updated
    ensure_helm_repo "opengovernance" "https://opengovern.github.io/charts/"
    ensure_additional_helm_repos

    echo_info "Checking Prerequisites...Completed"
}

# -----------------------------
# Additional Function Definitions
# -----------------------------

# Function to validate the domain
validate_domain() {
    local domain="$1"
    # Simple regex for domain validation
    if [[ "$domain" =~ ^(([a-zA-Z0-9](-*[a-zA-Z0-9])*)\.)+[a-zA-Z]{2,}$ ]]; then
        echo_info "Domain '$domain' is valid."
    else
        echo_error "Invalid domain: '$domain'. Please enter a valid domain."
        exit 1
    fi
}

# Function to validate the email
validate_email() {
    local email="$1"
    # Simple regex for email validation
    if [[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        echo_info "Email '$email' is valid."
    else
        echo_error "Invalid email: '$email'. Please enter a valid email address."
        exit 1
    fi
}

# Function to display installation type descriptions inline
get_inline_install_type_description() {
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

# Function to choose installation type in interactive mode with "?" capability
choose_install_type() {
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

        echo_prompt "You selected: $choice) $(get_inline_install_type_description "$choice")"
        break
    done

    # Inform user that installation will start shortly
    echo_primary "Installation will start in 5 seconds..."
    sleep 5
}

# Function to prompt the user for domain and email
prompt_domain_and_email() {
    # Prompt for domain
    while true; do
        echo_prompt -n "Enter your domain for OpenGovernance: "
        read -r DOMAIN < /dev/tty
        if [ -z "$DOMAIN" ]; then
            echo_error "Domain is required for installation types 1 and 2."
            continue
        fi
        validate_domain "$DOMAIN"
        break
    done

    # Prompt for email only if HTTPS is enabled
    if [ "$ENABLE_HTTPS" = true ]; then
        while true; do
            echo_prompt -n "Enter your email. This email will be used to generate a signed certificate with Let's Encrypt: "
            read -r EMAIL < /dev/tty
            if [ -z "$EMAIL" ]; then
                echo_error "Email is required for HTTPS installation."
                continue
            fi
            validate_email "$EMAIL"
            break
        done
    fi
}

# Function to detect Kubernetes provider and unset context
detect_kubernetes_provider_and_set_context() {
    # Retrieve the current Kubernetes context, suppressing any errors
    CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || true)

    if [ -n "$CURRENT_CONTEXT" ]; then
        echo_info "Current kubectl context: $CURRENT_CONTEXT"

        # Unset the current Kubernetes context
        if kubectl config unset current-context >/dev/null 2>&1; then
            echo_info "Successfully unset the current kubectl context."
        else
            echo_error "Failed to unset the current kubectl context."
        fi
    else
        echo_info "No kubectl context found."
    fi
}

# -----------------------------
# Function to create a DigitalOcean Kubernetes cluster
# -----------------------------
create_digitalocean_cluster() {
    local TIMEOUT=15

    # Display initial messages
    echo_primary "We will now create a new DigitalOcean Kubernetes cluster."

    # Check if the default cluster name is available
    echo_info "Checking availability of the default cluster name: '$DEFAULT_CLUSTER_NAME'."
    if doctl kubernetes cluster get "$DEFAULT_CLUSTER_NAME" >/dev/null 2>&1; then
        echo_error "The cluster name '$DEFAULT_CLUSTER_NAME' is already in use."
        echo_primary "Please enter a different cluster name."

        # Prompt the user to enter a different cluster name
        while true; do
            echo_prompt -n "Enter the name for the new DigitalOcean Kubernetes cluster: "
            read -r new_cluster_name < /dev/tty

            # Check if the cluster name is empty
            if [ -z "$new_cluster_name" ]; then
                echo_error "Cluster name cannot be empty. Please enter a valid name."
                continue
            fi

            # Check if the cluster name already exists
            if doctl kubernetes cluster get "$new_cluster_name" >/dev/null 2>&1; then
                echo_error "A Kubernetes cluster named '$new_cluster_name' already exists. Please choose a different name."
                continue
            fi

            # Validate cluster name format
            if ! [[ "$new_cluster_name" =~ ^[a-z0-9-]+$ ]]; then
                echo_error "Invalid cluster name format. Use only lowercase letters, numbers, and hyphens."
                continue
            fi

            # Assign the valid and unique cluster name
            KUBE_CLUSTER_NAME="$new_cluster_name"
            break
        done
    else
        # Default cluster name is available
        echo_info "The default cluster name '$DEFAULT_CLUSTER_NAME' is available."
        KUBE_CLUSTER_NAME="$DEFAULT_CLUSTER_NAME"
    fi

    # Display default region
    echo_primary "Default Region: '$DEFAULT_REGION'"

    # Prompt to change the default region with a 15-second timeout
    echo_prompt -n "Do you wish to change the region [Current: $DEFAULT_REGION]? (y/n, auto-proceeds with 'n' in $TIMEOUT seconds): "
    if read -t "$TIMEOUT" -r change_region < /dev/tty; then
        case "$change_region" in
            [yY]|[yY][eE][sS])
                # Retrieve available regions
                echo_info "Fetching available DigitalOcean regions..."
                AVAILABLE_REGIONS=$(doctl kubernetes options regions | awk 'NR>1 {print $1}')

                if [ -z "$AVAILABLE_REGIONS" ]; then
                    echo_error "Failed to retrieve available regions. Please ensure 'doctl' is authenticated and has the necessary permissions."
                    exit 1
                fi

                echo_primary "Available Regions:"
                echo "$AVAILABLE_REGIONS" | nl -w2 -s'. '

                # Prompt for region selection
                while true; do
                    echo_prompt -n "Select a region [Default: $DEFAULT_REGION]: "
                    read -r selected_region < /dev/tty
                    selected_region="${selected_region:-$DEFAULT_REGION}"

                    if echo "$AVAILABLE_REGIONS" | grep -qw "$selected_region"; then
                        DIGITALOCEAN_REGION="$selected_region"
                        echo_info "Region set to '$DIGITALOCEAN_REGION'."
                        break
                    else
                        echo_error "Invalid region selection. Please choose a region from the available list."
                    fi
                done
                ;;
            [nN]|[nN][oO])
                echo_info "Using default region '$DEFAULT_REGION'."
                DIGITALOCEAN_REGION="$DEFAULT_REGION"
                ;;
            *)
                echo_info "Invalid input received. Proceeding with default choice 'n'."
                echo_info "Using default region '$DEFAULT_REGION'."
                DIGITALOCEAN_REGION="$DEFAULT_REGION"
                ;;
        esac
    else
        echo_info "No input received within $TIMEOUT seconds. Proceeding with default choice 'n'."
        DIGITALOCEAN_REGION="$DEFAULT_REGION"
    fi

    # Final confirmation with cluster name and region, with a 15-second timeout
    echo_primary "Creating Kubernetes cluster with the following details in $TIMEOUT seconds. "
    echo_primary "  - Cluster Name: $KUBE_CLUSTER_NAME"
    echo_primary "  - Region: $DIGITALOCEAN_REGION"
    echo_prompt -n "Press 'n' to change; press 'y' or ENTER to start immediately"
    if read -t "$TIMEOUT" -r confirm < /dev/tty; then
        case "$confirm" in
            [nN][oO]|[nN])
                echo_info "Cluster creation aborted."
                exit 0
                ;;
            *)
                echo_info "Proceeding with cluster creation."
                ;;
        esac
    else
        echo_info "No input received within $TIMEOUT seconds. Proceeding with cluster creation."
    fi

    # Create the cluster
    echo_primary "Creating cluster '$KUBE_CLUSTER_NAME' in region '$DIGITALOCEAN_REGION'..."
    if doctl kubernetes cluster create "$KUBE_CLUSTER_NAME" --region "$DIGITALOCEAN_REGION" \
        --node-pool "name=main-pool;size=g-4vcpu-16gb-intel;count=3" --wait; then
        echo_info "Cluster '$KUBE_CLUSTER_NAME' created successfully."
    else
        echo_error "Failed to create cluster '$KUBE_CLUSTER_NAME'."
        exit 1
    fi

    # Save kubeconfig
    if doctl kubernetes cluster kubeconfig save "$KUBE_CLUSTER_NAME"; then
        echo_info "Kubeconfig for '$KUBE_CLUSTER_NAME' saved successfully."
    else
        echo_error "Failed to save kubeconfig for '$KUBE_CLUSTER_NAME'."
        exit 1
    fi

    echo_info "DigitalOcean Kubernetes cluster '$KUBE_CLUSTER_NAME' is set up and ready to use."
}

# -----------------------------
# Function to install OpenGovernance (handles both HTTPS and HTTP with Ingress)
# -----------------------------

install_opengovernance() {
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
        echo_primary "Proceeding with OpenGovernance installation with HTTPS and Hostname. (Expected time: 7-12 minutes)"
    else
        if [ "$install_type" -eq 3 ]; then
            echo_primary "Proceeding with OpenGovernance Basic Install (No Ingress). (Expected time: 7-12 minutes)"
        else
            echo_primary "Proceeding with OpenGovernance installation with HTTP and Hostname. (Expected time: 7-12 minutes)"
        fi
    fi

    # Prepare Helm values based on installation type
    local HELM_VALUES
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

    helm_install_with_timeout opengovernance opengovernance/opengovernance -n "$KUBE_NAMESPACE" --create-namespace --timeout=10m --wait \
        -f - <<< "$HELM_VALUES"

    if [ $? -ne 0 ]; then
        echo_error "Helm installation failed."
        return 1
    fi

    echo_detail "OpenGovernance installation completed."
    echo_detail "Application installed successfully."

    return 0
}

# -----------------------------
# Function to setup Cert-Manager and Issuer, and setup Ingress Controller with IP wait
# -----------------------------

setup_cert_manager_ingress_controller() {
    # Setup Cert-Manager and Issuer
    setup_cert_manager_and_issuer

    # Setup Ingress Controller and wait for external IP
    setup_ingress_controller_with_ip_wait
}

# Function to setup Cert-Manager and Issuer
setup_cert_manager_and_issuer() {
    echo_primary "Setting up Cert-Manager (Expected time: 1-2 minutes)"

    # Function to check if Cert-Manager is installed
    is_cert_manager_installed() {
        if helm list -n cert-manager | grep -qw "cert-manager"; then
            return 0
        fi

        if kubectl get namespace cert-manager >/dev/null 2>&1 && kubectl get deployments -n cert-manager | grep -q "cert-manager"; then
            return 0
        fi

        return 1
    }

    # Function to wait for the ClusterIssuer to be ready
    wait_for_clusterissuer_ready() {
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
        helm_install_with_timeout cert-manager jetstack/cert-manager -n cert-manager --create-namespace --version v1.11.0 --set installCRDs=true --wait || {
            echo_error "Failed to install Cert-Manager."
            return 1
        }
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
setup_ingress_controller_with_ip_wait() {
    echo_primary "Setting up Ingress Controller and waiting for external IP. (Expected time: 2-5 minutes)"

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
    if helm list -n "$KUBE_NAMESPACE" | grep -qw ingress-nginx; then
        echo_detail "Ingress Controller already installed. Skipping installation."
    else
        echo_detail "Starting Install of Ingress Controller ingress-nginx via Helm. (Expected time: 1-2 minutes)"
        helm_install_with_timeout ingress-nginx ingress-nginx/ingress-nginx -n "$KUBE_NAMESPACE" --create-namespace --wait || {
            echo_error "Failed to install ingress-nginx."
            return 1
        }
        echo_detail "Ingress Controller installed."
    fi

    # Wait for ingress-nginx controller to obtain an external IP (up to 6 minutes) only if Ingress is used
    if [ "$INSTALL_TYPE" -eq 1 ] || [ "$INSTALL_TYPE" -eq 2 ]; then
        wait_for_ingress_ip "$KUBE_NAMESPACE"
    fi
}

# Function to wait for ingress-nginx controller to obtain an external IP
wait_for_ingress_ip() {
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
deploy_ingress_resources() {
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
    echo "$INGRESS_YAML" | kubectl apply -n "$KUBE_NAMESPACE" -f - || {
        echo_error "Failed to deploy Ingress resources."
        return 1
    }

    echo_detail "Ingress resources deployed."
    return 0
}

# Function to display completion message
display_completion() {
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

# -----------------------------
# Function to run installation logic
# -----------------------------

run_installation_logic() {
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
        # Removed call to check_pods_and_jobs
        DEPLOY_SUCCESS=true
    elif [ "$INSTALL_TYPE" -eq 3 ]; then
        # Basic Install does not require HTTPS setup
        install_opengovernance 3 || {
            echo_error "Basic installation failed."
            exit 1
        }
        deploy_ingress_resources false
        # Removed call to check_pods_and_jobs
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

# Check for required tools before starting
check_prerequisites

# Detect Kubernetes provider and unset context
detect_kubernetes_provider_and_set_context

# Create DigitalOcean Kubernetes cluster
create_digitalocean_cluster

# Run installation logic
run_installation_logic
