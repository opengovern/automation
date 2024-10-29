#!/usr/bin/env bash

# -----------------------------
# Configuration Variables
# -----------------------------
# Default Kubernetes namespace for OpenGovernance
KUBE_NAMESPACE="opengovernance"

# Default Kubernetes cluster name for OpenGovernance
KUBE_CLUSTER_NAME="opengovernance"

# Default DigitalOcean Kubernetes cluster region for OpenGovernance
DIGITALOCEAN_REGION="nyc3"

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
UNAVAILABLE_PLATFORMS=()
PROVIDER_CONFIGS=()
PROVIDER_ERRORS=()

# Initialize variables
INFRA_DIR="${INFRA_DIR:-$HOME/opengovernance_infrastructure}"  # Default infrastructure directory
INFRA_TOOL=""  # Will be set to 'terraform' or 'tofu' based on availability

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

    for tool in "${required_tools[@]}"; do
        if ! command_exists "$tool"; then
            echo_error "$tool is required but not installed."
            MISSING_TOOLS+=("$tool")
        fi
    done

    if ! command_exists "terraform" && ! command_exists "tofu"; then
        echo_error "Neither Terraform nor OpenTofu is installed."
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
    local get_config_command="$4"

    if command_exists "$cli_command"; then
        if eval "$cli_check_command" >/dev/null 2>&1; then
            echo_info "$provider_name CLI is installed and configured."
            AVAILABLE_PLATFORMS+=("$provider_name")
            # Get the configuration info
            local config_info
            config_info=$(eval "$get_config_command" 2>/dev/null) || config_info="Unknown"
            PROVIDER_CONFIGS+=("$config_info")
        else
            echo_error "$provider_name CLI is installed but not fully configured."
            UNAVAILABLE_PLATFORMS+=("$provider_name")
            PROVIDER_ERRORS+=("$provider_name: CLI not configured")
        fi
    else
        echo_info "$provider_name CLI is not installed."
        UNAVAILABLE_PLATFORMS+=("$provider_name")
        PROVIDER_ERRORS+=("$provider_name: CLI not installed")
    fi
}

