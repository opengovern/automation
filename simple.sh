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
PROVIDER_CONFIGS=()

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
        fi
    else
        echo_info "$provider_name CLI is not installed."
    fi
}

# Function to check cloud provider CLIs
check_provider_clis() {
    AVAILABLE_PLATFORMS=()
    PROVIDER_CONFIGS=()

    check_provider_cli "AWS" "aws" "aws sts get-caller-identity" \
        "aws sts get-caller-identity --query 'Account' --output text | awk '{print \"Account ID: \" \$1}'"
    check_provider_cli "Azure" "az" "az account show" \
        "az account show --query '{SubscriptionId:id, TenantId:tenantId}' -o json | jq -r 'to_entries[] | \"\(.key): \(.value)\"' | paste -sd ', ' -"
    check_provider_cli "GCP" "gcloud" "gcloud auth list --filter=status:ACTIVE --format='value(account)'" \
        "gcloud config list --format='value(core.project)' || echo 'Unknown Project'"
    check_provider_cli "DigitalOcean" "doctl" "doctl account get" \
        "doctl account get --format UUID,Email --no-header | awk '{print \"UUID: \" \$1 \", Email: \" \$2}'"

    # Verify at least one provider is available
    if [[ ${#AVAILABLE_PLATFORMS[@]} -eq 0 ]]; then
        echo_error "No configured CLI tools found."
        echo_primary "Please visit https://docs.opengovernance.io to install and configure the required tools."
        exit 1
    fi
}

# Function to check if kubectl is configured
is_kubectl_configured() {
    if kubectl cluster-info >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

get_cluster_info() {
    # Check if kubectl is connected to a cluster
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
        echo_error "There is no existing Kubernetes Cluster"
        return 1
    fi
}

# Function to detect Kubernetes provider and deploy
detect_kubernetes_provider_and_deploy() {
    local cluster_info
    cluster_info=$(get_cluster_info) || true

    if [[ -z "$cluster_info" ]]; then
        echo_primary "Unable to retrieve cluster information."
        choose_deployment
        return
    fi

    echo_info "Cluster control plane URL: $cluster_info"

    case "$cluster_info" in
        *".azmk8s.io"*|*"azure"*)
            echo_primary "Detected AKS (Azure) cluster. Deploying OpenGovernance to Azure."
            deploy_via_curl "azure"
            ;;
        *".eks.amazonaws.com"*|*"amazonaws.com"*)
            echo_primary "Detected EKS (AWS) cluster. Deploying OpenGovernance to AWS."
            deploy_via_curl "aws"
            ;;
        *".gke.io"*|*"gke"*)
            echo_primary "Detected GKE (GCP) cluster. Deploying OpenGovernance to GCP."
            deploy_via_curl "gcp"
            ;;
        *".k8s.ondigitalocean.com"*|*"digitalocean"*|*"do-"*)
            echo_primary "Detected DigitalOcean Kubernetes cluster. Deploying OpenGovernance to DigitalOcean."
            deploy_to_digitalocean
            ;;
        *)
            echo_primary "Unable to identify Kubernetes provider."
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
    echo_primary "Multiple Cloud Platforms are available"
    echo_primary "Which platform would you like to deploy OpenGovernance to?"

    local option=1
    local opts=()

    for i in "${!AVAILABLE_PLATFORMS[@]}"; do
        local platform="${AVAILABLE_PLATFORMS[$i]}"
        local config_info="${PROVIDER_CONFIGS[$i]}"
        echo_primary "$option. $platform ($config_info)"
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
                deploy_to_aws
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
    # Ensure jq is installed
    if ! command_exists "jq"; then
        echo_error "jq is required but not installed. Please install jq to enable JSON parsing."
        exit 1
    fi

    # Set KUBE_NAMESPACE if not already set
    KUBE_NAMESPACE="${KUBE_NAMESPACE:-opengovernance}"

    # Check if OpenGovernance Helm repo is added and OpenGovernance is installed
    if helm repo list | grep -qw "opengovernance" && helm ls -n "$KUBE_NAMESPACE" | grep -qw opengovernance; then
        # Check Helm release status using jq
        local helm_release_status
        helm_release_status=$(helm list -n "$KUBE_NAMESPACE" --filter '^opengovernance$' -o json | jq -r '.[0].status // "unknown"')

        if [ "$helm_release_status" == "deployed" ]; then
            echo_error "An existing OpenGovernance installation was found in namespace '$KUBE_NAMESPACE'. Unable to proceed."
            exit 1  # Exit the script with an error
        elif [ "$helm_release_status" == "failed" ]; then
            echo_error "OpenGovernance is installed but not in 'deployed' state (current status: $helm_release_status)."
            exit 1
        else
            echo_error "OpenGovernance is in an unexpected state ('$helm_release_status')."
            exit 1
        fi
    else
        echo_info "No existing OpenGovernance installation found in namespace '$KUBE_NAMESPACE'. Proceeding with deployment."
        return 0
    fi
}

