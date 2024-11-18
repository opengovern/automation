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
DEBUG_MODE=true  # Helm operates in debug mode
LOGFILE="$HOME/.opengovernance/install.log"
DEBUG_LOGFILE="$HOME/.opengovernance/helm_debug.log"

# Create the log directories and files if they don't exist
LOGDIR="$(dirname "$LOGFILE")"
DEBUG_LOGDIR="$(dirname "$DEBUG_LOGFILE")"
mkdir -p "$LOGDIR" || { echo "Failed to create log directory at $LOGDIR."; exit 1; }
mkdir -p "$DEBUG_LOGDIR" || { echo "Failed to create debug log directory at $DEBUG_LOGDIR."; exit 1; }
touch "$LOGFILE" "$DEBUG_LOGFILE" || { echo "Failed to create log files."; exit 1; }

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
    echo_primary "  -r, --region <region>    Specify the AWS region to deploy the infrastructure (e.g., us-west-2)."
    echo_primary "  --debug                  Enable debug mode for detailed output."
    echo_primary "  -h, --help               Display this help message."
    exit 1
}

# Function to run helm commands with a timeout of 15 minutes in debug mode
helm_install_with_timeout() {
    helm install "$@" --debug --timeout=15m 2>&1 | tee -a "$DEBUG_LOGFILE" >> "$LOGFILE"
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

# Function to detect Kubernetes provider and unset context
detect_kubernetes_and_unset_context() {
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

# Function to confirm Deployment Settings
confirm_deployment_settings() {
    echo_primary "======================================="
    echo_primary "Confirm Deployment Settings"
    echo_primary "======================================="
    echo_info "EKS Cluster Name: ${EKS_CLUSTER_NAME:-opengovernance-cluster}"
    echo_info "AWS Region: ${REGION:-$(aws configure get region)}"
    echo_info "Installation Type: ${INSTALL_TYPE:-Not Set}"
    echo_info "Protocol: ${PROTOCOL:-Not Set}"
    echo_primary ""

    while :; do
        echo_prompt "Do you want to use these settings? (Y/n): "
        read -r USER_CONFIRM

        case "$USER_CONFIRM" in
            [Yy]|"" )
                break
                ;;
            [Nn] )
                modify_deployment_settings
                ;;
            * )
                echo_error "Invalid input. Please enter Y or N."
                ;;
        esac
    done
}

# Function to modify Deployment Settings
modify_deployment_settings() {
    # Prompt user to change EKS Cluster Name
    echo_prompt "Enter new EKS Cluster Name (leave blank to keep current [${EKS_CLUSTER_NAME:-opengovernance-cluster}]): "
    read -r NEW_CLUSTER_NAME
    if [ -n "$NEW_CLUSTER_NAME" ]; then
        EKS_CLUSTER_NAME="$NEW_CLUSTER_NAME"
        echo_info "EKS Cluster Name updated to: $EKS_CLUSTER_NAME"
    else
        echo_info "EKS Cluster Name remains as: ${EKS_CLUSTER_NAME:-opengovernance-cluster}"
    fi

    # Prompt user to change AWS Region with list of available regions
    echo_prompt "Would you like to see the list of available AWS Regions? (Y/n): "
    read -r SHOW_REGIONS

    if echo "$SHOW_REGIONS" | grep -iq "^y"; then
        display_available_regions
    fi

    echo_prompt "Enter new AWS Region (leave blank to keep current [${REGION:-$(aws configure get region)}]): "
    read -r NEW_REGION
    if [ -n "$NEW_REGION" ]; then
        if validate_aws_region "$NEW_REGION"; then
            REGION="$NEW_REGION"
            echo_info "AWS Region updated to: $REGION"
        else
            echo_error "Invalid AWS Region: $NEW_REGION"
            REGION=""
        fi
    else
        echo_info "AWS Region remains as: ${REGION:-$(aws configure get region)}"
    fi
}

# Function to validate AWS Region
validate_aws_region() {
    INPUT_REGION="$1"
    AVAILABLE_REGIONS=$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text 2>/dev/null || true)

    if echo "$AVAILABLE_REGIONS" | grep -qw "$INPUT_REGION"; then
        return 0
    else
        return 1
    fi
}

# Function to get available AWS regions
get_available_regions() {
    aws ec2 describe-regions --query 'Regions[].RegionName' --output text 2>/dev/null || true
}

# Function to display available AWS regions
display_available_regions() {
    echo_primary "Available AWS Regions:"
    AVAILABLE_REGIONS=$(get_available_regions)
    echo_primary "$AVAILABLE_REGIONS" | tr '\t' '\n' | nl -w2 -s'. '
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

    echo_info "Checking Prerequisites...Completed"
}