# Function to check cloud provider CLIs
check_provider_clis() {
    AVAILABLE_PLATFORMS=()
    PROVIDER_CONFIGS=()
    UNAVAILABLE_PLATFORMS=()
    PROVIDER_ERRORS=()

    check_provider_cli "AWS" "aws" "aws sts get-caller-identity" \
        "aws sts get-caller-identity --query 'Account' --output text | awk '{print \"Account ID: \" \$1}'"
    check_provider_cli "Azure" "az" "az account show" \
        "az account show --query '{SubscriptionId:id, TenantId:tenantId}' -o json | jq -r 'to_entries[] | \"\(.key): \(.value)\"' | paste -sd ', ' -"
    check_provider_cli "GCP" "gcloud" "gcloud auth list --filter=status:ACTIVE --format='value(account)'" \
        "gcloud config list --format='value(core.project)' || echo 'Unknown Project'"
    check_provider_cli "DigitalOcean" "doctl" "doctl account get" \
        "doctl account get --format UUID,Email --no-header | awk '{print \"UUID: \" \$1 \", Email: \" \$2}'"

    # List unavailable platforms with reasons
    if [[ ${#UNAVAILABLE_PLATFORMS[@]} -ne 0 ]]; then
        echo_primary "The following providers are not available:"
        for error in "${PROVIDER_ERRORS[@]}"; do
            echo_detail "$error"
        done
    fi

    # Proceed even if no providers are available
}

# Function to check if kubectl is configured
is_kubectl_configured() {
    if kubectl cluster-info >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Function to check if OpenGovernance is installed
check_opengovernance_installation() {
    # Check if OpenGovernance Helm repo is added and OpenGovernance is installed
    if helm repo list | grep -qw "opengovernance" && helm ls -n "$KUBE_NAMESPACE" | grep -qw opengovernance; then
        # Ensure jq is installed
        if ! command -v jq &> /dev/null; then
            echo_error "jq is not installed. Please install jq to enable JSON parsing."
            exit 1
        fi

        # Check Helm release status using jq
        local helm_release_status
        helm_release_status=$(helm list -n "$KUBE_NAMESPACE" --filter '^opengovernance$' -o json | jq -r '.[0].status // "unknown"')

        if [ "$helm_release_status" == "deployed" ]; then
            echo_error "An existing OpenGovernance installation was found. Unable to proceed."
            exit 1  # Exit the script with an error
        elif [ "$helm_release_status" == "failed" ]; then
            echo_error "OpenGovernance is installed but not in 'deployed' state (current status: $helm_release_status)."
            exit 1
        else
            echo_error "OpenGovernance is in an unexpected state ('$helm_release_status')."
            exit 1
        fi
    else
        echo_info "Checking for any existing OpenGovernance Installation...No existing Installations found."
        return 1
    fi
}

get_cluster_info() {
    # Check if a Kubernetes context is set and kubectl can connect to a cluster
    if kubectl config current-context > /dev/null 2>&1; then
        # Verify if kubectl can communicate with the cluster
        if kubectl cluster-info > /dev/null 2>&1; then
            # Extract and display the control plane URL for further analysis
            local control_plane_url
            control_plane_url=$(kubectl cluster-info | grep -i "control plane" | awk '{print $NF}' || true)
            
            if [[ -n "$control_plane_url" ]]; then
                echo "$control_plane_url"
            else
                echo_error "Unable to determine control plane URL."
                return 1
            fi
        else
            echo_error "Kubernetes cluster is unreachable. Please check your connection."
            return 1
        fi
    else
        echo_error "No Kubernetes context is currently set in kubectl."
        return 1
    fi
}

# Function to detect Kubernetes provider and deploy
detect_kubernetes_provider_and_deploy() {
    local cluster_info
    # Get cluster_info from existing function
    cluster_info=$(get_cluster_info) || true

    # Get current context, cluster name, and cluster server using kubectl
    current_context=$(kubectl config current-context 2>/dev/null) || true
    if [[ -n "$current_context" ]]; then
        # Get cluster name associated with the current context
        cluster_name=$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$current_context\")].context.cluster}")
        # Get cluster server endpoint
        cluster_server=$(kubectl config view -o jsonpath="{.clusters[?(@.name==\"$cluster_name\")].cluster.server}")
        # Append cluster information to cluster_info
        cluster_info="$cluster_info $current_context $cluster_name $cluster_server"
    fi

    if [[ -z "$cluster_info" ]]; then
        echo_primary "Unable to retrieve cluster information."
        prompt_kubectl_setup
        return
    fi

    echo_info "Cluster control plane information: $cluster_info"

    case "$cluster_info" in
        *".azmk8s.io"*|*"azure"*)
            echo_primary "Detected AKS (Azure) cluster."
            ;;
        *".eks.amazonaws.com"*|*"amazonaws.com"*)
            echo_primary "Detected EKS (AWS) cluster."
            ;;
        *".gke.io"*|*"gke"*)
            echo_primary "Detected GKE (GCP) cluster."
            ;;
        *".k8s.ondigitalocean.com"*|*"digitalocean"*|*"do-"*)
            echo_primary "Detected DigitalOcean Kubernetes cluster."
            ;;
        *"minikube"*)
            echo_primary "Detected Minikube cluster."
            ;;
        *"kind"*)
            echo_primary "Detected Kind cluster."
            ;;
        *)
            echo_primary "Unable to identify Kubernetes provider."
            ;;
    esac

    # Ask user if they want to deploy to the existing cluster or create a new one
    echo_prompt "Do you want to deploy OpenGovernance to the existing Kubernetes cluster or create a new cluster?"
    echo_prompt "1. Deploy to existing cluster"
    echo_prompt "2. Create a new cluster"
    echo_prompt "3. Exit"

    read -p "Select an option (1-3): " deploy_choice
    case "$deploy_choice" in
        1)
            # Check if OpenGovernance is already installed
            if check_opengovernance_installation; then
                # If installation exists, the function will exit
                :
            else
                # If no installation exists, determine the provider and execute provider-specific scripts
                determine_and_deploy_provider "$cluster_info"
            fi
            ;;
        2)
            # Proceed to provider selection for creating a new cluster
            check_provider_clis
            choose_deployment
            ;;
        3)
            echo_primary "Exiting."
            exit 0
            ;;
        *)
            echo_error "Invalid selection. Exiting."
            exit 1
            ;;
    esac
}

