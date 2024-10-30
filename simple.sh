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

    if [[ ${#MISSING_TOOLS[@]} -ne 0 ]]; then
        echo_error "Missing required tools: ${MISSING_TOOLS[*]}"
        echo_primary "Please install the missing tools and re-run the script."
        exit 1
    fi

    echo_info "All required tools are installed."
}

# Function to check provider CLI and get minimal and detailed info
check_provider_cli() {
    local provider_name="$1"
    local cli_command="$2"
    local cli_check_command="$3"

    if command_exists "$cli_command"; then
        if eval "$cli_check_command" >/dev/null 2>&1; then
            echo_info "$provider_name CLI is installed and configured."
            if [[ "$provider_name" == "AWS" ]]; then
                local account_id iam_arn iam_user
                account_id=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null || echo "Unknown")
                iam_arn=$(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null || echo "Unknown")
                iam_user=$(echo "$iam_arn" | awk -F'/' '{print $NF}')
                AWS_AVAILABLE="yes"
                AWS_MINIMAL_DETAIL="$account_id / $iam_user"
                AWS_DETAILED_INFO="Account ID: $account_id, IAM Principal ARN: $iam_arn"
            elif [[ "$provider_name" == "Azure" ]]; then
                local subscription_name subscription_id tenant_id
                subscription_name=$(az account show --query 'name' -o tsv 2>/dev/null || echo "Unknown")
                subscription_id=$(az account show --query 'id' -o tsv 2>/dev/null || echo "Unknown")
                tenant_id=$(az account show --query 'tenantId' -o tsv 2>/dev/null || echo "Unknown")
                AZURE_AVAILABLE="yes"
                AZURE_MINIMAL_DETAIL="$subscription_name"
                AZURE_DETAILED_INFO="Subscription Name: $subscription_name, Subscription ID: $subscription_id, Tenant ID: $tenant_id"
            elif [[ "$provider_name" == "GCP" ]]; then
                local project_id compute_region
                project_id=$(gcloud config get-value project 2>/dev/null || echo "Unknown")
                compute_region=$(gcloud config get-value compute/region 2>/dev/null || echo "Unknown")
                GCP_AVAILABLE="yes"
                GCP_MINIMAL_DETAIL="$project_id"
                GCP_DETAILED_INFO="Project ID: $project_id, Compute Region: $compute_region"
            elif [[ "$provider_name" == "DigitalOcean" ]]; then
                local email uuid
                email=$(doctl account get --format Email --no-header 2>/dev/null || echo "Unknown")
                uuid=$(doctl account get --format UUID --no-header 2>/dev/null || echo "Unknown")
                DIGITALOCEAN_AVAILABLE="yes"
                DIGITALOCEAN_MINIMAL_DETAIL="$email"
                DIGITALOCEAN_DETAILED_INFO="Email: $email, Account UUID: $uuid"
            fi
        else
            echo_error "$provider_name CLI is installed but not fully configured."
            if [[ "$provider_name" == "AWS" ]]; then
                AWS_AVAILABLE="no"
                AWS_ERROR="$provider_name: CLI not configured"
            elif [[ "$provider_name" == "Azure" ]]; then
                AZURE_AVAILABLE="no"
                AZURE_ERROR="$provider_name: CLI not configured"
            elif [[ "$provider_name" == "GCP" ]]; then
                GCP_AVAILABLE="no"
                GCP_ERROR="$provider_name: CLI not configured"
            elif [[ "$provider_name" == "DigitalOcean" ]]; then
                DIGITALOCEAN_AVAILABLE="no"
                DIGITALOCEAN_ERROR="$provider_name: CLI not configured"
            fi
        fi
    else
        echo_info "$provider_name CLI is not installed."
        if [[ "$provider_name" == "AWS" ]]; then
            AWS_AVAILABLE="no"
            AWS_ERROR="$provider_name: CLI not installed"
        elif [[ "$provider_name" == "Azure" ]]; then
            AZURE_AVAILABLE="no"
            AZURE_ERROR="$provider_name: CLI not installed"
        elif [[ "$provider_name" == "GCP" ]]; then
            GCP_AVAILABLE="no"
            GCP_ERROR="$provider_name: CLI not installed"
        elif [[ "$provider_name" == "DigitalOcean" ]]; then
            DIGITALOCEAN_AVAILABLE="no"
            DIGITALOCEAN_ERROR="$provider_name: CLI not installed"
        fi
    fi
}

# Function to check cloud provider CLIs
check_provider_clis() {
    # Initialize provider availability and details
    AWS_AVAILABLE="no"
    AZURE_AVAILABLE="no"
    GCP_AVAILABLE="no"
    DIGITALOCEAN_AVAILABLE="no"

    check_provider_cli "AWS" "aws" "aws sts get-caller-identity"

    check_provider_cli "Azure" "az" "az account show"

    check_provider_cli "GCP" "gcloud" "gcloud auth list --filter=status:ACTIVE --format='value(account)'"

    check_provider_cli "DigitalOcean" "doctl" "doctl account get"
}

# Function to check if kubectl is configured
is_kubectl_configured() {
    if kubectl cluster-info >/dev/null 2>&1; then
        KUBECTL_CONFIGURED=true
        return 0
    else
        KUBECTL_CONFIGURED=false
        return 1
    fi
}

# Function to get cluster information
get_cluster_info() {
    # (Function body remains unchanged)
    if kubectl config current-context > /dev/null 2>&1; then
        if kubectl cluster-info > /dev/null 2>&1; then
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

# Function to detect Kubernetes provider and set context information
detect_kubernetes_provider_and_set_context() {
    # (Function body remains unchanged)
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
        return
    fi

    echo_info "Cluster control plane information: $cluster_info"

    case "$cluster_info" in
        *".azmk8s.io"*|*"azure"*)
            echo_info "Detected AKS (Azure) cluster."
            CURRENT_PROVIDER="Azure"
            ;;
        *".eks.amazonaws.com"*|*"amazonaws.com"*)
            echo_info "Detected EKS (AWS) cluster."
            CURRENT_PROVIDER="AWS"
            ;;
        *".gke.io"*|*"gke"*)
            echo_info "Detected GKE (GCP) cluster."
            CURRENT_PROVIDER="GCP"
            ;;
        *".k8s.ondigitalocean.com"*|*"digitalocean"*|*"do-"*)
            echo_info "Detected DigitalOcean Kubernetes cluster."
            CURRENT_PROVIDER="DigitalOcean"
            ;;
        *"minikube"*)
            echo_info "Detected Minikube cluster."
            CURRENT_PROVIDER="Minikube"
            ;;
        *"kind"*)
            echo_info "Detected Kind cluster."
            CURRENT_PROVIDER="Kind"
            ;;
        *)
            echo_info "Unable to identify Kubernetes provider."
            CURRENT_PROVIDER="Unknown"
            ;;
    esac
}

