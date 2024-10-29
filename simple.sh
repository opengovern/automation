#!/usr/bin/env bash

# -----------------------------
# Script Configuration
# -----------------------------

# Enable strict mode
set -euo pipefail

# Trap for unexpected exits
trap 'echo_error "Script terminated unexpectedly."; exit 1' INT TERM ERR

# Logging Configuration
LOGFILE="$HOME/opengovernance_install.log"

# Ensure the log directory exists
mkdir -p "$(dirname "$LOGFILE")" || { echo "Failed to create log directory."; exit 1; }

# Redirect all output to the log file and console
exec > >(tee -a "$LOGFILE") 2>&1

# Open file descriptor 3 for logging only
exec 3>>"$LOGFILE"

# Initialize arrays
MISSING_TOOLS=()
AVAILABLE_PLATFORMS=()

# Initialize cluster-related variables
KUBE_REGION="${KUBE_REGION:-nyc1}"            # Default region, can be overridden by environment variable
KUBE_CLUSTER_NAME="${KUBE_CLUSTER_NAME:-}"    # Initially empty, will be set based on detection or user input

# Detect Operating System
OS_TYPE="$(uname -s)"
case "$OS_TYPE" in
    Linux*)     OS=Linux;;
    Darwin*)    OS=Darwin;;
    FreeBSD*)   OS=FreeBSD;;
    *)          OS="UNKNOWN"
esac

if [[ "$OS" == "UNKNOWN" ]]; then
    echo_error "Unsupported Operating System: $OS_TYPE"
    exit 1
fi

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

# Function to redirect Helm commands to the log only
helm_quiet() {
    helm "$@" >&3 2>&1
}

# Function to check if a command exists
command_exists() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1
}