# Function to determine provider from cluster_info and deploy accordingly
determine_and_deploy_provider() {
    local cluster_info="$1"

    case "$cluster_info" in
        *".azmk8s.io"*|*"azure"*)
            echo_primary "Deploying OpenGovernance to Azure."
            deploy_via_curl "azure"
            ;;
        *".eks.amazonaws.com"*|*"amazonaws.com"*)
            echo_primary "Deploying OpenGovernance to AWS."
            deploy_via_curl "aws"
            ;;
        *".gke.io"*|*"gke"*)
            echo_primary "Deploying OpenGovernance to GCP."
            deploy_via_curl "gcp"
            ;;
        *".k8s.ondigitalocean.com"*|*"digitalocean"*|*"do-"*)
            echo_primary "Deploying OpenGovernance to DigitalOcean."
            deploy_to_digitalocean
            ;;
        *"minikube"*)
            echo_primary "Deploying OpenGovernance to Minikube."
            if warn_minikube_kind "Minikube"; then
                install_opengovernance_with_helm
            else
                echo_primary "Deployment aborted by user."
                exit 0
            fi
            ;;
        *"kind"*)
            echo_primary "Deploying OpenGovernance to Kind."
            if warn_minikube_kind "Kind"; then
                install_opengovernance_with_helm
            else
                echo_primary "Deployment aborted by user."
                exit 0
            fi
            ;;
        *)
            echo_error "Unable to identify Kubernetes provider. Cannot proceed with deployment."
            exit 1
            ;;
    esac
}

