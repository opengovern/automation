#!/bin/sh

# Enable strict error handling
set -eu

# -----------------------------
# Configuration Variables
# -----------------------------

# Repository URLs and Directories
REPO_URL="https://github.com/opengovern/deploy-opengovernance.git"
REPO_DIR="$HOME/.opengovernance/deploy-terraform"
INFRA_DIR="$REPO_DIR/aws/eks"

# Helm Chart Configuration
HELM_RELEASE="opengovernance"
HELM_CHART="opengovernance/opengovernance"  # Official Helm chart repository
REPO_NAME="opengovernance"
HELM_REPO_URL="https://opengovern.github.io/charts"

# Namespace
NAMESPACE="opengovernance"  # Default namespace

# -----------------------------
# Logging Configuration
# -----------------------------
DEBUG_MODE=false  # Set to true to enable debug mode
LOGFILE="$HOME/.opengovernance/install.log"

# Create the log directory if it doesn't exist
LOGDIR="$(dirname "$LOGFILE")"
mkdir -p "$LOGDIR" || { echo "Failed to create log directory at $LOGDIR."; exit 1; }

# Initialize the log file
touch "$LOGFILE" || { echo "Failed to create log file at $LOGFILE."; exit 1; }

# -----------------------------
# Trap for Unexpected Exits
# -----------------------------
trap 'echo_error "Script terminated unexpectedly."; exit 1' INT TERM HUP

# -----------------------------
# Common Functions
# -----------------------------

# Function to display messages directly to the user
echo_prompt() {
    printf "%s\n" "$*" > /dev/tty
}

# Function to display informational messages to console and log with timestamp
echo_info() {
    message="$1"
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    if [ "$DEBUG_MODE" = "true" ]; then
        printf "[DEBUG] %s\n" "$message" > /dev/tty
    fi
    printf "%s [INFO] %s\n" "$timestamp" "$message" >> "$LOGFILE"
}

# Function to display primary messages to console and log with timestamp
echo_primary() {
    message="$1"
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    printf "%s\n" "$message" > /dev/tty
    printf "%s [INFO] %s\n" "$timestamp" "$message" >> "$LOGFILE"
}

# Function to display error messages to console and log with timestamp
echo_error() {
    message="$1"
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    printf "Error: %s\n" "$message" > /dev/tty
    printf "%s [ERROR] %s\n" "$timestamp" "$message" >> "$LOGFILE"
}

# Function to display usage information
usage() {
    echo_primary "Usage: $0 [options]"
    echo_primary ""
    echo_primary "Options:"
    echo_primary "  -d, --domain <domain>    Specify the fully qualified domain for OpenGovernance (e.g., some.example.com)."
    echo_primary "  -t, --type <type>        Specify the installation type."
    echo_primary "                            Types:"
    echo_primary "                              1 - Install with HTTPS (requires a domain name)"
    echo_primary "                              2 - Basic Install (No Ingress, use port-forwarding)"
    echo_primary "  --debug                  Enable debug mode for detailed output."
    echo_primary "  -h, --help               Display this help message."
    exit 1
}

# Function to run helm commands with a timeout of 15 minutes
helm_install_with_timeout() {
    helm install "$@" --timeout=15m >> "$LOGFILE" 2>&1
}

# Function to check if a command exists
check_command() {
    cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo_error "Required command '$cmd' is not installed."
        exit 1
    else
        echo_info "Command '$cmd' is installed."
    fi
}

# Function to check if either Terraform or OpenTofu is installed
check_terraform_or_opentofu() {
    if command -v tofu >/dev/null 2>&1; then
        INFRA_BINARY="tofu"
        echo_info "OpenTofu is installed."
    elif command -v terraform >/dev/null 2>&1; then
        INFRA_BINARY="terraform"
        echo_info "Terraform is installed."
    else
        echo_error "Neither OpenTofu nor Terraform is installed. Please install one of them and retry."
        exit 1
    fi
}

# Function to check AWS CLI authentication
check_aws_auth() {
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        echo_error "AWS CLI is not configured or authenticated. Please run 'aws configure' and ensure you have the necessary permissions."
        exit 1
    fi
    echo_info "AWS CLI is authenticated."
}