# Function to display cluster details
display_cluster_details() {
    # (Function body remains unchanged)
    echo_primary "Provider Details:"

    # AWS
    echo_detail "Provider: AWS"
    if [[ "$AWS_AVAILABLE" == "yes" ]]; then
        detailed_info="$AWS_DETAILED_INFO"
        IFS=',' read -ra INFO_ARRAY <<< "$detailed_info"
        for info in "${INFO_ARRAY[@]}"; do
            echo_detail "    $info"
        done
    else
        echo_detail "    ${AWS_ERROR:-CLI not found or not configured.}"
    fi

    # Azure
    echo_detail "Provider: Azure"
    if [[ "$AZURE_AVAILABLE" == "yes" ]]; then
        detailed_info="$AZURE_DETAILED_INFO"
        IFS=',' read -ra INFO_ARRAY <<< "$detailed_info"
        for info in "${INFO_ARRAY[@]}"; do
            echo_detail "    $info"
        done
    else
        echo_detail "    ${AZURE_ERROR:-CLI not found or not configured.}"
    fi

    # GCP
    echo_detail "Provider: GCP"
    if [[ "$GCP_AVAILABLE" == "yes" ]]; then
        detailed_info="$GCP_DETAILED_INFO"
        IFS=',' read -ra INFO_ARRAY <<< "$detailed_info"
        for info in "${INFO_ARRAY[@]}"; do
            echo_detail "    $info"
        done
    else
        echo_detail "    ${GCP_ERROR:-CLI not found or not configured.}"
    fi

    # DigitalOcean
    echo_detail "Provider: DigitalOcean"
    if [[ "$DIGITALOCEAN_AVAILABLE" == "yes" ]]; then
        detailed_info="$DIGITALOCEAN_DETAILED_INFO"
        IFS=',' read -ra INFO_ARRAY <<< "$detailed_info"
        for info in "${INFO_ARRAY[@]}"; do
            echo_detail "    $info"
        done
    else
        echo_detail "    ${DIGITALOCEAN_ERROR:-CLI not found or not configured.}"
    fi

    # Also display kubectl context details
    if [ "$KUBECTL_CONFIGURED" == "true" ]; then
        echo_primary "Kubernetes Cluster Details:"
        echo_detail "    Current Context: $CURRENT_CONTEXT"
        echo_detail "    Cluster Name: $CURRENT_CLUSTER_NAME"
        echo_detail "    Provider: $CURRENT_PROVIDER"
        echo_detail "    Number of Nodes: $NODE_COUNT"
    else
        echo_primary "kubectl is not configured or not connected to a cluster."
    fi
}

