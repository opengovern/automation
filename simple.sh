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

    check_provider_cli "AWS" "aws" "aws sts get-caller-identity" "aws sts get-caller-identity --query 'Account' --output text | awk '{print \"Account ID: \" \$1}'"
    check_provider_cli "Azure" "az" "az account show" "az account show --query '{SubscriptionId:id, TenantId:tenantId}' -o json | jq -r 'to_entries[] | \"\(.key): \(.value)\"' | paste -sd ', ' -"
    check_provider_cli "GCP" "gcloud" "gcloud auth list --filter=status:ACTIVE --format='value(account)'" "gcloud config list --format='value(core.project)' || echo 'Unknown Project'"
    check_provider_cli "DigitalOcean" "doctl" "doctl auth list" "doctl account get --format UUID,Email --no-header | awk '{print \"UUID: \" \$1 \", Email: \" \$2}'"

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
        echo_primary "Unable to retrieve cluster info."
        choose_deployment
        return
    fi

    echo_info "Cluster info: $cluster_info"

    case "$cluster_info" in
        *".azmk8s.io"*|*"azure"*)
            echo_primary "Cluster on AKS (Azure). Deploying OpenGovernance to Azure."
            deploy_via_curl "azure"
            ;;
        *".eks.amazonaws.com"*|*"amazonaws.com"*)
            echo_primary "Cluster on EKS (AWS). Deploying OpenGovernance to AWS."
            deploy_via_curl "aws"
            ;;
        *".gke.io"*|*"gke"*)
            echo_primary "Cluster on GKE (GCP). Deploying OpenGovernance to GCP."
            deploy_via_curl "gcp"
            ;;
        *".k8s.ondigitalocean.com"*|*"digitalocean"*|*"do-"*)
            echo_primary "Cluster on DigitalOcean. Deploying OpenGovernance to DigitalOcean."
            deploy_via_curl "digitalocean"
            ;;
        *)
            echo_primary "Kubernetes provider undetermined."
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

# [Include any other necessary functions, such as install_opengovernance_with_helm, etc.]

# -----------------------------
# Main Execution Flow
# -----------------------------

echo_info "OpenGovernance installation script started."

check_dependencies
check_provider_clis

if is_kubectl_configured; then
    detect_kubernetes_provider_and_deploy
else
    echo_primary "kubectl is not configured."
    choose_deployment
fi

echo_primary "OpenGovernance installation script completed successfully."

# Exit script successfully
exit 0