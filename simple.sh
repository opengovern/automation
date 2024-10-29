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

# Function to redirect Helm commands to the log only, always with --debug
helm_quiet() {
    helm --debug "$@" >&3 2>&1
}

# Function to check if a command exists
command_exists() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1
}

# Function to check tool dependencies
check_dependencies() {
    local required_tools=("helm" "kubectl" "jq" "curl" "doctl")

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
            echo_primary "An existing OpenGovernance installation was found and is healthy."
            echo_primary "Do you want to reconfigure it? (yes/no): "
            read -r reconfig_choice < /dev/tty
            USER_INPUTS+=("Reconfigure existing OpenGovernance installation: $reconfig_choice")

            case "$reconfig_choice" in
                yes|y|Y)
                    echo_info "Proceeding with reconfiguration."
                    return 0  # Allow script to proceed with configuration
                    ;;
                no|n|N)
                    echo_primary "Exiting as per user request."
                    exit 0
                    ;;
                *)
                    echo_error "Invalid input. Exiting."
                    exit 1
                    ;;
            esac
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

# Function to get cluster information
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

# Function to install OpenGovernance with Helm
install_opengovernance_with_helm() {
    if [[ "$OPENGOVERNANCE_INSTALLED" == "true" ]]; then
        echo_info "OpenGovernance is already installed."
        return
    fi

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

    echo_detail "Installing OpenGovernance via Helm in namespace '$KUBE_NAMESPACE' (this may take a few minutes)."
    save_state  # Save state before starting Helm installation
    if ! helm_quiet install opengovernance opengovernance/opengovernance \
        -n "$KUBE_NAMESPACE" --create-namespace --timeout=15m --wait; then
        echo_error "Helm installation failed."
        exit 1
    fi

    echo_detail "OpenGovernance installed successfully."
    OPENGOVERNANCE_INSTALLED="true"
    save_state  # Save state after Helm installation

    check_pods_and_jobs

    if [[ "$CURRENT_PROVIDER" == "DigitalOcean" ]]; then
        echo_info "Configuring DigitalOcean setup."
        configure_digitalocean_app
    else
        setup_port_forwarding
    fi
}

# Function to check pods and jobs
check_pods_and_jobs() {
    echo_detail "Checking pod and job statuses in namespace '$KUBE_NAMESPACE'."
    if ! kubectl get pods -n "$KUBE_NAMESPACE" >&3 2>&1; then
        echo_error "Failed to get pod statuses."
    fi

    if ! kubectl get jobs -n "$KUBE_NAMESPACE" >&3 2>&1; then
        echo_error "Failed to get job statuses."
    fi
}

# Function to provide port-forwarding instructions
provide_port_forward_instructions() {
    echo_primary "To access OpenGovernance, set up port-forwarding using the following command:"
    echo_prompt "kubectl port-forward -n \"$KUBE_NAMESPACE\" service/nginx-proxy 8080:80"
    echo_prompt "Access OpenGovernance at http://localhost:8080"
    echo_prompt "Use these credentials to sign in: Username: admin@opengovernance.io, Password: password"
}

# Function to check if Kubernetes nodes are ready
check_ready_nodes() {
    local provider="$1"
    local required_nodes=3
    local attempts=0
    local max_attempts=10  # 10 attempts * 30 seconds = 5 minutes
    local sleep_time=30

    echo_info "Checking if at least $required_nodes Kubernetes nodes are ready for $provider..."

    if [[ "$provider" == "Minikube" || "$provider" == "Kind" ]]; then
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
    echo_primary "Please ensure 3 nodes are ready before proceeding."
    exit 1
}

# Function to warn on Minikube or Kind deployment
warn_minikube_kind() {
    local provider="$1"
    echo_primary "Detected $provider cluster."
    echo_primary "OpenGovernance uses resources that may require at least 16GB of RAM for stability on desktops."

    echo_prompt -n "Do you wish to proceed? (yes/no): "
    read -r proceed < /dev/tty
    USER_INPUTS+=("$provider proceed: $proceed")

    if [[ "$proceed" == "yes" ]]; then
        return 0
    else
        return 1
    fi
}