# Function to check tool dependencies
check_dependencies() {
    local required_tools=("helm" "kubectl" "jq" "curl")
    local additional_tools=("doctl")  # Added 'doctl' for DigitalOcean

    for tool in "${required_tools[@]}"; do
        if ! command_exists "$tool"; then
            echo_error "$tool is required but not installed."
            MISSING_TOOLS+=("$tool")
        fi
    done

    for tool in "${additional_tools[@]}"; do
        if ! command_exists "$tool"; then
            echo_error "$tool is recommended but not installed. If you plan to deploy to DigitalOcean, please install $tool."
            # Not exiting immediately; 'doctl' is optional based on deployment needs
        fi
    done

    if ! command_exists "terraform" && ! command_exists "tofu"; then
        echo_error "Either Terraform or OpenTofu is required but not installed."
        MISSING_TOOLS+=("terraform/OpenTofu")
    fi

    if [[ ${#MISSING_TOOLS[@]} -ne 0 ]]; then
        echo_error "Missing required tools: ${MISSING_TOOLS[*]}"
        echo_primary "Please install the missing tools and re-run the script."
        exit 1
    fi
}

# Cloud provider CLI check function
check_provider_cli() {
    local provider_name="$1"
    local cli_command="$2"
    local cli_check_command="$3"

    if command_exists "$cli_command"; then
        if eval "$cli_check_command" >/dev/null 2>&1; then
            echo_info "$provider_name CLI is installed and configured."
            AVAILABLE_PLATFORMS+=("$provider_name")
        else
            echo_error "$provider_name CLI is installed but not fully configured."
        fi
    else
        echo_info "$provider_name CLI is not installed."
    fi
}

# Function to check cloud provider CLIs
check_provider_clis() {
    AVAILABLE_PLATFORMS=()

    check_provider_cli "AWS" "aws" "aws sts get-caller-identity"
    check_provider_cli "Azure" "az" "az account show"
    check_provider_cli "GCP" "gcloud" "gcloud auth list --filter=status:ACTIVE --format='value(account)'"
    check_provider_cli "DigitalOcean" "doctl" "doctl auth list"

    # Verify at least one provider is available
    if [[ ${#AVAILABLE_PLATFORMS[@]} -eq 0 ]]; then
        echo_error "No configured CLI tools found."
        echo_primary "Please visit https://docs.opengovernance.io to install and configure the required tools."
        exit 1
    fi
}

# Function to get cluster info
get_cluster_info() {
    if kubectl cluster-info > /dev/null 2>&1; then
        # Extract the URL of the Kubernetes control plane
        kubectl cluster-info | grep -i "control plane" | awk '{print $NF}' || true
    else
        echo_error "kubectl is not configured correctly."
        return 1
    fi
}

# Function to detect Kubernetes provider and deploy
detect_kubernetes_provider_and_deploy() {
    local cluster_info
    cluster_info=$(get_cluster_info) || true

    if [[ -z "$cluster_info" ]]; then
        echo_primary "Unable to retrieve cluster info. Offering deployment options based on configured CLIs."
        if command_exists "helm"; then
            echo_primary "Helm is installed. Proceeding with OpenGovernance installation in 10 seconds..."
            sleep 10
            install_opengovernance_with_helm
        else
            choose_deployment
        fi
        return
    fi

    echo_info "Cluster info: $cluster_info"

    case "$cluster_info" in
        *".azmk8s.io"*) 
            echo_primary "Cluster on AKS (Azure). Deploying OpenGovernance to Azure." 
            deploy_via_curl "azure"
            ;;
        *".eks.amazonaws.com"*) 
            echo_primary "Cluster on EKS (AWS). Deploying OpenGovernance to AWS."
            deploy_via_curl "aws"
            ;;
        *".gke.io"*) 
            echo_primary "Cluster on GKE (GCP). Deploying OpenGovernance to GCP."
            deploy_via_curl "gcp"
            ;;
        *".k8s.ondigitalocean.com"*) 
            echo_primary "Cluster on DigitalOcean. Deploying OpenGovernance to DigitalOcean."
            deploy_via_curl "digitalocean"
            ;;
        *) 
            echo_primary "Kubernetes provider undetermined. Offering deployment options based on configured CLIs."
            choose_deployment 
            ;;
    esac
}

# Function to deploy via curl
deploy_via_curl() {
    local provider="$1"
    local script_url="https://raw.githubusercontent.com/opengovern/deploy-opengovernance/main/${provider}/scripts/simple.sh"

    if curl --head --silent --fail "$script_url" >/dev/null; then
        curl -sL "$script_url" | bash
    else
        echo_error "Deployment script for $provider is not accessible."
        exit 1
    fi
}

# Function to allow user to choose deployment based on available platforms
choose_deployment() {
    echo_primary "Which platform would you like to deploy OpenGovernance to?"
    local option=1
    local opts=()
    for platform in "${AVAILABLE_PLATFORMS[@]}"; do
        echo_primary "$option. $platform"
        opts+=("$platform")
        ((option++))
    done
    echo_primary "$option. Exit"
    
    while true; do
        echo_prompt -n "Select an option (1-$option): "
        read -r platform_choice < /dev/tty

        # Validate input is a number
        if ! [[ "$platform_choice" =~ ^[0-9]+$ ]]; then
            echo_error "Invalid input. Please enter a number between 1 and $option."
            continue
        fi

        if (( platform_choice < 1 || platform_choice > option )); then
            echo_error "Invalid choice. Please select a number between 1 and $option."
            continue
        fi

        if (( platform_choice == option )); then
            echo_primary "Exiting."
            exit 0
        fi

        selected_platform="${opts[platform_choice-1]}"

        case "$selected_platform" in
            "AWS") 
                echo_primary "Deploying OpenGovernance to AWS."
                deploy_via_curl "aws"
                ;;
            "Azure") 
                echo_primary "Deploying OpenGovernance to Azure."
                deploy_via_curl "azure"
                ;;
            "GCP") 
                echo_primary "Deploying OpenGovernance to GCP."
                deploy_via_curl "gcp"
                ;;
            "DigitalOcean") 
                echo_primary "Deploying OpenGovernance to DigitalOcean."
                deploy_via_curl "digitalocean"
                ;;
            *) 
                echo_error "Unsupported platform: $selected_platform"
                ;;
        esac
        break
    done
}