# Function to deploy to AWS
deploy_to_aws() {
    check_terraform_or_opentofu
    prepare_infrastructure_directory
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

    # Set and navigate to the AWS infrastructure directory
    INFRA_DIR="$INFRA_DIR/aws/infrastructure"
    if [ -d "$INFRA_DIR" ]; then
        cd "$INFRA_DIR" || { echo_error "Failed to navigate to $INFRA_DIR/aws/infrastructure"; return 1; }
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

# Function to deploy to DigitalOcean (from previous integration)
deploy_to_digitalocean() {
    # Ensure required variables are set
    KUBE_REGION="${KUBE_REGION:-nyc1}"
    KUBE_CLUSTER_NAME="${KUBE_CLUSTER_NAME:-opengovernance-cluster}"

    # Check if the cluster exists
    if doctl kubernetes cluster list --format Name --no-header | grep -qw "^$KUBE_CLUSTER_NAME$"; then
        echo_error "A Kubernetes cluster named '$KUBE_CLUSTER_NAME' already exists."

        # Prompt user to use existing cluster or exit
        echo_prompt -n "Do you want to use the existing cluster '$KUBE_CLUSTER_NAME'? Press 'y' to use, or any other key to exit: "
        read -r use_existing < /dev/tty
        if [[ "$use_existing" =~ ^[Yy]$ ]]; then
            echo_primary "Using existing cluster '$KUBE_CLUSTER_NAME'."
            # Retrieve kubeconfig for the cluster
            doctl kubernetes cluster kubeconfig save "$KUBE_CLUSTER_NAME"
        else
            echo_primary "Exiting."
            exit 1
        fi
    else
        # Create the cluster since it doesn't exist
        create_cluster "$KUBE_CLUSTER_NAME"
    fi

    # Wait for nodes to be ready
    check_ready_nodes

    # Proceed to install OpenGovernance with Helm
    install_opengovernance_with_helm
}

# Function to create a Kubernetes cluster on DigitalOcean
create_cluster() {
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

    # Save kubeconfig for the cluster
    doctl kubernetes cluster kubeconfig save "$cluster_name"

    # Wait for nodes to become ready
    check_ready_nodes
}

# Function to check if Kubernetes nodes are ready
check_ready_nodes() {
    local attempts=0
    local max_attempts=10  # 10 attempts * 30 seconds = 5 minutes
    local sleep_time=30

    while [ $attempts -lt $max_attempts ]; do
        READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready ')
        if [ "$READY_NODES" -ge 3 ]; then
            echo_info "Required nodes are ready. ($READY_NODES nodes)"
            return 0
        fi

        attempts=$((attempts + 1))
        echo_detail "Waiting for nodes to become ready... ($attempts/$max_attempts)"
        sleep $sleep_time
    done

    echo_error "At least three Kubernetes nodes must be ready, but only $READY_NODES node(s) are ready after $((max_attempts * sleep_time / 60)) minutes."
    exit 1
}

# -----------------------------
# Main Execution Flow
# -----------------------------

echo_info "OpenGovernance installation script started."

check_dependencies
check_provider_clis

# Check if OpenGovernance is already installed
check_opengovernance_installation

if is_kubectl_configured; then
    detect_kubernetes_provider_and_deploy
else
    echo_primary "kubectl is not configured."
    choose_deployment
fi

echo_primary "OpenGovernance installation script completed successfully."

# Exit script successfully
exit 0