# Function to configure DigitalOcean app
configure_digitalocean_app() {
    if [[ "$DIGITALOCEAN_APP_CONFIGURED" == "true" ]]; then
        echo_info "DigitalOcean application is already configured."
        return
    fi

    echo_primary "How would you like to configure the OpenGovernance application?"
    echo_primary "1) Configure with HTTPS and Hostname"
    echo_primary "2) Configure without HTTPS"
    echo_primary "3) No further configuration required"

    while true; do
        echo_prompt -n "Select an option (1-3): "
        read -r config_choice < /dev/tty
        USER_INPUTS+=("DigitalOcean configuration choice: $config_choice")
        save_state  # Save state after user input

        case "$config_choice" in
            1)
                INSTALL_TYPE=1
                ;;
            2)
                INSTALL_TYPE=2
                ;;
            3)
                INSTALL_TYPE=3
                ;;
            *)
                echo_error "Invalid selection. Please choose between 1 and 3."
                continue
                ;;
        esac

        break
    done

    case "$INSTALL_TYPE" in
        1|2)
            local script_url="https://raw.githubusercontent.com/opengovern/deploy-opengovernance/main/digitalocean/scripts/do-automation.sh"
            echo_info "Running DigitalOcean automation script with installation type $INSTALL_TYPE."
            save_state

            if curl --head --silent --fail "$script_url" >/dev/null; then
                echo_detail "Executing DigitalOcean automation script."
                curl -sL "$script_url" | bash -s -- --type "$INSTALL_TYPE" --kube-namespace "$KUBE_NAMESPACE"
                echo_info "DigitalOcean automation script executed successfully."
                DIGITALOCEAN_APP_CONFIGURED="true"
                save_state
            else
                echo_error "DigitalOcean automation script is not accessible at $script_url."
                exit 1
            fi
            ;;
        3)
            setup_port_forwarding
            ;;
    esac
}

# Function to set up port-forwarding
setup_port_forwarding() {
    echo_primary "Setting up port-forwarding to access OpenGovernance locally."
    if kubectl port-forward -n "$KUBE_NAMESPACE" service/nginx-proxy 8080:80 >/dev/null 2>&1 & then
        PORT_FORWARD_PID=$!
    
        sleep 5  # Wait briefly to ensure port-forwarding is established
    
        if ps -p "$PORT_FORWARD_PID" > /dev/null 2>&1; then
            echo_detail "Port-forwarding established successfully (PID: $PORT_FORWARD_PID)."
            echo_prompt "OpenGovernance is accessible at http://localhost:8080"
            echo_prompt "To sign in, use: Username: admin@opengovernance.io, Password: password"
            echo_prompt "To terminate port-forwarding: kill $PORT_FORWARD_PID"
        else
            echo_error "Port-forwarding failed to establish."
            provide_port_forward_instructions
        fi
    else
        echo_error "Failed to initiate port-forwarding."
        provide_port_forward_instructions
    fi
}


# Function to save state
save_state() {
    {
        echo "## State saved at $(date '+%Y-%m-%d %H:%M:%S')"
        echo "INSTALL_RUN_ID=\"$INSTALL_RUN_ID\""
        echo "START_TIME=\"$START_TIME\""
        echo "CURRENT_STEP=$CURRENT_STEP"
        echo "KUBE_NAMESPACE=\"$KUBE_NAMESPACE\""
        echo "KUBE_CLUSTER_NAME=\"$KUBE_CLUSTER_NAME\""
        echo "DIGITALOCEAN_REGION=\"$DIGITALOCEAN_REGION\""
        echo "INFRA_DIR=\"$INFRA_DIR\""
        echo "INFRA_TOOL=\"$INFRA_TOOL\""
        echo "CURRENT_PROVIDER=\"$CURRENT_PROVIDER\""
        echo "DIGITALOCEAN_CLUSTER_CREATED=\"$DIGITALOCEAN_CLUSTER_CREATED\""
        echo "OPENGOVERNANCE_INSTALLED=\"$OPENGOVERNANCE_INSTALLED\""
        echo "DIGITALOCEAN_APP_CONFIGURED=\"$DIGITALOCEAN_APP_CONFIGURED\""
        echo "KUBECTL_CONFIGURED=\"$KUBECTL_CONFIGURED\""
        echo "RESUMING_FROM_STATE=\"$RESUMING_FROM_STATE\""
        # Include user inputs and selections
        for key in "${!USER_INPUTS[@]}"; do
            echo "USER_INPUT_$key=\"${USER_INPUTS[$key]}\""
        done
    } > "$STATE_FILE"
}