# Function to display details for a specific option
display_option_details() {
    # (Function body remains unchanged)
    local option="$1"

    case "$option" in
        "AWS")
            echo_primary "AWS Details:"
            if [[ "$AWS_AVAILABLE" == "yes" ]]; then
                detailed_info="$AWS_DETAILED_INFO"
                IFS=',' read -ra INFO_ARRAY <<< "$detailed_info"
                for info in "${INFO_ARRAY[@]}"; do
                    echo_detail "$info"
                done
            else
                echo_detail "${AWS_ERROR:-CLI not found or not configured.}"
            fi
            ;;
        "Azure")
            echo_primary "Azure Details:"
            if [[ "$AZURE_AVAILABLE" == "yes" ]]; then
                detailed_info="$AZURE_DETAILED_INFO"
                IFS=',' read -ra INFO_ARRAY <<< "$detailed_info"
                for info in "${INFO_ARRAY[@]}"; do
                    echo_detail "$info"
                done
            else
                echo_detail "${AZURE_ERROR:-CLI not found or not configured.}"
            fi
            ;;
        "GCP")
            echo_primary "GCP Details:"
            if [[ "$GCP_AVAILABLE" == "yes" ]]; then
                detailed_info="$GCP_DETAILED_INFO"
                IFS=',' read -ra INFO_ARRAY <<< "$detailed_info"
                for info in "${INFO_ARRAY[@]}"; do
                    echo_detail "$info"
                done
            else
                echo_detail "${GCP_ERROR:-CLI not found or not configured.}"
            fi
            ;;
        "DigitalOcean")
            echo_primary "DigitalOcean Details:"
            if [[ "$DIGITALOCEAN_AVAILABLE" == "yes" ]]; then
                detailed_info="$DIGITALOCEAN_DETAILED_INFO"
                IFS=',' read -ra INFO_ARRAY <<< "$detailed_info"
                for info in "${INFO_ARRAY[@]}"; do
                    echo_detail "$info"
                done
            else
                echo_detail "${DIGITALOCEAN_ERROR:-CLI not found or not configured.}"
            fi
            ;;
        "Kubernetes Cluster")
            echo_primary "Kubernetes Cluster Details:"
            if [ "$KUBECTL_CONFIGURED" == "true" ]; then
                echo_detail "Current Context: $CURRENT_CONTEXT"
                echo_detail "Cluster Name: $CURRENT_CLUSTER_NAME"
                echo_detail "Provider: $CURRENT_PROVIDER"
                echo_detail "Number of Nodes: $NODE_COUNT"
            else
                echo_detail "kubectl is not configured or not connected to a cluster."
            fi
            ;;
        *)
            echo_error "Invalid option selected."
            ;;
    esac
}

# Function to deploy to a specific platform
deploy_to_platform() {
    local platform="$1"
    case "$platform" in
        "AWS")
            echo_primary "Deploying OpenGovernance to AWS."
            ensure_cli_installed "aws" "AWS CLI"
            deploy_via_curl "aws"
            ;;
        "Azure")
            echo_primary "Deploying OpenGovernance to Azure."
            ensure_cli_installed "az" "Azure CLI"
            deploy_via_curl "azure"
            ;;
        "GCP")
            echo_primary "Deploying OpenGovernance to GCP."
            ensure_cli_installed "gcloud" "GCP CLI"
            deploy_via_curl "gcp"
            ;;
        "DigitalOcean")
            echo_primary "Deploying OpenGovernance to DigitalOcean."
            ensure_cli_installed "doctl" "DigitalOcean CLI"
            deploy_to_digitalocean
            ;;
        *)
            echo_error "Unsupported platform: $platform"
            ;;
    esac
}