# Function to check if kubectl is connected to a cluster
is_kubectl_active() {
    if ! kubectl cluster-info >/dev/null 2>&1; then
        echo_info "kubectl is not connected to any cluster."
        KUBECTL_ACTIVE="false"
        return 1
    else
        echo_info "kubectl is connected to a cluster."
        KUBECTL_ACTIVE="true"
        return 0
    fi
}

# Function to confirm the Kubernetes provider is AWS (EKS)
confirm_provider_is_eks() {
    CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || true)
    if [ -n "$CURRENT_CONTEXT" ]; then
        CURRENT_CLUSTER_NAME=$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$CURRENT_CONTEXT\")].context.cluster}")
        cluster_server=$(kubectl config view -o jsonpath="{.clusters[?(@.name==\"$CURRENT_CLUSTER_NAME\")].cluster.server}")
        case "$cluster_server" in
            *".eks.amazonaws.com"*|*"amazonaws.com"*)
                echo_info "Detected EKS (AWS) cluster."
                CURRENT_PROVIDER="AWS"
                return 0
                ;;
            *)
                echo_info "Detected non-EKS cluster."
                CURRENT_PROVIDER="OTHER"
                return 1
                ;;
        esac
    else
        echo_info "kubectl is not configured to any cluster."
        CURRENT_PROVIDER="NONE"
        return 1
    fi
}

# Function to check if there are at least three ready nodes
check_ready_nodes() {
    ready_nodes=$(kubectl get nodes --no-headers | grep -c ' Ready ')
    if [ "$ready_nodes" -lt 3 ]; then
        echo_error "At least three Kubernetes nodes must be ready. Currently, $ready_nodes node(s) are ready."
        return 1
    else
        echo_info "There are $ready_nodes ready nodes."
        return 0
    fi
}

# Function to determine if the current Kubernetes cluster is suitable for installation
is_cluster_suitable() {
    confirm_provider_is_eks
    if [ "$CURRENT_PROVIDER" = "AWS" ]; then
        if ! check_ready_nodes; then
            echo_error "Cluster does not have the required number of ready nodes."
            CLUSTER_SUITABLE="false"
            return 1
        fi

        if helm list -n "$NAMESPACE" | grep -q "^opengovernance\b"; then
            echo_info "OpenGovernance is already installed in namespace '$NAMESPACE'."
            CLUSTER_SUITABLE="false"
            return 1
        fi

        echo_info "Cluster is suitable for OpenGovernance installation."
        CLUSTER_SUITABLE="true"
        return 0
    else
        echo_info "Current Kubernetes cluster is not an EKS cluster."
        CLUSTER_SUITABLE="false"
        return 1
    fi
}

# Function to check prerequisites
check_prerequisites() {
    # List of required commands
    REQUIRED_COMMANDS="git kubectl aws jq helm"

    echo_info "Checking for required tools..."

    # Check if each command is installed
    for cmd in $REQUIRED_COMMANDS; do
        check_command "$cmd"
    done

    # Check for Terraform or OpenTofu
    check_terraform_or_opentofu

    # Check AWS CLI authentication
    check_aws_auth

    # Ensure Helm repository is added and updated
    ensure_helm_repo
    
    # Check if kubectl is connected to a cluster
    if is_kubectl_active; then
        # Determine if there is a suitable cluster
        if is_cluster_suitable; then
            echo_info "Cluster is suitable for installation."
        else
            echo_info "Cluster is not suitable for installation. Unsetting current kubectl context."
            kubectl config unset current-context || { 
                echo_error "Failed to unset the current kubectl context."
                exit 1
            }
            echo_error "Cluster is not suitable for installation. Exiting."
            exit 1
        fi
    else
        echo_info "kubectl is not connected to any cluster. Proceeding without cluster suitability checks."
    fi

    echo_info "Checking Prerequisites...Completed"
}