# Function to load state
load_state() {
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    # Reconstruct USER_INPUTS array
    USER_INPUTS=()
    for key in $(compgen -A variable | grep '^USER_INPUT_'); do
        USER_INPUTS+=("${!key}")
    done
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
            CURRENT_PROVIDER="Azure"
            ;;
        *".eks.amazonaws.com"*|*"amazonaws.com"*)
            echo_primary "Detected EKS (AWS) cluster."
            CURRENT_PROVIDER="AWS"
            ;;
        *".gke.io"*|*"gke"*)
            echo_primary "Detected GKE (GCP) cluster."
            CURRENT_PROVIDER="GCP"
            ;;
        *".k8s.ondigitalocean.com"*|*"digitalocean"*|*"do-"*)
            echo_primary "Detected DigitalOcean Kubernetes cluster."
            CURRENT_PROVIDER="DigitalOcean"
            ;;
        *"minikube"*)
            echo_primary "Detected Minikube cluster."
            CURRENT_PROVIDER="Minikube"
            ;;
        *"kind"*)
            echo_primary "Detected Kind cluster."
            CURRENT_PROVIDER="Kind"
            ;;
        *)
            echo_primary "Unable to identify Kubernetes provider."
            CURRENT_PROVIDER="Unknown"
            ;;
    esac

    # Save state after detecting provider
    save_state

    # Ask user if they want to deploy to the existing cluster or create a new one
    if [[ "$RESUMING_FROM_STATE" == "true" && "$CURRENT_STEP" -gt 3 ]]; then
        echo_info "Resuming deployment to existing cluster."
        determine_and_deploy_provider "$cluster_info" "true"
    else
        echo_primary "Do you want to deploy OpenGovernance to the existing Kubernetes cluster or create a new cluster?"
        echo_primary "1. Deploy to existing cluster"
        echo_primary "2. Create a new cluster"
        echo_primary "3. Exit"

        echo_prompt -n "Select an option (1-3): "
        read -r deploy_choice < /dev/tty
        USER_INPUTS+=("Deployment choice: $deploy_choice")
        save_state  # Save state after user input

        case "$deploy_choice" in
            1)
                # Check if OpenGovernance is already installed
                if check_opengovernance_installation; then
                    # If installation exists and user chooses to reconfigure, proceed
                    determine_and_deploy_provider "$cluster_info" "true"
                else
                    # If no installation exists, determine the provider and execute provider-specific scripts
                    determine_and_deploy_provider "$cluster_info" "false"
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
    fi
}

# Function to determine provider from cluster_info and deploy accordingly
determine_and_deploy_provider() {
    local cluster_info="$1"
    local deploy_existing="$2"  # 'true' or 'false'

    case "$cluster_info" in
        *".azmk8s.io"*|*"azure"*)
            echo_primary "Deploying OpenGovernance to Azure."
            CURRENT_PROVIDER="Azure"
            save_state
            deploy_via_curl "azure"
            ;;
        *".eks.amazonaws.com"*|*"amazonaws.com"*)
            echo_primary "Deploying OpenGovernance to AWS."
            CURRENT_PROVIDER="AWS"
            save_state
            deploy_via_curl "aws"
            ;;
        *".gke.io"*|*"gke"*)
            echo_primary "Deploying OpenGovernance to GCP."
            CURRENT_PROVIDER="GCP"
            save_state
            deploy_via_curl "gcp"
            ;;
        *".k8s.ondigitalocean.com"*|*"digitalocean"*|*"do-"*)
            echo_primary "Deploying OpenGovernance to DigitalOcean."
            CURRENT_PROVIDER="DigitalOcean"
            save_state
            deploy_to_digitalocean "$deploy_existing"
            ;;
        *"minikube"*)
            echo_primary "Deploying OpenGovernance to Minikube."
            CURRENT_PROVIDER="Minikube"
            save_state
            if warn_minikube_kind "Minikube"; then
                install_opengovernance_with_helm
            else
                echo_primary "Deployment aborted by user."
                exit 0
            fi
            ;;
        *"kind"*)
            echo_primary "Deploying OpenGovernance to Kind."
            CURRENT_PROVIDER="Kind"
            save_state
            if warn_minikube_kind "Kind"; then
                install_opengovernance_with_helm
            else
                echo_primary "Deployment aborted by user."
                exit 1
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
        curl -sL "$script_url" | bash -s -- "$KUBE_NAMESPACE"
    else
        echo_error "Deployment script for $provider is not accessible."
        exit 1
    fi
}