# Function to ensure provider CLI is installed and configured
ensure_cli_installed() {
    # (Function body remains unchanged)
    local cli_command="$1"
    local cli_name="$2"

    if ! command_exists "$cli_command"; then
        echo_error "$cli_name is required but not installed."
        echo_primary "Please install $cli_name and configure it before proceeding."
        exit 1
    fi

    # Check if CLI is configured
    if [[ "$cli_command" == "aws" ]]; then
        if ! aws sts get-caller-identity >/dev/null 2>&1; then
            echo_error "$cli_name is not configured properly."
            echo_primary "Please configure $cli_name before proceeding."
            exit 1
        fi
    elif [[ "$cli_command" == "az" ]]; then
        if ! az account show >/dev/null 2>&1; then
            echo_error "$cli_name is not configured properly."
            echo_primary "Please configure $cli_name before proceeding."
            exit 1
        fi
    elif [[ "$cli_command" == "gcloud" ]]; then
        if ! gcloud auth list --filter=status:ACTIVE --format='value(account)' >/dev/null 2>&1; then
            echo_error "$cli_name is not configured properly."
            echo_primary "Please configure $cli_name before proceeding."
            exit 1
        fi
    elif [[ "$cli_command" == "doctl" ]]; then
        if ! doctl account get >/dev/null 2>&1; then
            echo_error "$cli_name is not configured properly."
            echo_primary "Please configure $cli_name before proceeding."
            exit 1
        fi
    fi
}

# Function to deploy via curl
deploy_via_curl() {
    # (Function body remains unchanged)
    local provider="$1"
    local script_url="https://raw.githubusercontent.com/opengovern/deploy-opengovernance/main/${provider}/scripts/simple.sh"

    if curl --head --silent --fail "$script_url" >/dev/null; then
        curl -sL "$script_url" | bash -s -- "$KUBE_NAMESPACE"
    else
        echo_error "Deployment script for $provider is not accessible."
        exit 1
    fi
}

# Function to allow user to choose deployment based on available platforms
choose_deployment() {
    # (Function body remains unchanged)
    while true; do
        echo_primary "Where would you like to deploy OpenGovernance to?"

        # Initialize options array
        OPTIONS=()
        option_number=1

        # AWS
        if [[ "$AWS_AVAILABLE" == "yes" ]]; then
            echo_primary "$option_number. AWS ($AWS_MINIMAL_DETAIL)"
        else
            echo_primary "$option_number. AWS (Unavailable)"
        fi
        OPTIONS[$option_number]="AWS"
        ((option_number++))

        # Azure
        if [[ "$AZURE_AVAILABLE" == "yes" ]]; then
            echo_primary "$option_number. Azure ($AZURE_MINIMAL_DETAIL)"
        else
            echo_primary "$option_number. Azure (Unavailable)"
        fi
        OPTIONS[$option_number]="Azure"
        ((option_number++))

        # GCP
        if [[ "$GCP_AVAILABLE" == "yes" ]]; then
            echo_primary "$option_number. GCP ($GCP_MINIMAL_DETAIL)"
        else
            echo_primary "$option_number. GCP (Unavailable)"
        fi
        OPTIONS[$option_number]="GCP"
        ((option_number++))

        # DigitalOcean
        if [[ "$DIGITALOCEAN_AVAILABLE" == "yes" ]]; then
            echo_primary "$option_number. DigitalOcean ($DIGITALOCEAN_MINIMAL_DETAIL)"
        else
            echo_primary "$option_number. DigitalOcean (Unavailable)"
        fi
        OPTIONS[$option_number]="DigitalOcean"
        ((option_number++))

        # Exit
        echo_primary "$option_number. Exit"
        OPTIONS[$option_number]="Exit"
        ((option_number++))

        # Kubernetes Cluster
        if [ "$KUBECTL_CONFIGURED" == "true" ]; then
            NODE_COUNT="${NODE_COUNT:-Unknown}"
            echo_primary "$option_number. Kubernetes Cluster ($CURRENT_PROVIDER / $NODE_COUNT nodes)"
            OPTIONS[$option_number]="Kubernetes Cluster"
            ((option_number++))
        fi

        echo_primary "Press 's' to view cluster and provider details"

        echo_prompt -n "Select an option (1-$((option_number-1))) or press 's' to view details: "

        read -r user_input < /dev/tty

        if [[ "$user_input" =~ ^[sS]$ ]]; then
            display_cluster_details
            continue
        fi

        if ! [[ "$user_input" =~ ^[0-9]+$ ]]; then
            echo_error "Invalid input. Please enter a number between 1 and $((option_number-1))."
            continue
        fi

        if (( user_input < 1 || user_input >= option_number )); then
            echo_error "Invalid choice. Please select a number between 1 and $((option_number-1))."
            continue
        fi

        selected_option="${OPTIONS[$user_input]}"

        if [[ "$selected_option" == "Exit" ]]; then
            echo_primary "Exiting."
            exit 0
        elif [[ "$selected_option" == "Kubernetes Cluster" ]]; then
            # Display details for Kubernetes Cluster
            display_option_details "Kubernetes Cluster"

            # Wait for 15 seconds to allow the user to return to the main menu
            echo_prompt "Press 'b' to return to the main menu within 15 seconds, or any other key to proceed."
            read -t 15 -n 1 -r user_response
            if [[ "$user_response" == "b" ]]; then
                echo_primary "Returning to main menu."
                continue
            else
                install_opengovernance_with_helm
                break
            fi
        else
            # Map selected_option to the correct availability variable
            case "$selected_option" in
                "AWS") available_var="AWS_AVAILABLE" ;;
                "Azure") available_var="AZURE_AVAILABLE" ;;
                "GCP") available_var="GCP_AVAILABLE" ;;
                "DigitalOcean") available_var="DIGITALOCEAN_AVAILABLE" ;;
                *) available_var="" ;;
            esac

            if [[ -n "$available_var" && "${!available_var}" == "yes" ]]; then
                # Display details for the selected option
                display_option_details "$selected_option"

                # Wait for 15 seconds to allow the user to return to the main menu
                echo_prompt "Press 'b' to return to the main menu within 15 seconds, or any other key to proceed."
                read -t 15 -n 1 -r user_response
                if [[ "$user_response" == "b" ]]; then
                    echo_primary "Returning to main menu."
                    continue
                else
                    deploy_to_platform "$selected_option"
                    break
                fi
            else
                echo_error "Platform '$selected_option' is unavailable. Please select another option."
                continue
            fi
        fi
    done
}