# Function to ensure the Helm repository is added and updated
ensure_helm_repo() {
    # Check if Helm is installed
    if command -v helm >/dev/null 2>&1; then
        echo_info "Ensuring Helm repository '$REPO_NAME' is added and up to date."

        # Check if the repository already exists
        if helm repo list | awk '{print $1}' | grep -q "^$REPO_NAME$"; then
            echo_info "Helm repository '$REPO_NAME' already exists."
        else
            # Add the repository
            echo_info "Adding Helm repository '$REPO_NAME'."
            helm repo add "$REPO_NAME" "$HELM_REPO_URL" >> "$LOGFILE" 2>&1 || { echo_error "Failed to add Helm repository '$REPO_NAME'."; exit 1; }
        fi

        # Update the Helm repositories
        echo_info "Updating Helm repositories."
        helm repo update >> "$LOGFILE" 2>&1 || { echo_error "Failed to update Helm repositories."; exit 1; }
    else
        echo_error "Helm is not installed."
        exit 1
    fi
}

# Function to display cluster metadata to the user
display_cluster_metadata() {
    echo_primary ""
    echo_primary "Cluster Metadata:"
    echo_primary "-----------------"

    # Get AWS Account ID
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
    if [ -n "$ACCOUNT_ID" ]; then
        echo_primary "AWS Account ID: $ACCOUNT_ID"
    else
        echo_primary "AWS Account ID: Unable to retrieve"
    fi

    # Get current context and cluster name
    CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null)
    if [ -n "$CURRENT_CONTEXT" ]; then
        CURRENT_CLUSTER_NAME=$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$CURRENT_CONTEXT\")].context.cluster}")
        # Extract the cluster name (last part of the cluster ARN)
        CLUSTER_NAME="${CURRENT_CLUSTER_NAME##*/}"
        echo_primary "Cluster Name: $CLUSTER_NAME"
    else
        echo_primary "Unable to determine current kubectl context."
    fi

    echo_primary "-----------------"
}

# -----------------------------
# Infrastructure Setup
# -----------------------------

deploy_infrastructure() {
    echo_info "Deploying infrastructure. This step may take 10-15 minutes..."
    echo_info "Ensuring infrastructure directory exists: $INFRA_DIR"
    mkdir -p "$INFRA_DIR" || { echo_error "Failed to create infrastructure directory at $INFRA_DIR."; exit 1; }

    echo_info "Navigating to infrastructure directory: $INFRA_DIR"
    cd "$INFRA_DIR" || { echo_error "Failed to navigate to $INFRA_DIR"; exit 1; }

    # Check for existing infrastructure
    if $INFRA_BINARY state list >> "$LOGFILE" 2>&1; then
        STATE_COUNT=$($INFRA_BINARY state list | wc -l | tr -d ' ')
        if [ "$STATE_COUNT" -gt 0 ]; then
            echo_prompt "Existing infrastructure detected. Do you want to (c)lean up existing infra or (u)se it? [c/u]: "
            read USER_CHOICE
            case "$USER_CHOICE" in
                c|C)
                    echo_info "Destroying existing infrastructure..."
                    $INFRA_BINARY destroy -auto-approve >> "$LOGFILE" 2>&1 || { echo_error "$INFRA_BINARY destroy failed."; exit 1; }
                    ;;
                u|U)
                    echo_info "Using existing infrastructure. Configuring kubectl..."
                    KUBECTL_CMD="$($INFRA_BINARY output -raw configure_kubectl)"
                    echo_info "Executing kubectl configuration command: $KUBECTL_CMD"
                    sh -c "$KUBECTL_CMD" >> "$LOGFILE" 2>&1 || { echo_error "$INFRA_BINARY output failed."; exit 1; }
                    ;;
                *)
                    echo_error "Invalid choice. Exiting."
                    exit 1
                    ;;
            esac
        fi
    fi

    # Proceed to deploy only if cleanup was chosen or infra does not exist
    echo_info "Initializing $INFRA_BINARY..."
    $INFRA_BINARY init >> "$LOGFILE" 2>&1 || { echo_error "$INFRA_BINARY init failed."; exit 1; }

    echo_info "Planning $INFRA_BINARY deployment..."
    $INFRA_BINARY plan >> "$LOGFILE" 2>&1 || { echo_error "$INFRA_BINARY plan failed."; exit 1; }

    echo_info "Applying $INFRA_BINARY deployment..."
    $INFRA_BINARY apply -auto-approve >> "$LOGFILE" 2>&1 || { echo_error "$INFRA_BINARY apply failed."; exit 1; }

    echo_info "Connecting to the Kubernetes cluster..."
    KUBECTL_CMD="$($INFRA_BINARY output -raw configure_kubectl)"

    echo_info "Executing kubectl configuration command: $KUBECTL_CMD"
    sh -c "$KUBECTL_CMD" >> "$LOGFILE" 2>&1 || { echo_error "Failed to configure kubectl."; exit 1; }

    # Verify kubectl configuration
    if ! kubectl cluster-info > /dev/null 2>&1; then
        echo_error "kubectl failed to configure the cluster."
        exit 1
    fi
    echo_info "kubectl configured successfully."
}

