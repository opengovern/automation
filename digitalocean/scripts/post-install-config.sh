#!/usr/bin/env bash

# -----------------------------
# Script Configuration
# -----------------------------

# Enable strict mode
set -euo pipefail

# Trap for unexpected exits
trap 'echo_error "Script terminated unexpectedly."; exit 1' INT TERM ERR

# Default Kubernetes namespace for OpenGovernance
DEFAULT_KUBE_NAMESPACE="opengovernance"

# Data directory for OpenGovernance
DATA_DIR="$HOME/opengovernance_data"

# Log file location
LOGFILE="$DATA_DIR/opengovernance_install.log"

# Ensure the data directory exists
mkdir -p "$DATA_DIR"

# Redirect all output to the log file and console
exec > >(tee -a "$LOGFILE") 2>&1

# Open file descriptor 3 for appending to the log file only
exec 3>> "$LOGFILE"

# -----------------------------
# Function Definitions
# -----------------------------

# Function to display messages directly to the user
echo_prompt() {
    echo "$@" > /dev/tty
}

# Function to display informational messages to the log with timestamp
echo_info() {
    local message="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $message" >&3
}

# Function to display error messages to console and log with timestamp
echo_error() {
    local message="$1"
    echo_prompt "Error: $message"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $message" >&3
}

# Function to display primary messages to both console and log with timestamp
echo_primary() {
    local message="$1"
    echo_prompt "$message"
    echo_info "$message"
}

# Function to display detail messages to both console and log with timestamp, indented with 4 spaces
echo_detail() {
    local message="$1"
    local indent="    "  # 4 spaces
    echo_prompt "${indent}${message}"
    echo_info "${indent}${message}"
}

# Function to redirect Helm commands to the log only, always with --debug
helm_quiet() {
    helm --debug "$@" >&3 2>&1
}

# Function to check if a command exists
command_exists() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1
}

# Function to display usage information
usage() {
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

# Function to parse command-line arguments
parse_args() {
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
            if [ -n "${DOMAIN:-}" ] && [ -n "${EMAIL:-}" ]; then
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
                ENABLE_HTTPS=true
                ;;
            2|3)
                ENABLE_HTTPS=false
                ;;
            *)
                echo_error "Unsupported installation type: $INSTALL_TYPE"
                usage
                ;;
        esac
    fi
}