# Function to prompt user to set up kubectl
prompt_kubectl_setup() {
    echo_primary "Unable to determine the Kubernetes provider."
    echo_primary "Please ensure that kubectl is installed and configured to connect to your Kubernetes cluster."
    echo_primary "Visit https://kubernetes.io/docs/tasks/tools/ to install and configure kubectl."
    exit 1
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
    echo_primary "Where would you like to deploy OpenGovernance to?"

    local option=1
    local opts=()

    for i in "${!AVAILABLE_PLATFORMS[@]}"; do
        local platform="${AVAILABLE_PLATFORMS[$i]}"
        local config_info="${PROVIDER_CONFIGS[$i]}"
        echo_primary "$option. $platform ($config_info)"
        opts+=("$platform")
        ((option++))
    done

    # If no available platforms, inform the user
    if [[ ${#AVAILABLE_PLATFORMS[@]} -eq 0 ]]; then
        echo_primary "No available platforms to deploy. Exiting."
        exit 1
    fi

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
                deploy_to_digitalocean
                ;;
            *)
                echo_error "Unsupported platform: $selected_platform"
                ;;
        esac
        break
    done
}

# Function to check if OpenGovernance is already installed
check_opengovernance_installation() {
    # Check if OpenGovernance Helm repo is added and OpenGovernance is installed
    if helm repo list | grep -qw "opengovernance" && helm ls -n "$KUBE_NAMESPACE" | grep -qw opengovernance; then
        # Ensure jq is installed
        if ! command -v jq &> /dev/null; then
            echo_error "jq is not installed. Please install jq to enable JSON parsing."
            exit 1
        fi

        # Check Helm release status using jq
        local helm_release_status
        helm_release_status=$(helm list -n "$KUBE_NAMESPACE" --filter '^opengovernance$' -o json | jq -r '.[0].status // "unknown"')

        if [ "$helm_release_status" == "deployed" ]; then
            echo_error "An existing OpenGovernance installation was found. Unable to proceed."
            exit 1  # Exit the script with an error
        elif [ "$helm_release_status" == "failed" ]; then
            echo_error "OpenGovernance is installed but not in 'deployed' state (current status: $helm_release_status)."
            exit 1
        else
            echo_error "OpenGovernance is in an unexpected state ('$helm_release_status')."
            exit 1
        fi
    else
        echo_info "Checking for any existing OpenGovernance Installation...No existing Installations found."
        return 1
    fi
}

# Function to deploy to AWS
deploy_to_aws() {
    check_terraform_or_opentofu
    prepare_infrastructure_directory "aws"
    deploy_infrastructure_to_aws
    install_opengovernance_with_helm
}

# Function to check if Terraform or OpenTofu is installed
check_terraform_or_opentofu() {
    if command_exists "terraform"; then
        INFRA_TOOL="terraform"
        echo_info "Terraform is installed."
    elif command_exists "tofu"; then
        INFRA_TOOL="tofu"
        echo_info "OpenTofu is installed."
    else
        echo_error "Neither Terraform nor OpenTofu is installed. Please install one of them and retry."
        exit 1
    fi
}

prepare_infrastructure_directory() {
    local provider="$1"
    # Set the infrastructure directory
    INFRA_DIR="${INFRA_DIR:-$HOME/deploy-opengovernance}"

    # Clone or update the infrastructure repository
    if [ -d "$INFRA_DIR" ]; then
        echo_info "Infrastructure directory exists at $INFRA_DIR. Updating repository..."
        cd "$INFRA_DIR" || { echo_error "Failed to navigate to $INFRA_DIR"; return 1; }
        git pull
    else
        echo_info "Cloning infrastructure repository to $INFRA_DIR..."
        git clone https://github.com/opengovern/deploy-opengovernance.git "$INFRA_DIR"
    fi

    # Set and navigate to the provider-specific infrastructure directory
    INFRA_DIR="$INFRA_DIR/$provider/infrastructure"
    if [ -d "$INFRA_DIR" ]; then
        cd "$INFRA_DIR" || { echo_error "Failed to navigate to $INFRA_DIR"; return 1; }
    else
        echo_error "Expected directory $INFRA_DIR does not exist. Clone might have failed."
        return 1
    fi
}

# Function to deploy infrastructure to AWS
deploy_infrastructure_to_aws() {
    echo_info "Deploying infrastructure to AWS. This step may take 10-15 minutes..."

    if [ "$INFRA_TOOL" == "terraform" ]; then
        echo_info "Using Terraform for deployment."

        terraform init && terraform plan && terraform apply --auto-approve || {
            echo_error "Terraform deployment failed."
            return 1
        }

    elif [ "$INFRA_TOOL" == "tofu" ]; then
        echo_info "Using OpenTofu for deployment."

        tofu init && tofu plan && tofu apply -auto-approve || {
            echo_error "OpenTofu deployment failed."
            return 1
        }
    else
        echo_error "Unsupported infrastructure tool: $INFRA_TOOL"
        return 1
    fi

    echo_info "Configuring kubectl to connect to the new EKS cluster..."
    eval "$("$INFRA_TOOL" output -raw configure_kubectl)"
}

# Function to install OpenGovernance with Helm
install_opengovernance_with_helm() {

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
        -n "$KUBE_NAMESPACE" --create-namespace --timeout=15m --wait; then  # Timeout increased to 15m
        echo_error "Helm installation failed."
        exit 1
    fi

    echo_detail "OpenGovernance installed successfully."

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

# Function to deploy to DigitalOcean (Updated)
deploy_to_digitalocean() {
    # Ensure required variables are set
    DIGITALOCEAN_REGION="${DIGITALOCEAN_REGION:-nyc1}"
    KUBE_CLUSTER_NAME="${KUBE_CLUSTER_NAME:-opengovernance}"

    # Check if the cluster exists
    if doctl kubernetes cluster list --format Name --no-header | grep -qw "^$KUBE_CLUSTER_NAME$"; then
        echo_error "A Kubernetes cluster named '$KUBE_CLUSTER_NAME' already exists."

        # Prompt user for choice
        echo_primary "Choose an option for deploying to DigitalOcean Kubernetes cluster:"
        echo_primary "1. Use existing cluster '$KUBE_CLUSTER_NAME'"
        echo_primary "2. Create a new cluster"
        echo_primary "3. Exit"

        read -p "Select an option (1-3): " do_option
        case "$do_option" in
            1)
                echo_primary "Using existing cluster '$KUBE_CLUSTER_NAME'."
                # Check if OpenGovernance is already installed
                if check_opengovernance_installation; then
                    # If installation exists, the function will exit
                    :
                else
                    # If no installation exists, determine the provider and execute provider-specific scripts
                    local cluster_info="digitalocean"
                    determine_and_deploy_provider "$cluster_info"
                fi
                # Retrieve kubeconfig for the cluster
                doctl kubernetes cluster kubeconfig save "$KUBE_CLUSTER_NAME"
                ;;
            2)
                # Prompt user for new cluster name
                echo_prompt -n "Enter the name for the new DigitalOcean Kubernetes cluster: "
                read -r new_cluster_name < /dev/tty
                if [[ -z "$new_cluster_name" ]]; then
                    echo_error "Cluster name cannot be empty. Exiting."
                    exit 1
                fi
                create_cluster_digitalocean "$new_cluster_name"
                ;;
            3)
                echo_primary "Exiting."
                exit 0
                ;;
            *)
                echo_error "Invalid selection. Exiting."
                exit 1
                ;;
        esac
    else
        # Cluster does not exist, prompt user to create or exit
        echo_primary "DigitalOcean Kubernetes cluster '$KUBE_CLUSTER_NAME' does not exist."

        echo_primary "Choose an option:"
        echo_primary "1. Create a new cluster named '$KUBE_CLUSTER_NAME'"
        echo_primary "2. Exit"

        read -p "Select an option (1-2): " do_option
        case "$do_option" in
            1)
                create_cluster_digitalocean "$KUBE_CLUSTER_NAME"
                ;;
            2)
                echo_primary "Exiting."
                exit 0
                ;;
            *)
                echo_error "Invalid selection. Exiting."
                exit 1
                ;;
        esac
    fi

    # Wait for nodes to be ready
    check_ready_nodes "DigitalOcean"

    # Proceed to install OpenGovernance with Helm
    install_opengovernance_with_helm
}