# -----------------------------
# Application Installation
# -----------------------------

install_application() {
    echo_primary "Installing OpenGovernance via Helm. This step takes approximately 7-11 minutes."
    echo_info "Installing OpenGovernance via Helm."

    if [ "$INSTALL_TYPE" = "1" ]; then
        # Ensure DOMAIN is set
        if [ -z "${DOMAIN:-}" ]; then
            echo_error "Domain must be provided for installation."
            exit 1
        fi

        # Create a temporary values file
        TEMP_VALUES_FILE="$(mktemp)"
        cat > "$TEMP_VALUES_FILE" <<EOF
global:
  domain: ${DOMAIN}
dex:
  config:
    issuer: ${PROTOCOL}://${DOMAIN}/dex
EOF

        # Run helm install with the values file
        helm_install_with_timeout -n "$NAMESPACE" "$HELM_RELEASE" "$HELM_CHART" --create-namespace -f "$TEMP_VALUES_FILE" || { echo_error "Helm install failed."; exit 1; }
        rm -f "$TEMP_VALUES_FILE"
    else
        # For Basic Install, run helm install without additional values
        helm_install_with_timeout -n "$NAMESPACE" "$HELM_RELEASE" "$HELM_CHART" --create-namespace || { echo_error "Helm install failed."; exit 1; }
    fi

    echo_info "Helm install completed."
}

# -----------------------------
# Ingress Configuration
# -----------------------------

configure_ingress() {
    echo_primary "Configuring Ingress. This step takes approximately 2-3 minutes."

    # Ensure DOMAIN is set
    if [ -z "${DOMAIN:-}" ]; then
        echo_error "DOMAIN must be set to configure Ingress."
        exit 1
    fi

    # Prepare Ingress manifest
    INGRESS_TEMPLATE=$(cat <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  namespace: "${NAMESPACE}"
  name: opengovernance-ingress
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/backend-protocol: HTTP
    kubernetes.io/ingress.class: alb
EOF
    )

    if [ "$USE_HTTPS" = "true" ]; then
        echo_info "Applying Ingress with HTTPS."
        INGRESS_TEMPLATE="$INGRESS_TEMPLATE
    alb.ingress.kubernetes.io/listen-ports: '[{\"HTTP\": 80}, {\"HTTPS\":443}]'
    alb.ingress.kubernetes.io/certificate-arn: \"${CERTIFICATE_ARN}\"
"
    else
        echo_info "Applying Ingress with HTTP only."
        INGRESS_TEMPLATE="$INGRESS_TEMPLATE
    alb.ingress.kubernetes.io/listen-ports: '[{\"HTTP\": 80}]'
"
    fi

    INGRESS_TEMPLATE="$INGRESS_TEMPLATE
spec:
  ingressClassName: alb
  rules:
    - host: \"${DOMAIN}\"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: nginx-proxy
                port:
                  number: 80
"

    # Apply Ingress
    echo "$INGRESS_TEMPLATE" | kubectl apply -f - >> "$LOGFILE" 2>&1
    echo_info "Ingress applied successfully."
}

# -----------------------------
# Readiness Checks
# -----------------------------

# Function to check OpenGovernance readiness
check_opengovernance_readiness() {
    # Check the readiness of all pods in the specified namespace
    not_ready_pods=$(kubectl get pods -n "$NAMESPACE" --no-headers | awk '{print $3}' | grep -v -E 'Running|Completed' || true)

    if [ -z "$not_ready_pods" ]; then
        APP_HEALTHY="true"
    else
        echo_error "Some OpenGovernance pods are not healthy."
        kubectl get pods -n "$NAMESPACE" >> "$LOGFILE" 2>&1
        APP_HEALTHY="false"
    fi
}