# Function to ensure the Helm repository is added and updated in debug mode
ensure_helm_repo() {
    # Check if Helm is installed
    if command -v helm >/dev/null 2>&1; then
        echo_info "Ensuring Helm repository '$REPO_NAME' is added and up to date."

        # Check if the repository already exists
        if helm repo list | awk '{print $1}' | grep -q "^$REPO_NAME$"; then
            echo_info "Helm repository '$REPO_NAME' already exists."
        else
            # Add the repository with debug
            echo_info "Adding Helm repository '$REPO_NAME' in debug mode."
            helm repo add "$REPO_NAME" "$HELM_REPO_URL" --debug 2>&1 | tee -a "$DEBUG_LOGFILE" >> "$LOGFILE" || { echo_error "Failed to add Helm repository '$REPO_NAME'."; exit 1; }
        fi

        # Update the Helm repositories with debug
        echo_info "Updating Helm repositories in debug mode."
        helm repo update --debug 2>&1 | tee -a "$DEBUG_LOGFILE" >> "$LOGFILE" || { echo_error "Failed to update Helm repositories."; exit 1; }
    else
        echo_error "Helm is not installed."
        exit 1
    fi
}

# Function to deploy infrastructure
deploy_infrastructure() {
    # Construct the deployment message with REGION if it's set
    if [ -n "$REGION" ]; then
        echo_primary "Deploying Infrastructure with terraform (this will take 10-5 mins)"
        export AWS_REGION="$REGION"
    else
        echo_primary "Deploying Infrastructure with terraform (this will take 10-5 mins)"
    fi

    echo_info "Ensuring infrastructure directory exists: $INFRA_DIR"
    mkdir -p "$INFRA_DIR" || { echo_error "Failed to create infrastructure directory at $INFRA_DIR."; exit 1; }

    echo_info "Navigating to infrastructure directory: $INFRA_DIR"
    cd "$INFRA_DIR" || { echo_error "Failed to navigate to $INFRA_DIR"; exit 1; }

    # Set variables for plan and apply
    TF_VAR_REGION_OPTION=""
    TF_VAR_CLUSTER_NAME_OPTION=""

    # Conditionally add the region variable if REGION is set
    if [ -n "$REGION" ]; then
        TF_VAR_REGION_OPTION="-var 'region=$REGION'"
    fi

    # Conditionally add the cluster name variable if EKS_CLUSTER_NAME is set
    if [ -n "${EKS_CLUSTER_NAME:-}" ]; then
        TF_VAR_CLUSTER_NAME_OPTION="-var 'cluster_name=$EKS_CLUSTER_NAME'"
    fi

    # Combine variable options
    TF_VARS_OPTIONS="$TF_VAR_REGION_OPTION $TF_VAR_CLUSTER_NAME_OPTION"

    echo_info "Initializing $INFRA_BINARY..."
    $INFRA_BINARY init >> "$LOGFILE" 2>&1 || { echo_error "$INFRA_BINARY init failed."; exit 1; }

    echo_info "Planning $INFRA_BINARY deployment..."
    # Use eval to properly handle variables with quotes
    eval "$INFRA_BINARY plan $TF_VARS_OPTIONS -out=plan.tfplan" >> "$LOGFILE" 2>&1 || { echo_error "$INFRA_BINARY plan failed."; exit 1; }

    echo_info "Generating JSON representation of the plan..."
    $INFRA_BINARY show -json plan.tfplan > plan.json || { echo_error "$INFRA_BINARY show failed."; exit 1; }

    # ------------------------------
    # ISSUE 2 FIX: Run apply in foreground
    # ------------------------------
    echo_info "Applying $INFRA_BINARY deployment..."
    # Run apply in foreground without backgrounding
    eval "$INFRA_BINARY apply plan.tfplan" >> "$LOGFILE" 2>&1 || { echo_error "$INFRA_BINARY apply failed."; exit 1; }

    # Clean up plan files
    rm -f plan.tfplan plan.json

    echo_info "Connecting to the Kubernetes cluster..."
    KUBECTL_CMD=$($INFRA_BINARY output -raw configure_kubectl)

    echo_info "Executing kubectl configuration command."
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
    CERT_LIST=$(aws acm list-certificates --query "CertificateSummaryList[?DomainName==\`$DOMAIN_TO_LOOKUP\` && Status==\`ISSUED\`].CertificateArn" --output text 2>/dev/null || true)

    if [ -z "$CERT_LIST" ]; then
        echo_error "No active ACM certificate found for domain '$DOMAIN_TO_LOOKUP'."
        CERTIFICATE_ARN=""
        USE_HTTPS="false"
        PROTOCOL="http"
        return 1
    fi

    # If multiple certificates are found, select the first one
    CERTIFICATE_ARN=$(echo "$CERT_LIST" | awk '{print $1}' | head -n 1)

    if [ -z "$CERTIFICATE_ARN" ]; then
        echo_error "Failed to retrieve ACM Certificate ARN for domain '$DOMAIN_TO_LOOKUP'."
        USE_HTTPS="false"
        PROTOCOL="http"
        return 1
    fi

    echo_info "Found ACM Certificate ARN: $CERTIFICATE_ARN"
    USE_HTTPS="true"
    PROTOCOL="https"
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
        echo_primary "kubectl port-forward -n '$NAMESPACE' service/nginx-proxy 8080:80"
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
CERTIFICATE_ARN=""                # Will be set during domain confirmation
INFRA_BINARY=""                   # Will be determined later
USE_HTTPS="false"                 # Will be set during domain confirmation
PROTOCOL="http"                   # Default protocol
REGION=""                         # New variable for AWS region
EKS_CLUSTER_NAME=""               # Initialize EKS Cluster Name

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
        -r|--region)
            if [ "$#" -lt 2 ]; then
                echo_error "Option '$1' requires an argument."
                usage
            fi
            REGION="$2"
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

