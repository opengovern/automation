#!/bin/sh

# Enable strict error handling
set -eu

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
    if command -v terraform >/dev/null 2>&1; then
        INFRA_TOOL="terraform"
        echo_info "Terraform is installed."
    elif command -v tofu >/dev/null 2>&1; then
        INFRA_TOOL="tofu"
        echo_info "OpenTofu is installed."
    else
        echo_error "Neither Terraform nor OpenTofu is installed. Please install one of them and retry."
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
    is_kubectl_active

    if [ "$KUBECTL_ACTIVE" = "true" ]; then
        # Determine if there is a suitable cluster
        is_cluster_suitable
        if [ "$CLUSTER_SUITABLE" = "true" ]; then
            echo_info "Cluster is suitable for installation."
        else
            echo_info "Cluster is not suitable for installation."
        fi
    fi

    echo_info "Checking Prerequisites...Completed"
}

# Function to ensure the Helm repository is added and updated
ensure_helm_repo() {
    REPO_NAME="opengovernance"
    REPO_URL="https://opengovern.github.io/charts"

    # Check if Helm is installed
    if command -v helm >/dev/null 2>&1; then
        echo_info "Ensuring Helm repository '$REPO_NAME' is added and up to date."

        # Check if the repository already exists
        if helm repo list | awk '{print $1}' | grep -q "^$REPO_NAME$"; then
            echo_info "Helm repository '$REPO_NAME' already exists."
        else
            # Add the repository
            echo_info "Adding Helm repository '$REPO_NAME'."
            helm repo add "$REPO_NAME" "$REPO_URL" >> "$LOGFILE" 2>&1 || { echo_error "Failed to add Helm repository '$REPO_NAME'."; exit 1; }
        fi

        # Update the Helm repositories
        echo_info "Updating Helm repositories."
        helm repo update >> "$LOGFILE" 2>&1 || { echo_error "Failed to update Helm repositories."; exit 1; }
    else
        echo_error "Helm is not installed."
        exit 1
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
INSTALL_TYPE_SPECIFIED=false
SKIP_INFRA=false
HELM_RELEASE="opengovernance"
HELM_CHART="opengovernance/opengovernance"  # Official Helm chart repository
NAMESPACE="opengovernance"        # Default namespace
CERTIFICATE_ARN=""                # Will be set during Ingress with HTTPS
INFRA_TOOL=""                     # Will be determined later
KUBECTL_ACTIVE="false"            # Will be set in is_kubectl_active
CLUSTER_SUITABLE="false"          # Will be set in is_cluster_suitable
CURRENT_PROVIDER="NONE"           # Will be set in confirm_provider_is_eks

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
            INSTALL_TYPE_SPECIFIED=true
            shift 2
            ;;
        --debug)
            DEBUG_MODE=true
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
    INSTALL_TYPE=1
else
    # Domain is not specified, use install type parameter or prompt
    if [ "$INSTALL_TYPE_SPECIFIED" = "false" ]; then
        # Prompt user for installation type
        echo_primary ""
        echo_primary "======================================="
        echo_primary "Select Installation Type:"
        echo_primary "======================================="
        echo_primary "1) Install with HTTPS and Hostname (default if domain is provided)"
        echo_primary "2) Install without HTTPS (DNS records required after installation)"
        echo_primary "3) Minimal Install (Access via public IP) [Placeholder]"
        echo_primary "4) Basic Install (No Ingress, use port-forwarding)"
        echo_primary "Default: 1"
        echo_prompt "Enter your choice (1/2/3/4): "
        read USER_INSTALL_TYPE

        # Validate user input
        case "$USER_INSTALL_TYPE" in
            1|2|3|4)
                INSTALL_TYPE="$USER_INSTALL_TYPE"
                ;;
            "")
                INSTALL_TYPE=1
                ;;
            *)
                echo_error "Invalid installation type selected."
                usage
                ;;
        esac
    else
        # Use install type specified via parameter
        case "$INSTALL_TYPE" in
            1|2|3|4)
                ;;
            *)
                echo_error "Invalid installation type specified via parameter."
                usage
                ;;
        esac
    fi
fi

# Step 3: Determine Installation Behavior Based on Cluster Configuration

if [ "$KUBECTL_ACTIVE" = "true" ] && [ "$CLUSTER_SUITABLE" = "true" ]; then
    echo_prompt "A suitable EKS cluster is detected. Do you wish to use it and skip infrastructure setup? (y/n): "
    read USE_EXISTING_CLUSTER

    case "$USE_EXISTING_CLUSTER" in
        y|Y)
            SKIP_INFRA=true
            echo_info "Skipping infrastructure creation. Proceeding with installation using existing cluster."
            ;;
        n|N)
            SKIP_INFRA=false
            ;;
        *)
            echo_error "Invalid choice. Exiting."
            exit 1
            ;;
    esac
else
    SKIP_INFRA=false
fi

# Step 4: Clone repository and deploy infrastructure if not skipping
if [ "$SKIP_INFRA" = "false" ]; then
    clone_repository() {
        REPO_URL="https://github.com/opengovern/deploy-opengovernance.git"
        REPO_DIR="$HOME/.opengovernance/deploy-terraform"
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
echo_info "Proceeding with OpenGovernance installation."

# If domain was not specified and install type 1 or 2 is selected, prompt for domain
if [ -z "$DOMAIN" ] && ([ "$INSTALL_TYPE" = "1" ] || [ "$INSTALL_TYPE" = "2" ]); then
    echo_prompt "Enter the domain name for OpenGovernance (e.g., demo.opengovernance.io): "
    read -r DOMAIN
    if [ -z "$DOMAIN" ]; then
        echo_error "Domain name cannot be empty for installation type $INSTALL_TYPE."
        exit 1
    fi
fi

install_application

# Step 6: Configure Ingress or Port-Forwarding based on installation type
configure_ingress

echo_primary ""
echo_primary "======================================="
echo_primary "Deployment Script Completed Successfully!"
echo_primary "======================================="
if [ "$INSTALL_TYPE" = "1" ]; then
    echo_primary "Your service should now be fully operational at https://$DOMAIN"
elif [ "$INSTALL_TYPE" = "2" ]; then
    echo_primary "Your service should now be fully operational at http://$DOMAIN"
elif [ "$INSTALL_TYPE" = "4" ]; then
    echo_primary "Your service should now be accessible via port-forwarding at http://localhost:8080"
fi
echo_primary "======================================="

exit 0