# Function to check pods and migrator jobs
check_pods_and_jobs() {
    attempts=0
    max_attempts=24  # 24 attempts * 30 seconds = 12 minutes
    sleep_time=30

    while [ "$attempts" -lt "$max_attempts" ]; do
        check_opengovernance_readiness
        if [ "${APP_HEALTHY:-false}" = "true" ]; then
            return 0
        fi
        attempts=$((attempts + 1))
        echo_info "Waiting for pods to become ready... ($attempts/$max_attempts)"
        sleep "$sleep_time"
    done

    echo_error "OpenGovernance did not become ready within expected time."
    exit 1
}

# -----------------------------
# ACM Certificate Lookup
# -----------------------------

lookup_acm_certificate() {
    DOMAIN_TO_LOOKUP="$1"
    echo_info "Looking up ACM Certificate ARN for domain '$DOMAIN_TO_LOOKUP'."

    # List certificates with status 'ISSUED'
    CERT_LIST=$(aws acm list-certificates --query 'CertificateSummaryList[?DomainName==`'"$DOMAIN_TO_LOOKUP"'` && Status==`ISSUED`].CertificateArn' --output text 2>/dev/null || true)

    if [ -z "$CERT_LIST" ]; then
        echo_error "No active ACM certificate found for domain '$DOMAIN_TO_LOOKUP'."
        CERTIFICATE_ARN=""
        return 1
    fi

    # If multiple certificates are found, select the first one
    CERTIFICATE_ARN=$(echo "$CERT_LIST" | awk '{print $1}' | head -n 1)

    if [ -z "$CERTIFICATE_ARN" ]; then
        echo_error "Failed to retrieve ACM Certificate ARN for domain '$DOMAIN_TO_LOOKUP'."
        return 1
    fi

    echo_info "Found ACM Certificate ARN: $CERTIFICATE_ARN"
    return 0
}

# -----------------------------
# Port-Forwarding Function
# -----------------------------

basic_install_with_port_forwarding() {
    echo_info "Setting up port-forwarding to access OpenGovernance locally."

    # Start port-forwarding in the background
    kubectl port-forward -n "$NAMESPACE" service/nginx-proxy 8080:80 >> "$LOGFILE" 2>&1 &
    PORT_FORWARD_PID=$!

    # Give port-forwarding some time to establish
    sleep 5

    # Check if port-forwarding is still running
    if kill -0 "$PORT_FORWARD_PID" >/dev/null 2>&1; then
        echo_info "Port-forwarding established successfully."
        echo_prompt "OpenGovernance is accessible at http://localhost:8080"
        echo_prompt "To sign in, use the following default credentials:"
        echo_prompt "  Username: admin@opengovernance.io"
        echo_prompt "  Password: password"
        echo_prompt "You can terminate port-forwarding by killing the background process (PID: $PORT_FORWARD_PID)."
    else
        echo_primary ""
        echo_primary "========================================="
        echo_primary "Port-Forwarding Instructions"
        echo_primary "========================================="
        echo_primary "OpenGovernance is running but not accessible via Ingress."
        echo_primary "You can access it using port-forwarding as follows:"
        echo_primary ""
        echo_primary "kubectl port-forward -n \"$NAMESPACE\" service/nginx-proxy 8080:80"
        echo_primary ""
        echo_primary "Then, access it at http://localhost:8080"
        echo_primary ""
        echo_primary "To sign in, use the following default credentials:"
        echo_primary "  Username: admin@opengovernance.io"
        echo_primary "  Password: password"
        echo_primary ""
    fi
}

# -----------------------------
# Main Execution Flow
# -----------------------------

echo_primary "======================================="
echo_primary "Starting OpenGovernance Deployment Script"
echo_primary "======================================="