# Step 2: Detect Kubernetes provider and unset context
detect_kubernetes_and_unset_context

# Step 3: Determine Installation Type Based on Parameters
if [ -n "$DOMAIN" ]; then
    # Domain is specified, set installation type to 1
    echo_info "Domain specified: $DOMAIN. Setting installation type to 1."
    INSTALL_TYPE="1"
fi

if [ -z "$INSTALL_TYPE" ]; then
    # Installation type not specified via parameter or domain
    if [ "$INSTALL_TYPE_SPECIFIED" = "false" ]; then
        # Prompt user for installation type
        echo_primary ""
        echo_primary "======================================="
        echo_primary "Select Installation Type:"
        echo_primary "======================================="
        echo_primary "1) Install with HTTPS (requires a domain name)"
        echo_primary "2) Basic Install (No Ingress, use port-forwarding)"
        echo_primary "Default: 2"
        echo_prompt "Enter your choice (1/2): "

        read -r USER_INSTALL_TYPE

        if [ -z "$USER_INSTALL_TYPE" ]; then
            echo_primary "No input received. Proceeding with Basic Install (No Ingress, use port-forwarding)."
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

# Step 4: If user selected Install with HTTPS, ensure domain is provided and lookup ACM certificate
if [ "$INSTALL_TYPE" = "1" ]; then
    if [ -z "$DOMAIN" ]; then
        echo_prompt "Please enter your fully qualified domain name (e.g., some.example.com): "
        read -r DOMAIN_INPUT

        if [ -z "$DOMAIN_INPUT" ]; then
            echo_primary "No domain provided. Proceeding with Basic Install (No Ingress, use port-forwarding)."
            INSTALL_TYPE="2"
            echo_info "Proceeding with Basic Install (No Ingress, use port-forwarding)."
        else
            DOMAIN="$DOMAIN_INPUT"
        fi
    fi

    # After domain is confirmed, lookup ACM certificate
    if [ -n "$DOMAIN" ]; then
        if lookup_acm_certificate "$DOMAIN"; then
            echo_info "ACM certificate found. Proceeding with HTTPS."
        else
            echo_primary "No ACM certificate found for domain '$DOMAIN'. Proceeding with HTTP only."
        fi
    fi
fi

# Step 5: Confirm Deployment Settings (EKS Cluster Name, Region, Install Type, Protocol)
confirm_deployment_settings

# ------------------------------
# ISSUE 1 FIX: Prevent Redundant Confirmation
# ------------------------------
# The confirmation loop in 'confirm_deployment_settings' now ensures that once the user accepts the settings (Y), the loop breaks, and the script proceeds without re-prompting.

# Step 6: Clone repository and deploy infrastructure
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

# Step 7: Install OpenGovernance via Helm
install_application

# Step 8: Wait for application readiness
check_pods_and_jobs

# Step 9: Configure Ingress or Port-Forwarding based on installation type
if [ "$INSTALL_TYPE" = "1" ]; then
    configure_ingress
elif [ "$INSTALL_TYPE" = "2" ]; then
    basic_install_with_port_forwarding
fi

# Step 10: Final Directions
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

echo_primary "OpenGovernance deployment script completed successfully."
exit 0