# Function to allow user to choose deployment based on available platforms
choose_deployment() {
    # If resuming and already selected a platform, skip this step
    if [[ "$RESUMING_FROM_STATE" == "true" && "$CURRENT_STEP" -gt 3 ]]; then
        echo_info "Resuming deployment to $CURRENT_PROVIDER."
        determine_and_deploy_provider_from_selection
        return
    fi

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
        USER_INPUTS+=("Platform choice: $platform_choice")
        save_state  # Save state after user input

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
        CURRENT_PROVIDER="$selected_platform"
        save_state  # Save selected platform

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
                deploy_to_digitalocean "false"  # 'false' indicates not deploying to existing cluster
                ;;
            *)
                echo_error "Unsupported platform: $selected_platform"
                ;;
        esac
        break
    done
}

# Function to determine and deploy based on user selection (for resuming)
determine_and_deploy_provider_from_selection() {
    case "$CURRENT_PROVIDER" in
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
            deploy_to_digitalocean "false"  # 'false' indicates not deploying to existing cluster
            ;;
        *)
            echo_error "Unsupported or unidentified platform: $CURRENT_PROVIDER"
            ;;
    esac
}

# Function to deploy to DigitalOcean
deploy_to_digitalocean() {
    local deploy_existing="$1"  # 'true' or 'false'

    # Ensure required variables are set
    DIGITALOCEAN_REGION="${DIGITALOCEAN_REGION:-nyc3}"
    KUBE_CLUSTER_NAME="${KUBE_CLUSTER_NAME:-opengovernance}"

    # Check if the cluster exists using 'doctl kubernetes cluster get'
    if doctl kubernetes cluster get "$KUBE_CLUSTER_NAME" >/dev/null 2>&1; then
        if [[ "$deploy_existing" == "true" ]]; then
            echo_primary "Using existing cluster '$KUBE_CLUSTER_NAME'."
            # Retrieve kubeconfig for the cluster
            doctl kubernetes cluster kubeconfig save "$KUBE_CLUSTER_NAME"
            # Proceed to install OpenGovernance with Helm
            install_opengovernance_with_helm
        else
            echo_primary "A Kubernetes cluster named '$KUBE_CLUSTER_NAME' already exists."

            # Prompt user for choice
            echo_primary "Choose an option for deploying to DigitalOcean Kubernetes cluster:"
            echo_primary "1. Use existing cluster '$KUBE_CLUSTER_NAME'"
            echo_primary "2. Create a new cluster with a different name"
            echo_primary "3. Exit"

            echo_prompt -n "Select an option (1-3): "
            read -r do_option < /dev/tty
            USER_INPUTS+=("DigitalOcean cluster option: $do_option")
            save_state  # Save state after user input

            case "$do_option" in
                1)
                    echo_primary "Using existing cluster '$KUBE_CLUSTER_NAME'."
                    # Retrieve kubeconfig for the cluster
                    doctl kubernetes cluster kubeconfig save "$KUBE_CLUSTER_NAME"
                    # Proceed to install OpenGovernance with Helm
                    install_opengovernance_with_helm
                    ;;
                2)
                    # Prompt user for new cluster name with validation
                    create_unique_digitalocean_cluster
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
        fi
    else
        if [[ "$deploy_existing" == "true" ]]; then
            echo_error "DigitalOcean Kubernetes cluster '$KUBE_CLUSTER_NAME' does not exist."
            echo_primary "Cannot deploy to a non-existent cluster."
            exit 1
        fi

        # Cluster does not exist, prompt user to create or exit
        echo_primary "DigitalOcean Kubernetes cluster '$KUBE_CLUSTER_NAME' does not exist."

        echo_primary "Choose an option:"
        echo_primary "1. Create a new cluster named '$KUBE_CLUSTER_NAME'"
        echo_primary "2. Exit"

        echo_prompt -n "Select an option (1-2): "
        read -r do_option < /dev/tty
        USER_INPUTS+=("DigitalOcean cluster creation option: $do_option")
        save_state  # Save state after user input

        case "$do_option" in
            1)
                # Prompt user for new cluster name with validation
                create_unique_digitalocean_cluster
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