# Function to create a Kubernetes cluster on DigitalOcean
create_cluster_digitalocean() {
    local cluster_name="$1"

    # Before creating the cluster, provide the region and cluster name
    echo_primary "Cluster Name: '$cluster_name'"
    echo_primary "Region: '$DIGITALOCEAN_REGION'"

    # Ask if they want to change the cluster name or region
    echo_prompt -n "Change cluster name or region? Press 'y' to change, or 'Enter' to proceed (auto-continue in 30s): "
    read -t 30 response < /dev/tty
    if [ $? -eq 0 ]; then
        # User provided input
        if [ -z "$response" ]; then
            # User pressed Enter, proceed
            :
        elif [[ "$response" =~ ^[Yy]$ ]]; then
            # User wants to change the cluster name and/or region
            # Prompt for new cluster name
            echo_prompt -n "Enter new cluster name [current: $cluster_name]: "
            read new_cluster_name < /dev/tty
            if [ -n "$new_cluster_name" ]; then
                cluster_name="$new_cluster_name"
                KUBE_CLUSTER_NAME="$new_cluster_name"
            fi

            # Prompt for new region
            echo_prompt -n "Enter new region [current: $DIGITALOCEAN_REGION]: "
            read new_region < /dev/tty
            if [ -n "$new_region" ]; then
                DIGITALOCEAN_REGION="$new_region"
            fi
        fi
    else
        # Timeout, no response
        echo_prompt ""
        echo_detail "No response received in 30 seconds. Proceeding with current cluster name and region."
    fi

    # Proceed with creating the cluster
    echo_primary "Creating DigitalOcean Kubernetes cluster '$cluster_name' in region '$DIGITALOCEAN_REGION'... (Expected time: 3-5 minutes)"
    doctl kubernetes cluster create "$cluster_name" --region "$DIGITALOCEAN_REGION" \
        --node-pool "name=main-pool;size=g-4vcpu-16gb-intel;count=3" --wait

    # Save kubeconfig for the cluster
    doctl kubernetes cluster kubeconfig save "$cluster_name"

    # Wait for nodes to become ready
    check_ready_nodes "DigitalOcean"
}

# Function to check if Kubernetes nodes are ready, with specific checks for cloud providers, Minikube, and Kind
check_ready_nodes() {
    local provider="$1"
    local required_nodes=3
    local attempts=0
    local max_attempts=10  # 10 attempts * 30 seconds = 5 minutes
    local sleep_time=30

    echo_info "Checking if at least $required_nodes Kubernetes nodes are ready for $provider..."

    if [[ "$provider" == "Minikube" || "$provider" == "Kind" ]]; then
        # For Minikube and Kind, no strict node requirement
        return 0
    fi

    while [ $attempts -lt $max_attempts ]; do
        READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready ')
        
        if [ "$READY_NODES" -ge $required_nodes ]; then
            echo_info "$provider cluster: Required nodes are ready. ($READY_NODES nodes)"
            return 0
        fi

        attempts=$((attempts + 1))
        echo_detail "Waiting for nodes to become ready on $provider... ($attempts/$max_attempts, currently $READY_NODES node(s) ready)"
        sleep $sleep_time
    done

    echo_error "At least $required_nodes Kubernetes nodes must be ready for $provider, but only $READY_NODES node(s) are ready after $((max_attempts * sleep_time / 60)) minutes."
    echo_warning "$provider requires at least 3 nodes (4 vCPUs, 16GB RAM each) for optimal performance with OpenGovernance."
    echo_primary "Please ensure 3 nodes are ready before proceeding."
    exit 1
}

# Function to warn user on Minikube or Kind deployment
warn_minikube_kind() {
    local provider="$1"
    echo_warning "Detected $provider cluster."
    echo_warning "No minimum node requirement for $provider, but note:"
    echo_warning "OpenGovernance uses OpenSearch with 3 nodes, which can be resource-intensive on desktops/laptops."
    echo_warning "We strongly recommend at least 16GB of RAM for stability."
    
    read -p "Do you wish to proceed? (yes/no): " proceed
    if [[ "$proceed" == "yes" ]]; then
        return 0
    else
        return 1
    fi
}

# -----------------------------
# Main Execution Flow
# -----------------------------

echo_info "OpenGovernance installation script started."

check_dependencies

if is_kubectl_configured; then
    # kubectl is connected to a cluster
    detect_kubernetes_provider_and_deploy
else
    # kubectl is not connected to a cluster
    check_provider_clis
    # Allow user to choose deployment
    choose_deployment
fi

echo_primary "OpenGovernance installation script completed successfully."

# Exit script successfully
exit 0