# Function to install OpenGovernance with Helm
install_opengovernance_with_helm() {
    echo_primary "Proceeding with Basic Install of OpenGovernance without Network Ingress. (Expected time: 7-10 minutes)"
    
    echo_detail "Adding OpenGovernance Helm repository."
    if ! helm_quiet repo add opengovernance https://opengovern.github.io/charts; then
        echo_error "Failed to add OpenGovernance Helm repository."
        exit 1
    fi

    echo_detail "Updating Helm repositories."
    if ! helm_quiet repo update; then
        echo_error "Failed to update Helm repositories."
        exit 1
    fi

    # Ensure KUBE_NAMESPACE is set
    KUBE_NAMESPACE="${KUBE_NAMESPACE:-opengovernance}"
    echo_detail "Installing OpenGovernance via Helm in namespace '$KUBE_NAMESPACE'."
    if ! helm_quiet install opengovernance opengovernance/opengovernance \
        -n "$KUBE_NAMESPACE" --create-namespace --timeout=10m --wait; then
        echo_error "Helm installation failed."
        exit 1
    fi

    echo_detail "OpenGovernance installation without Ingress completed."
    echo_detail "Application Installed successfully."

    check_pods_and_jobs

    echo_primary "Setting up port-forwarding to access OpenGovernance locally."
    if ! kubectl port-forward -n "$KUBE_NAMESPACE" service/nginx-proxy 8080:80 >/dev/null 2>&1 & then
        echo_error "Failed to initiate port-forwarding."
        provide_port_forward_instructions
        return
    fi

    PORT_FORWARD_PID=$!

    # Wait briefly to ensure port-forwarding is established
    sleep 5

    if ps -p "$PORT_FORWARD_PID" > /dev/null 2>&1; then
        echo_detail "Port-forwarding established successfully (PID: $PORT_FORWARD_PID)."
        echo_prompt "OpenGovernance is accessible at http://localhost:8080"
        echo_prompt "To sign in, use the following default credentials:"
        echo_prompt "  Username: admin@opengovernance.io"
        echo_prompt "  Password: password"
        echo_prompt "You can terminate port-forwarding by running: kill $PORT_FORWARD_PID"
    else
        echo_error "Port-forwarding failed to establish."
        provide_port_forward_instructions
    fi
}

# Function to check pods and jobs
check_pods_and_jobs() {
    echo_detail "Checking pod and job statuses in namespace '$KUBE_NAMESPACE'."
    if ! kubectl get pods -n "$KUBE_NAMESPACE"; then
        echo_error "Failed to get pod statuses."
    fi

    if ! kubectl get jobs -n "$KUBE_NAMESPACE"; then
        echo_error "Failed to get job statuses."
    fi
}

# Function to provide port-forwarding instructions manually
provide_port_forward_instructions() {
    echo_primary "Please set up port-forwarding manually using the following command:"
    echo_prompt "kubectl port-forward -n \"$KUBE_NAMESPACE\" service/nginx-proxy 8080:80"
    echo_prompt "Then, access OpenGovernance at http://localhost:8080"
    echo_prompt "Use the following default credentials to sign in:"
    echo_prompt "  Username: admin@opengovernance.io"
    echo_prompt "  Password: password"
}

# -----------------------------
# New Function Definitions
# -----------------------------

# Function to create a Kubernetes cluster with a given name on DigitalOcean
create_cluster_in_digital_ocean() {
    local cluster_name="$1"

    # Before creating the cluster, provide the region and cluster name
    echo_primary "Cluster Name: '$cluster_name'"
    echo_primary "Region: '$KUBE_REGION'"

    # Ask if they want to change the cluster name or region
    echo_prompt -n "Do you want to change the cluster name or region? Press 'y' to change, or press 'Enter' to proceed within 30 seconds: "
    read -t 30 response < /dev/tty
    if [ $? -eq 0 ]; then
        # User provided input
        if [ -z "$response" ]; then
            # User pressed Enter, proceed
            :
        elif [[ "$response" =~ ^[Yy] ]]; then
            # User wants to change the cluster name and/or region
            # Prompt for new cluster name
            echo_prompt -n "Enter new cluster name [current: $cluster_name]: "
            read new_cluster_name < /dev/tty
            if [ -n "$new_cluster_name" ]; then
                cluster_name="$new_cluster_name"
                KUBE_CLUSTER_NAME="$new_cluster_name"
            fi

            # Prompt for new region
            echo_prompt -n "Enter new region [current: $KUBE_REGION]: "
            read new_region < /dev/tty
            if [ -n "$new_region" ]; then
                KUBE_REGION="$new_region"
            fi
        fi
    else
        # Timeout, no response
        echo_prompt ""
        echo_detail "No response received in 30 seconds. Proceeding with current cluster name and region."
    fi

    # Proceed with creating the cluster
    echo_primary "Creating DigitalOcean Kubernetes cluster '$cluster_name' in region '$KUBE_REGION'... (Expected time: 3-5 minutes)"
    doctl kubernetes cluster create "$cluster_name" --region "$KUBE_REGION" \
        --node-pool "name=main-pool;size=g-4vcpu-16gb-intel;count=3" --wait

    # Wait for nodes to become ready
    check_ready_nodes
}