# Function to create a unique Kubernetes cluster on DigitalOcean
create_unique_digitalocean_cluster() {
    # Check if cluster is already created
    if [[ "$DIGITALOCEAN_CLUSTER_CREATED" == "true" ]]; then
        echo_info "DigitalOcean cluster '$KUBE_CLUSTER_NAME' already created."
        return
    fi

    while true; do
        echo_prompt -n "Enter the name for the new DigitalOcean Kubernetes cluster: "
        read -r new_cluster_name < /dev/tty
        USER_INPUTS+=("New DigitalOcean cluster name: $new_cluster_name")

        # Check if the cluster name is empty
        if [[ -z "$new_cluster_name" ]]; then
            echo_error "Cluster name cannot be empty. Please enter a valid name."
            continue
        fi

        # Check if the cluster name already exists using 'doctl kubernetes cluster get'
        if doctl kubernetes cluster get "$new_cluster_name" >/dev/null 2>&1; then
            echo_primary "A Kubernetes cluster named '$new_cluster_name' already exists."
            echo_primary "Choose an option:"
            echo_primary "1. Use existing cluster '$new_cluster_name'"
            echo_primary "2. Enter a different cluster name"
            echo_primary "3. Exit"

            echo_prompt -n "Select an option (1-3): "
            read -r existing_option < /dev/tty
            USER_INPUTS+=("Existing cluster option: $existing_option")
            save_state  # Save state after user input

            case "$existing_option" in
                1)
                    echo_primary "Using existing cluster '$new_cluster_name'."
                    # Retrieve kubeconfig for the cluster
                    doctl kubernetes cluster kubeconfig save "$new_cluster_name"
                    # Update the global cluster name variable
                    KUBE_CLUSTER_NAME="$new_cluster_name"
                    # Proceed to install OpenGovernance with Helm
                    install_opengovernance_with_helm
                    return  # Exit the function after installing
                    ;;
                2)
                    echo_primary "Please enter a different cluster name."
                    continue  # Go back to prompt for a new name
                    ;;
                3)
                    echo_primary "Exiting."
                    exit 0
                    ;;
                *)
                    echo_error "Invalid selection. Please choose between 1 and 3."
                    ;;
            esac
            continue  # Loop back to the start
        fi

        # Optional: Validate cluster name format (e.g., only lowercase letters, numbers, and hyphens)
        if [[ ! "$new_cluster_name" =~ ^[a-z0-9-]+$ ]]; then
            echo_error "Invalid cluster name format. Use only lowercase letters, numbers, and hyphens."
            continue
        fi

        # Prompt to change the default region
        echo_primary "Current default region is '$DIGITALOCEAN_REGION'."
        echo_prompt -n "Do you wish to change the region? (yes/no): "
        read -r change_region < /dev/tty
        USER_INPUTS+=("Change region: $change_region")

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
                USER_INPUTS+=("Selected region: $input_region")

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
        save_state  # Save state before starting cluster creation

        # Create the cluster
        if doctl kubernetes cluster create "$new_cluster_name" --region "$DIGITALOCEAN_REGION" \
            --node-pool "name=main-pool;size=g-4vcpu-16gb-intel;count=3" --wait; then
            echo_info "Cluster '$new_cluster_name' created successfully."
            DIGITALOCEAN_CLUSTER_CREATED="true"
            save_state  # Save state after cluster creation
        else
            echo_error "Failed to create cluster '$new_cluster_name'. Please try again."
            continue
        fi

        # Save kubeconfig for the cluster
        doctl kubernetes cluster kubeconfig save "$new_cluster_name"

        # Update the global cluster name variable
        KUBE_CLUSTER_NAME="$new_cluster_name"

        # Exit the loop after successful creation
        break
    done
}

# The rest of the script remains unchanged, including functions:
# - install_opengovernance_with_helm
# - check_pods_and_jobs
# - provide_port_forward_instructions
# - check_ready_nodes
# - warn_minikube_kind
# - configure_digitalocean_app
# - setup_port_forwarding

# -----------------------------
# State Management
# -----------------------------

# Function to save state
save_state() {
    {
        echo "## State saved at $(date '+%Y-%m-%d %H:%M:%S')"
        echo "INSTALL_RUN_ID=\"$INSTALL_RUN_ID\""
        echo "START_TIME=\"$START_TIME\""
        echo "CURRENT_STEP=$CURRENT_STEP"
        echo "KUBE_NAMESPACE=\"$KUBE_NAMESPACE\""
        echo "KUBE_CLUSTER_NAME=\"$KUBE_CLUSTER_NAME\""
        echo "DIGITALOCEAN_REGION=\"$DIGITALOCEAN_REGION\""
        echo "INFRA_DIR=\"$INFRA_DIR\""
        echo "INFRA_TOOL=\"$INFRA_TOOL\""
        echo "CURRENT_PROVIDER=\"$CURRENT_PROVIDER\""
        echo "DIGITALOCEAN_CLUSTER_CREATED=\"$DIGITALOCEAN_CLUSTER_CREATED\""
        echo "OPENGOVERNANCE_INSTALLED=\"$OPENGOVERNANCE_INSTALLED\""
        echo "DIGITALOCEAN_APP_CONFIGURED=\"$DIGITALOCEAN_APP_CONFIGURED\""
        echo "KUBECTL_CONFIGURED=\"$KUBECTL_CONFIGURED\""
        echo "RESUMING_FROM_STATE=\"$RESUMING_FROM_STATE\""
        # Include user inputs and selections
        for key in "${!USER_INPUTS[@]}"; do
            echo "USER_INPUT_$key=\"${USER_INPUTS[$key]}\""
        done
    } > "$STATE_FILE"
}