# Function to choose installation type in interactive mode
choose_install_type() {
    if [ "$INSTALL_TYPE_SPECIFIED" = true ]; then
        # Installation type already specified; no need to prompt
        return
    fi

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
get_inline_install_type_description() {
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

# Function to configure email and domain with validation and confirmation
configure_email_and_domain() {
    # Function to prompt for confirmation with 30-second timeout
    confirm_proceed() {
        echo_prompt ""
        echo_prompt "Please review the entered details:"
        echo_prompt "  Domain: $DOMAIN"
        echo_prompt "  Email: $EMAIL"
        echo_prompt ""
        echo_prompt "Press Enter to confirm and proceed, or wait 30 seconds to auto-proceed."
        read -t 30 -p "" user_input
        echo_info "User confirmed or auto-proceeded."
    }

    # Function to handle invalid input
    handle_invalid_input() {
        while true; do
            echo_prompt "Do you want to:"
            echo_prompt "1) Re-enter the details"
            echo_prompt "2) Change the installation type"
            echo_prompt "3) Exit"
            echo_prompt -n "Select an option (1-3): "
            read option < /dev/tty

            case $option in
                1)
                    # Re-enter the details
                    configure_email_and_domain
                    ;;
                2)
                    # Change the installation type
                    choose_install_type
                    configure_email_and_domain
                    ;;
                3)
                    # Exit the script
                    echo_info "Exiting the script."
                    exit 0
                    ;;
                *)
                    echo_prompt "Invalid option. Please select 1, 2, or 3."
                    ;;
            esac
        done
    }

    # Depending on the installation type, prompt for DOMAIN and EMAIL as needed
    case $INSTALL_TYPE in
        1)
            # Install with HTTPS and Hostname
            if [ "$SILENT_INSTALL" = false ]; then
                # Prompt for DOMAIN if not provided
                if [ -z "${DOMAIN:-}" ]; then
                    while true; do
                        echo_prompt -n "Enter your domain for OpenGovernance: "
                        read DOMAIN < /dev/tty
                        if [[ "$DOMAIN" =~ ^(([a-zA-Z0-9](-*[a-zA-Z0-9])*)\.)+[a-zA-Z]{2,}$ ]]; then
                            break
                        else
                            echo_error "Invalid domain: '$DOMAIN'. Please enter a valid domain."
                            handle_invalid_input
                        fi
                    done
                else
                    # Validate the provided DOMAIN
                    if ! [[ "$DOMAIN" =~ ^(([a-zA-Z0-9](-*[a-zA-Z0-9])*)\.)+[a-zA-Z]{2,}$ ]]; then
                        echo_error "Invalid domain: '$DOMAIN'."
                        handle_invalid_input
                    fi
                fi

                # Prompt for EMAIL if not provided
                if [ -z "${EMAIL:-}" ]; then
                    while true; do
                        echo_prompt -n "Enter your email for Let's Encrypt: "
                        read EMAIL < /dev/tty
                        if [[ "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
                            break
                        else
                            echo_error "Invalid email: '$EMAIL'. Please enter a valid email address."
                            handle_invalid_input
                        fi
                    done
                else
                    # Validate the provided EMAIL
                    if ! [[ "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
                        echo_error "Invalid email: '$EMAIL'."
                        handle_invalid_input
                    fi
                fi
            fi
            ;;
        2)
            # Install without HTTPS
            if [ "$SILENT_INSTALL" = false ]; then
                # Prompt for DOMAIN if not provided
                if [ -z "${DOMAIN:-}" ]; then
                    while true; do
                        echo_prompt -n "Enter your domain for OpenGovernance: "
                        read DOMAIN < /dev/tty
                        if [[ "$DOMAIN" =~ ^(([a-zA-Z0-9](-*[a-zA-Z0-9])*)\.)+[a-zA-Z]{2,}$ ]]; then
                            break
                        else
                            echo_error "Invalid domain: '$DOMAIN'. Please enter a valid domain."
                            handle_invalid_input
                        fi
                    done
                else
                    # Validate the provided DOMAIN
                    if ! [[ "$DOMAIN" =~ ^(([a-zA-Z0-9](-*[a-zA-Z0-9])*)\.)+[a-zA-Z]{2,}$ ]]; then
                        echo_error "Invalid domain: '$DOMAIN'."
                        handle_invalid_input
                    fi
                fi
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

    # If in interactive mode and installation type requires DOMAIN and EMAIL, confirm the details
    if [ "$SILENT_INSTALL" = false ] && [ "$INSTALL_TYPE" -eq 1 ]; then
        confirm_proceed
    fi
}

# Function to check if OpenGovernance is installed and healthy
check_opengovernance_installation() {
    # Check if OpenGovernance is installed
    if helm ls -n "$KUBE_NAMESPACE" | grep -qw opengovernance; then
        echo_info "OpenGovernance is already installed."
        local unhealthy_pods
        # Exclude pods that have 'Completed' in their status
        unhealthy_pods=$(kubectl get pods -n "$KUBE_NAMESPACE" --no-headers | awk '{print $3}' | grep -v -E 'Running|Completed' || true)
        if [ -z "$unhealthy_pods" ]; then
            echo_info "OpenGovernance is healthy."
            # Do not display this information to the console, only log it
            return 1  # Return 1 to indicate that installation should proceed
        else
            echo_info "OpenGovernance pods are not all healthy. Proceeding to reconfigure."
            return 1  # Return 1 to indicate that installation should proceed
        fi
    else
        echo_info "OpenGovernance is not installed."
        return 1  # Return 1 to indicate that installation should proceed
    fi
}

# Function to check prerequisites
check_prerequisites() {
    # Check if kubectl is installed
    if ! command_exists kubectl; then
        echo_error "kubectl is not installed. Please install kubectl and try again."
        exit 1
    fi

    # Check if kubectl is connected to a cluster
    if ! kubectl cluster-info > /dev/null 2>&1; then
        echo_error "kubectl is not connected to a cluster."
        exit 1
    fi

    # Check if Helm is installed
    if ! command_exists helm; then
        echo_error "Helm is not installed. Please install Helm and try again."
        exit 1
    fi

    echo_info "Prerequisites check completed."
}

# Function to install or upgrade OpenGovernance via Helm
helm_upgrade_opengovernance() {
    echo_primary "Upgrading or installing OpenGovernance via Helm."
    echo_detail "Adding OpenGovernance Helm repository."
    helm_quiet repo add opengovernance https://opengovern.github.io/charts || true
    helm_quiet repo update >&3

    echo_detail "Performing Helm upgrade with custom configuration."

    case $INSTALL_TYPE in
        1)
            # Install with HTTPS and Hostname
            helm_quiet upgrade --install opengovernance opengovernance/opengovernance -n "$KUBE_NAMESPACE" --timeout=10m --wait \
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
            helm_quiet upgrade --install opengovernance opengovernance/opengovernance -n "$KUBE_NAMESPACE" --timeout=10m --wait \
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
            helm_quiet upgrade --install opengovernance opengovernance/opengovernance -n "$KUBE_NAMESPACE" --timeout=10m --wait \
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

# Function to check pods and jobs readiness
check_pods_and_jobs() {
    echo_detail "Waiting for application pods to be ready..."

    local attempts=0
    local max_attempts=12  # 12 attempts * 30 seconds = 6 minutes
    local sleep_time=30

    while [ $attempts -lt $max_attempts ]; do
        # Get pods that are not in Running or Completed status
        local not_ready_pods
        not_ready_pods=$(kubectl get pods -n "$KUBE_NAMESPACE" --no-headers | awk '{print $3}' | grep -v -E 'Running|Completed' || true)

        if [ -z "$not_ready_pods" ]; then
            echo_detail "All relevant OpenGovernance pods are ready."
            return 0
        fi

        attempts=$((attempts + 1))
        echo_detail "Waiting for pods to become ready... ($attempts/$max_attempts)"
        sleep $sleep_time
    done

    echo_error "OpenGovernance did not become ready within the expected time."
    exit 1
}

# Function to set up Ingress Controller
setup_ingress_controller() {
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
        helm_quiet repo update >&3
        helm_quiet install ingress-nginx ingress-nginx/ingress-nginx -n "$KUBE_NAMESPACE" --create-namespace --wait
        echo_detail "Ingress Controller installed."

        # Wait for ingress-nginx controller to obtain an external IP (up to 6 minutes)
        wait_for_ingress_ip "$KUBE_NAMESPACE"
    fi
}

# Function to wait for ingress-nginx controller to obtain an external IP
wait_for_ingress_ip() {
    local namespace="$1"
    local timeout=360  # 6 minutes
    local interval=30
    local elapsed=0

    echo_detail "Waiting for Ingress Controller to obtain an external IP... (Expected time: 2-5 minutes)"

    while [ $elapsed -lt $timeout ]; do
        EXTERNAL_IP=$(kubectl get svc ingress-nginx-controller -n "$namespace" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

        if [ -n "$EXTERNAL_IP" ]; then
            echo_detail "Ingress Controller external IP obtained: $EXTERNAL_IP"
            export INGRESS_EXTERNAL_IP="$EXTERNAL_IP"
            return 0
        fi

        echo_detail "Ingress Controller not ready yet. Retrying in $interval seconds... ($elapsed/$timeout)"
        sleep $interval
        elapsed=$((elapsed + interval))
    done

    echo_error "Ingress Controller did not obtain an external IP within the expected time."
    exit 1
}

# Function to deploy ingress resources
deploy_ingress_resources() {
    echo_primary "Deploying Ingress resources based on installation type."

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
setup_cert_manager_and_issuer() {
    echo_primary "Setting up Cert-Manager and Let's Encrypt Issuer. (Expected time: 1-2 minutes)"

    # Function to check if Cert-Manager is installed
    is_cert_manager_installed() {
        if helm_quiet list -A | grep -qw "cert-manager"; then
            return 0
        fi

        if kubectl get namespace cert-manager > /dev/null 2>&1 && kubectl get deployments -n cert-manager | grep -q "cert-manager"; then
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
        exit 1
    }

    # Check if Cert-Manager is already installed
    if is_cert_manager_installed; then
        echo_detail "Cert-Manager is already installed. Skipping installation."
    else
        echo_detail "Installing Cert-Manager via Helm."
        helm_quiet repo add jetstack https://charts.jetstack.io >&3
        helm_quiet repo update >&3
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
restart_pods() {
    echo_primary "Restarting OpenGovernance Pods to Apply Changes."

    # Restart only the specified deployments
    kubectl rollout restart deployment nginx-proxy -n "$KUBE_NAMESPACE"
    kubectl rollout restart deployment opengovernance-dex -n "$KUBE_NAMESPACE"

    echo_detail "Pods restarted successfully."
}

# Function to display completion message with protocol, DNS instructions, and default login details
display_completion_message() {
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
    if [ -n "${DOMAIN:-}" ] && [ "$INSTALL_TYPE" -ne 3 ]; then
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
run_installation_logic() {
    # Check if OpenGovernance is installed and healthy
    check_opengovernance_installation

    # If not in silent mode and INSTALL_TYPE was not specified, prompt for installation type
    if [ "$SILENT_INSTALL" = false ] && [ "$INSTALL_TYPE_SPECIFIED" = false ]; then
        echo_detail "Starting interactive installation type selection..."
        choose_install_type
    fi

    # Configure email and domain with validation and confirmation
    configure_email_and_domain

    # Set up Ingress Controller if Minimal Install
    if [ "$INSTALL_TYPE" -eq 3 ]; then
        setup_ingress_controller
    fi

    # Run Helm upgrade with appropriate parameters
    helm_upgrade_opengovernance

    # Wait for pods to be ready
    check_pods_and_jobs

    # Set up Ingress Controller if not Minimal Install
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

# -----------------------------
# Main Execution Flow
# -----------------------------

# Start the script
parse_args "$@"
check_prerequisites
run_installation_logic