# Function to install OpenGovernance with Helm
install_opengovernance_with_helm() {
    echo_primary "Installing OpenGovernance via Helm."

    echo_detail "Adding OpenGovernance Helm repository."
    if ! helm repo add opengovernance https://opengovern.github.io/charts; then
        echo_error "Failed to add OpenGovernance Helm repository."
        exit 1
    fi

    echo_detail "Updating Helm repositories."
    if ! helm repo update; then
        echo_error "Failed to update Helm repositories."
        exit 1
    fi

    echo_detail "Installing OpenGovernance via Helm in namespace '$KUBE_NAMESPACE' (this may take a few minutes)."
    if ! helm install opengovernance opengovernance/opengovernance \
        -n "$KUBE_NAMESPACE" --create-namespace --timeout=15m --wait; then
        echo_error "Helm installation failed."
        exit 1
    fi

    echo_detail "OpenGovernance installed successfully."

    # Provide port-forwarding instructions
    provide_port_forward_instructions
}

# Function to provide port-forwarding instructions
provide_port_forward_instructions() {
    echo_primary "To access OpenGovernance, set up port-forwarding using the following command:"
    echo_prompt "kubectl port-forward -n \"$KUBE_NAMESPACE\" service/nginx-proxy 8080:80"
    echo_prompt "Access OpenGovernance at http://localhost:8080"
    echo_prompt "Use these credentials to sign in: Username: admin@opengovernance.io, Password: password"
}

deploy_to_digitalocean() {
    # Ensure doctl is installed and configured
    ensure_cli_installed "doctl" "DigitalOcean CLI"

    # Create or select a Kubernetes cluster on DigitalOcean
    create_digitalocean_cluster
}