# Function to load state
load_state() {
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    # Reconstruct USER_INPUTS array
    USER_INPUTS=()
    for key in $(compgen -A variable | grep '^USER_INPUT_'); do
        USER_INPUTS+=("${!key}")
    done
}

# -----------------------------
# Script Initialization
# -----------------------------

# Logging Configuration
DATA_DIR="$HOME/opengovernance_data"
LOGFILE="$DATA_DIR/opengovernance_install.log"
STATE_FILE="$DATA_DIR/opengovernance_install.state"

# Ensure the data directory exists
mkdir -p "$DATA_DIR" || { echo "Failed to create data directory."; exit 1; }

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
USER_INPUTS=()  # Array to store user inputs and selections

# Initialize variables
INFRA_DIR="${INFRA_DIR:-$HOME/opengovernance_infrastructure}"  # Default infrastructure directory
INFRA_TOOL=""  # Will be set to 'terraform' or 'tofu' based on availability
CURRENT_PROVIDER=""  # Variable to store the detected Kubernetes provider
KUBECTL_CONFIGURED=false  # Variable to track if kubectl is configured
RESUMING_FROM_STATE="false"

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
# State Management
# -----------------------------

# Generate or load install-run-id
if [[ -f "$STATE_FILE" ]]; then
    echo "State file found. Resuming from last saved state."

    # Prompt user to decide whether to resume
    echo_prompt -n "Do you want to resume the previous installation? (yes/no): "
    read -r resume_choice < /dev/tty

    if [[ "$resume_choice" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        RESUMING_FROM_STATE="true"
        load_state
    else
        echo "Starting a new installation."
        RESUMING_FROM_STATE="false"
        CURRENT_STEP=1
        # Initialize state variables
        DIGITALOCEAN_CLUSTER_CREATED="false"
        OPENGOVERNANCE_INSTALLED="false"
        DIGITALOCEAN_APP_CONFIGURED="false"
        KUBECTL_CONFIGURED="false"
        INSTALL_RUN_ID=$(date +%s%N | cut -b1-13)  # 13-digit nanosecond timestamp
        START_TIME=$(date '+%Y-%m-%d %H:%M:%S')
        # Save initial state
        save_state
    fi
else
    echo "No state file found. Starting fresh."
    RESUMING_FROM_STATE="false"
    CURRENT_STEP=1
    # Initialize state variables
    DIGITALOCEAN_CLUSTER_CREATED="false"
    OPENGOVERNANCE_INSTALLED="false"
    DIGITALOCEAN_APP_CONFIGURED="false"
    KUBECTL_CONFIGURED="false"
    INSTALL_RUN_ID=$(date +%s%N | cut -b1-13)  # 13-digit nanosecond timestamp
    START_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    # Save initial state
    save_state
fi

# -----------------------------
# Main Execution Flow
# -----------------------------

echo_info "OpenGovernance installation script started."

# Step 1: Check dependencies
if [ "$CURRENT_STEP" -le 1 ]; then
    check_dependencies
    CURRENT_STEP=2
    save_state
fi

# Step 2: Check if kubectl is configured
if [ "$CURRENT_STEP" -le 2 ]; then
    if is_kubectl_configured; then
        KUBECTL_CONFIGURED=true
    else
        KUBECTL_CONFIGURED=false
    fi
    CURRENT_STEP=3
    save_state
fi

# Step 3: Proceed based on kubectl configuration
if [ "$CURRENT_STEP" -le 3 ]; then
    if [ "$KUBECTL_CONFIGURED" == "true" ]; then
        detect_kubernetes_provider_and_deploy
    else
        check_provider_clis
        choose_deployment
    fi
    CURRENT_STEP=4
    save_state
fi

echo_primary "OpenGovernance installation script completed successfully."

# Cleanup state file after successful completion
rm -f "$STATE_FILE"

# Exit script successfully
exit 0