# Initialize variables
DOMAIN=""
INSTALL_TYPE=""
INSTALL_TYPE_SPECIFIED="false"
SKIP_INFRA="false"
CERTIFICATE_ARN=""                # Will be set during domain confirmation
INFRA_BINARY=""                   # Will be determined later
KUBECTL_ACTIVE="false"            # Will be set in is_kubectl_active
CLUSTER_SUITABLE="false"          # Will be set in is_cluster_suitable
CURRENT_PROVIDER="NONE"           # Will be set in confirm_provider_is_eks
USE_HTTPS="false"                 # Will be set during domain confirmation
PROTOCOL="http"                   # Default protocol

# Parse command-line arguments
while [ "$#" -gt 0 ]; do
    case "$1" in
        -d|--domain)
            if [ "$#" -lt 2 ]; then
                echo_error "Option '$1' requires an argument."
                usage
            fi
            DOMAIN="$2"
            shift 2
            ;;
        -t|--type)
            if [ "$#" -lt 2 ]; then
                echo_error "Option '$1' requires an argument."
                usage
            fi
            INSTALL_TYPE="$2"
            INSTALL_TYPE_SPECIFIED="true"
            shift 2
            ;;
        --debug)
            DEBUG_MODE="true"
            echo_info "Debug mode enabled."
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

# Step 1: Check for required tools and prerequisites
echo_info "Checking for required tools and prerequisites..."
check_prerequisites

# Step 2: Determine Installation Type Based on Parameters
if [ -n "$DOMAIN" ]; then
    # Domain is specified, set installation type to 1
    echo_info "Domain specified: $DOMAIN. Setting installation type to 1."
    INSTALL_TYPE="1"
else
    # Domain is not specified, use install type parameter or prompt
    if [ "$INSTALL_TYPE_SPECIFIED" = "false" ]; then
        # Prompt user for installation type with a 30-second timeout
        echo_primary ""
        echo_primary "======================================="
        echo_primary "Select Installation Type:"
        echo_primary "======================================="
        echo_primary "1) Install with HTTPS (requires a domain name)"
        echo_primary "2) Basic Install (No Ingress, use port-forwarding)"
        echo_primary "Default: 2 (if no input within 30 seconds)"
        echo_prompt "Enter your choice (1/2): "

        # Read user input with a 30-second timeout
        if ! read -t 30 USER_INSTALL_TYPE; then
            USER_INSTALL_TYPE=""
        fi

        if [ -z "$USER_INSTALL_TYPE" ]; then
            echo_primary "No input received within 30 seconds. Proceeding with Basic Install (No Ingress, use port-forwarding)."
            INSTALL_TYPE="2"
        else
            # Validate user input
            case "$USER_INSTALL_TYPE" in
                1|2)
                    INSTALL_TYPE="$USER_INSTALL_TYPE"
                    ;;
                *)
                    echo_error "Invalid installation type selected."
                    usage
                    ;;
            esac
        fi
    else
        # Use install type specified via parameter
        case "$INSTALL_TYPE" in
            1|2)
                ;;
            *)
                echo_error "Invalid installation type specified via parameter."
                usage
                ;;
        esac
    fi
fi

# Step 2.1: If user selected Install with HTTPS, ensure domain is provided
if [ "$INSTALL_TYPE" = "1" ]; then
    if [ -z "$DOMAIN" ]; then
        total_time=0
        DOMAIN_INPUT=""
        while [ "$total_time" -lt 90 ]; do
            remaining_time=$((90 - total_time))
            echo_prompt "Please enter your fully qualified domain name (e.g., some.example.com). You have $remaining_time seconds left: "
            if ! read -t 15 DOMAIN_INPUT; then
                DOMAIN_INPUT=""
            fi

            if [ -z "$DOMAIN_INPUT" ]; then
                total_time=$((total_time + 15))
                echo_info "No domain entered. Please try again."
                if [ "$total_time" -ge 90 ]; then
                    echo_primary "No domain provided after 90 seconds. Proceeding with Basic Install (No Ingress, use port-forwarding)."
                    INSTALL_TYPE="2"
                    break
                fi
            else
                # Confirm the domain
                echo_prompt "You entered domain: $DOMAIN_INPUT. Press Enter to confirm or type a new domain within 15 seconds."
                if ! read -t 15 DOMAIN_CONFIRM; then
                    DOMAIN_CONFIRM=""
                fi

                if [ -z "$DOMAIN_CONFIRM" ]; then
                    # Domain confirmed
                    DOMAIN="$DOMAIN_INPUT"
                    break
                else
                    # User provided a new domain, update DOMAIN_INPUT and loop again
                    DOMAIN_INPUT="$DOMAIN_CONFIRM"
                fi
            fi
        done

        if [ "$INSTALL_TYPE" = "2" ]; then
            echo_info "Proceeding with Basic Install (No Ingress, use port-forwarding)."
        fi
    fi

    # After domain is confirmed, lookup ACM certificate
    if [ -n "$DOMAIN" ]; then
        # Use an if-statement to handle the function's exit status without causing the script to exit
        if lookup_acm_certificate "$DOMAIN"; then
            USE_HTTPS="true"
            PROTOCOL="https"
            echo_info "ACM certificate found. Proceeding with HTTPS."
        else
            USE_HTTPS="false"
            PROTOCOL="http"
            echo_primary "No ACM certificate found for domain '$DOMAIN'. Proceeding with HTTP only."
        fi
    fi
