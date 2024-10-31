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
        helm repo add "$REPO_NAME" "$REPO_URL" >/dev/null 2>&1 || { echo_error "Failed to add Helm repository '$REPO_NAME'."; exit 1; }
    fi
    helm repo update >/dev/null 2>&1 || { echo_error "Failed to update Helm repositories."; exit 1; }
}

# Function to check prerequisites
check_prerequisites() {
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

# Function to create a new Kind cluster with 8GB memory limit
create_kind_cluster() {
    cluster_name="$1"
    echo_info "Creating a new Kind Cluster '$cluster_name' with 8GB memory limit"

    # Define the Kind configuration without extraResources
    kind_config_file="$HOME/kind-config.yaml"
    cat <<EOF > "$kind_config_file"
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
EOF

    # Create the cluster using the configuration file
    kind create cluster --name "$cluster_name" --config "$kind_config_file" >> "$DEBUG_LOGFILE" 2>&1 || { echo_error "Failed to create Kind cluster '$cluster_name'."; exit 1; }

    kubectl config use-context "kind-$cluster_name" >> "$DEBUG_LOGFILE" 2>&1 || { echo_error "Failed to set kubectl context to 'kind-$cluster_name'."; exit 1; }

    echo_info "Set kubectl context to 'kind-$cluster_name'"

    # Validate memory allocation
    validate_memory_allocation "$cluster_name"
}

# Function to validate memory allocation using docker inspect
validate_memory_allocation() {
    cluster_name="$1"
    # Get the node name using kind
    node_name=$(kind get nodes --name "$cluster_name")
    container_name="$node_name"

    echo_info "Validating memory allocation for Kind cluster '$cluster_name'"

    # Get memory limit from docker inspect (in bytes)
    mem_limit_bytes=$(docker inspect "$container_name" --format='{{.HostConfig.Memory}}')

    # If Memory is 0, it means no limit is set
    if [ "$mem_limit_bytes" -eq 0 ]; then
        echo_error "No memory limit set for Kind cluster '$cluster_name'. Expected at least 7.44GiB (93% of 8GiB)."
        exit 1
    fi

    # Define the minimum required memory in bytes (93% of 8GiB)
    min_mem_bytes=7999255104  # 7.44 * 1024^3 ≈ 7.44GiB in bytes

    if [ "$mem_limit_bytes" -lt "$min_mem_bytes" ]; then
        # Convert bytes to GiB for logging
        mem_limit_gib=$(awk "BEGIN {printf \"%.2f\", $mem_limit_bytes/1024/1024/1024}")
        echo_error "Kind cluster '$cluster_name' has insufficient memory allocated: ${mem_limit_gib}GiB (< 7.44GiB)."
        exit 1
    else
        # Convert bytes to GiB for logging
        mem_limit_gib=$(awk "BEGIN {printf \"%.2f\", $mem_limit_bytes/1024/1024/1024}")
        echo_info "Kind cluster '$cluster_name' has sufficient memory allocated: ${mem_limit_gib}GiB."
    fi
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
    kubectl port-forward -n "$NAMESPACE" service/nginx-proxy 8080:80 >> "$DEBUG_LOGFILE" 2>&1 &
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

# Always create a new Kind cluster with an 8GB memory limit
create_kind_cluster "$NAMESPACE"

# Install the 'opengovernance' Helm chart into the specified namespace
echo_primary "Installing 'opengovernance' Helm chart into namespace '$NAMESPACE'."
run_with_timer helm_install_with_timeout -n "$NAMESPACE" opengovernance opengovernance/opengovernance --create-namespace || { echo_error "Helm installation failed."; exit 1; }

# Set up port-forwarding after successful Helm install
basic_install_with_port_forwarding

# Completion message
echo_primary "OpenGovernance deployment completed successfully."

# -----------------------------
# End of Script
# -----------------------------