# Function to create or use the default 'opengovernance' Kubernetes cluster on DigitalOcean
create_digitalocean_cluster() {
    local cluster_name="opengovernance"

    # Check if the cluster 'opengovernance' already exists
    if doctl kubernetes cluster get "$cluster_name" >/dev/null 2>&1; then
        echo_primary "A Kubernetes cluster named '$cluster_name' already exists."
        echo_primary "Choose an option:"
        echo_primary "1. Use existing cluster '$cluster_name'"
        echo_primary "2. Create a new cluster"
        echo_primary "3. Exit"

        echo_prompt -n "Select an option (1-3): "
        read -r existing_option < /dev/tty

        case "$existing_option" in
            1)
                echo_primary "Using existing cluster '$cluster_name'."
                # Retrieve kubeconfig for the cluster
                if ! doctl kubernetes cluster kubeconfig save "$cluster_name"; then
                    echo_error "Failed to retrieve kubeconfig for cluster '$cluster_name'."
                    exit 1
                fi
                # Update the global cluster name variable
                KUBE_CLUSTER_NAME="$cluster_name"
                # Proceed to install OpenGovernance with Helm
                install_opengovernance_with_helm
                ;;
            2)
                # Call function to create a new cluster with a unique name
                create_unique_digitalocean_cluster
                ;;
            3)
                echo_primary "Exiting."
                exit 0
                ;;
            *)
                echo_error "Invalid selection. Please choose between 1 and 3."
                create_digitalocean_cluster  # Retry
                ;;
        esac
    else
        # Cluster does not exist, create it automatically
        echo_primary "Creating DigitalOcean Kubernetes cluster '$cluster_name' in region '$DIGITALOCEAN_REGION'..."
        echo_primary "This step may take 3-5 minutes."

        # Create the cluster
        if doctl kubernetes cluster create "$cluster_name" --region "$DIGITALOCEAN_REGION" \
            --node-pool "name=main-pool;size=s-4vcpu-8gb;count=3" --wait; then
            echo_info "Cluster '$cluster_name' created successfully."
        else
            echo_error "Failed to create cluster '$cluster_name'. Please try again."
            exit 1
        fi

        # Save kubeconfig for the cluster
        if ! doctl kubernetes cluster kubeconfig save "$cluster_name"; then
            echo_error "Failed to retrieve kubeconfig for cluster '$cluster_name'."
            exit 1
        fi

        # Update the global cluster name variable
        KUBE_CLUSTER_NAME="$cluster_name"

        # Proceed to install OpenGovernance with Helm
        install_opengovernance_with_helm
    fi
}

# Function to create a unique Kubernetes cluster on DigitalOcean
create_unique_digitalocean_cluster() {
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
        echo_prompt -n "Do you wish to change the region? (yes/no): "
        read -r change_region < /dev/tty

        if [[ "$change_region" =~ ^([yY][eE][sS]|[yY])$ ]]; then
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
            --node-pool "name=main-pool;size=s-4vcpu-8gb;count=3" --wait; then
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

        # Proceed to install OpenGovernance with Helm
        install_opengovernance_with_helm

        # Exit the loop after successful creation and installation
        break
    done
}

# -----------------------------
# Script Initialization
# -----------------------------

# Logging Configuration
DATA_DIR="$HOME/opengovernance_data"
LOGFILE="$DATA_DIR/opengovernance_install.log"

# Ensure the data directory exists
mkdir -p "$DATA_DIR" || { echo "Failed to create data directory."; exit 1; }

# Redirect all output to the log file and console
exec > >(tee -a "$LOGFILE") 2>&1

# Open file descriptor 3 for logging only
exec 3>>"$LOGFILE"

# Initialize arrays
MISSING_TOOLS=()

# Initialize variables
INFRA_DIR="${INFRA_DIR:-$HOME/opengovernance_infrastructure}"  # Default infrastructure directory
CURRENT_PROVIDER=""  # Variable to store the detected Kubernetes provider
KUBECTL_CONFIGURED=false  # Variable to track if kubectl is configured
CURRENT_CONTEXT=""  # Current kubectl context
CURRENT_CLUSTER_NAME=""  # Current cluster name
NODE_COUNT="Unknown"  # Initialize NODE_COUNT with default value

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
# Main Execution Flow
# -----------------------------

echo_info "OpenGovernance installation script started."

# Step 1: Check dependencies
check_dependencies

# Step 2: Check if kubectl is configured
if is_kubectl_configured; then
    KUBECTL_CONFIGURED=true
    detect_kubernetes_provider_and_set_context
else
    KUBECTL_CONFIGURED=false
fi

# Step 3: Check provider CLIs (for displaying details)
check_provider_clis

# Step 4: Proceed to deployment selection
choose_deployment

echo_primary "OpenGovernance installation script completed successfully."

# Exit script successfully
exit 0