# Function to prompt for a new cluster name ensuring it's not empty
prompt_new_cluster_name() {
    local new_name
    while true; do
        echo_prompt -n "Enter a new name for the Kubernetes cluster: "
        read new_name < /dev/tty
        if [[ -n "$new_name" ]]; then
            echo "$new_name"
            return 0
        else
            echo_error "Cluster name cannot be empty. Please enter a valid name."
        fi
    done
}

# Function to check if at least three Kubernetes nodes are ready
check_ready_nodes() {
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

# -----------------------------
# New Integration Function
# -----------------------------

# Function to handle cluster creation on DigitalOcean if needed
handle_digitalocean_cluster() {
    echo_primary "Handling DigitalOcean Kubernetes cluster setup."

    # Check if a DigitalOcean Kubernetes cluster is already connected
    cluster_info=$(get_cluster_info) || true

    if [[ "$cluster_info" == *".k8s.ondigitalocean.com"* ]]; then
        echo_info "Existing DigitalOcean Kubernetes cluster detected."
        # Optionally, you can prompt to use the existing cluster or create a new one
        echo_prompt -n "Do you want to use the existing DigitalOcean Kubernetes cluster? Press 'y' to use, 'n' to create a new one: "
        read -r use_existing < /dev/tty
        if [[ "$use_existing" =~ ^[Yy]$ ]]; then
            echo_primary "Using the existing DigitalOcean Kubernetes cluster."
            return
        else
            # Prompt for new cluster name
            new_cluster_name=$(prompt_new_cluster_name)
            # Create a new cluster
            create_cluster_in_digital_ocean "$new_cluster_name"
        fi
    else
        echo_primary "No DigitalOcean Kubernetes cluster detected."

        # Check if DigitalOcean CLI is configured
        if command_exists "doctl"; then
            echo_primary "DigitalOcean CLI (doctl) is installed and configured."
            # Prompt to create a new cluster
            echo_prompt -n "Do you want to create a new Kubernetes cluster on DigitalOcean? Press 'y' to create, or press 'n' to skip: "
            read -r create_cluster < /dev/tty
            if [[ "$create_cluster" =~ ^[Yy]$ ]]; then
                # Prompt for cluster name
                new_cluster_name=$(prompt_new_cluster_name)
                # Create the cluster
                create_cluster_in_digital_ocean "$new_cluster_name"
            else
                echo_primary "Skipping Kubernetes cluster creation on DigitalOcean."
            fi
        else
            echo_error "DigitalOcean CLI (doctl) is not installed or not configured."
            echo_primary "Please install and authenticate 'doctl' if you wish to deploy to DigitalOcean."
        fi
    fi
}

# -----------------------------
# Main Execution Flow
# -----------------------------

echo_info "OpenGovernance installation script started."

check_dependencies
check_provider_clis

# Handle DigitalOcean cluster setup if DigitalOcean is among available platforms
if [[ " ${AVAILABLE_PLATFORMS[*]} " == *"DigitalOcean"* ]]; then
    handle_digitalocean_cluster
fi

detect_kubernetes_provider_and_deploy

echo_primary "OpenGovernance installation script completed successfully."

# Exit script successfully
exit 0