fi

# Step 3: Determine Installation Behavior Based on Cluster Configuration

if [ "$KUBECTL_ACTIVE" = "true" ] && [ "$CLUSTER_SUITABLE" = "true" ]; then
    # Display cluster metadata before prompting
    display_cluster_metadata

    echo_prompt "A suitable EKS cluster is detected. Do you wish to use it and skip infrastructure setup? (y/n): "
    read USE_EXISTING_CLUSTER

    case "$USE_EXISTING_CLUSTER" in
        y|Y)
            SKIP_INFRA="true"
            echo_info "Skipping infrastructure creation. Proceeding with installation using existing cluster."
            ;;
        n|N)
            SKIP_INFRA="false"
            ;;
        *)
            echo_error "Invalid choice. Exiting."
            exit 1
            ;;
    esac
else
    SKIP_INFRA="false"
fi

# Step 4: Clone repository and deploy infrastructure if not skipping
if [ "$SKIP_INFRA" = "false" ]; then
    clone_repository() {
        if [ -d "$REPO_DIR" ]; then
            echo_info "Directory '$REPO_DIR' already exists. Deleting it before cloning..."
            rm -rf "$REPO_DIR" >> "$LOGFILE" 2>&1 || { echo_error "Failed to delete existing directory '$REPO_DIR'."; exit 1; }
        fi
        echo_info "Cloning repository from $REPO_URL to $REPO_DIR..."
        git clone "$REPO_URL" "$REPO_DIR" >> "$LOGFILE" 2>&1 || { echo_error "Failed to clone repository."; exit 1; }
    }

    clone_repository
    deploy_infrastructure
else
    echo_info "Skipping infrastructure deployment as per user request."
fi

# Step 5: Install OpenGovernance via Helm
install_application

# Step 6: Wait for application readiness
check_pods_and_jobs

# Step 7: Configure Ingress or Port-Forwarding based on installation type
if [ "$INSTALL_TYPE" = "1" ]; then
    configure_ingress
elif [ "$INSTALL_TYPE" = "2" ]; then
    basic_install_with_port_forwarding
fi

# Add the new direction messages
if [ "$INSTALL_TYPE" = "1" ]; then
    echo_primary "OpenGovernance has been successfully installed and configured."
    echo_primary ""
    echo_primary "Access your OpenGovernance instance at: ${PROTOCOL}://${DOMAIN}"
    echo_primary ""
    echo_primary "To sign in, use the following default credentials:"
    echo_primary "  Username: admin@opengovernance.io"
    echo_primary "  Password: password"
    echo_primary ""
elif [ "$INSTALL_TYPE" = "2" ]; then
    echo_primary "OpenGovernance has been successfully installed and configured."
    echo_primary ""
    echo_primary "To access OpenGovernance, set up port-forwarding as follows:"
    echo_primary "kubectl port-forward -n \"$NAMESPACE\" service/nginx-proxy 8080:80"
    echo_primary ""
    echo_primary "Then, access it at http://localhost:8080"
    echo_primary ""
    echo_primary "To sign in, use the following default credentials:"
    echo_primary "  Username: admin@opengovernance.io"
    echo_primary "  Password: password"
    echo_primary ""
fi

exit 0
