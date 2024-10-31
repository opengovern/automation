#!/bin/sh

# Exit immediately if a command exits with a non-zero status
set -e

# -----------------------------
# Namespace Configuration
# -----------------------------
NAMESPACE="opengovernance"  # Default namespace

# -----------------------------
# Logging Configuration
# -----------------------------
# Set DEBUG_MODE based on environment variable; default to false
DEBUG_MODE="${DEBUG_MODE:-false}"  # Helm operates in debug mode
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

# Function to run helm install commands with a timeout of 15 minutes in debug mode
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

# Function to ensure Helm repository is added and updated
ensure_helm_repo() {
    REPO_NAME="opengovernance"
    REPO_URL="https://opengovern.github.io/charts/"

    if ! helm repo list | grep -q "^$REPO_NAME "; then
        # Suppress output from ensure_helm_repo
        helm repo add "$REPO_NAME" "$REPO_URL" >/dev/null 2>&1 || { echo_error "Failed to add Helm repository '$REPO_NAME'."; exit 1; }
    else
        # Suppress output from ensure_helm_repo
        :
    fi

    # Suppress output from ensure_helm_repo
    helm repo update >/dev/null 2>&1 || { echo_error "Failed to update Helm repositories."; exit 1; }
}

# Function to check prerequisites
check_prerequisites() {
    # List of required commands (removed 'yq')
    REQUIRED_COMMANDS="kind kubectl helm"

    echo_info "Checking for required tools..."

    # Check if each command is installed
    for cmd in $REQUIRED_COMMANDS; do
        check_command "$cmd"
    done

    # Ensure Helm repository is added and updated
    ensure_helm_repo

    echo_info "Checking Prerequisites...Completed"
}

# Function to list existing Kind clusters
list_kind_clusters() {
    kind get clusters
}

# Function to check if a Kind cluster exists
kind_cluster_exists() {
    kind get clusters | grep -qw "$1"
}

# Function to create a Kind cluster
create_kind_cluster() {
    cluster_name="$1"
    echo_info "Creating Kind Cluster $cluster_name"
    kind create cluster --name "$cluster_name" || { echo_error "Failed to create Kind cluster '$cluster_name'."; exit 1; }
    kubectl config use-context "kind-$cluster_name" || { echo_error "Failed to set kubectl context to 'kind-$cluster_name'."; exit 1; }
}

# Function to prompt the user for selecting an existing cluster or creating a new one
select_kind_cluster() {
    existing_clusters=$(list_kind_clusters)
    cluster_count=$(echo "$existing_clusters" | wc -l | tr -d ' ')

    if [ "$cluster_count" -eq 0 ]; then
        # No existing clusters, create a new one
        echo_info "No existing Kind clusters found. Creating a new Kind cluster named '$NAMESPACE'."
        run_with_timer create_kind_cluster "$NAMESPACE"
    else
        # Existing clusters found, prompt user
        echo_prompt "Existing Kind clusters detected:"
        echo "$existing_clusters" > /dev/tty
        echo_prompt "Do you want to use an existing Kind cluster? (y/N): "

        read user_input

        case "$user_input" in
            [Yy]* )
                # Prompt user to select which cluster to use
                echo_prompt "Enter the name of the Kind cluster you want to use:"
                read selected_cluster

                if kind_cluster_exists "$selected_cluster"; then
                    echo_info "Using existing Kind cluster '$selected_cluster'."
                    kubectl config use-context "kind-$selected_cluster" || { echo_error "Failed to set kubectl context to 'kind-$selected_cluster'."; exit 1; }
                else
                    echo_error "Kind cluster '$selected_cluster' does not exist."
                    exit 1
                fi
                ;;
            * )
                # Create a new cluster
                echo_info "Creating a new Kind cluster named '$NAMESPACE'."
                run_with_timer create_kind_cluster "$NAMESPACE"
                ;;
        esac
    fi
}

# -----------------------------
# Readiness Check Functions
# -----------------------------

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
# Timer Function
# -----------------------------

run_with_timer() {
    start_time=$(date +%s)  # Start time in seconds

    # Execute the command passed as arguments
    "$@"

    end_time=$(date +%s)  # End time in seconds
    elapsed_time=$((end_time - start_time))  # Calculate elapsed time in seconds

    # Convert elapsed time to minutes and seconds
    mins=$((elapsed_time / 60))
    secs=$((elapsed_time % 60))

    echo "Completed in ${mins} mins ${secs} secs"
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
# Main Deployment Steps
# -----------------------------

# Start of the script
echo_primary "Starting OpenGovernance deployment script."

# Check prerequisites
check_prerequisites

# Handle Kind clusters
select_kind_cluster

# Step 1: Install the 'opengovernance' chart into the specified namespace with timing
echo_primary "Installing 'opengovernance' Helm chart into namespace '$NAMESPACE'."
run_with_timer helm_install_with_timeout -n "$NAMESPACE" opengovernance opengovernance/opengovernance --create-namespace || { echo_error "Helm installation failed."; exit 1; }

# Step 2: Check if the application is ready
check_pods_and_jobs

# Step 3: Set up port-forwarding after successful Helm install and readiness
basic_install_with_port_forwarding

# Completion message
echo_primary "OpenGovernance deployment completed successfully."

# -----------------------------
# End of Script
# -----------------------------
