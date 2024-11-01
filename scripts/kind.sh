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
mkdir -p "$LOGDIR" || { printf "Failed to create log directory at %s.\n" "$LOGDIR"; exit 1; }
mkdir -p "$DEBUG_LOGDIR" || { printf "Failed to create debug log directory at %s.\n" "$DEBUG_LOGDIR"; exit 1; }
touch "$LOGFILE" "$DEBUG_LOGFILE" || { printf "Failed to create log files.\n"; exit 1; }

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

    if ! helm repo list | grep -w "^$REPO_NAME" >/dev/null 2>&1; then
        helm repo add "$REPO_NAME" "$REPO_URL" >/dev/null 2>&1 || { echo_error "Failed to add Helm repository '$REPO_NAME'."; exit 1; }
        echo_info "Helm repository '$REPO_NAME' added."
    else
        echo_info "Helm repository '$REPO_NAME' already exists."
    fi

    helm repo update >/dev/null 2>&1 || { echo_error "Failed to update Helm repositories."; exit 1; }
    echo_info "Helm repositories updated successfully."
}

# Function to check prerequisites
check_prerequisites() {
    REQUIRED_COMMANDS="kind kubectl helm docker bc awk"

    echo_info "Checking for required tools..."

    # Check if each command is installed
    for cmd in $REQUIRED_COMMANDS; do
        check_command "$cmd"
    done

    # Ensure Helm repository is added and updated
    ensure_helm_repo

    echo_info "Checking Prerequisites...Completed"
}

# Function to convert bytes to GiB with two decimal places
bytes_to_gib() {
    bytes="$1"
    awk "BEGIN { printf \"%.2f\", $bytes / (1024 * 1024 * 1024) }"
}

# Function to convert memory units to bytes
convert_to_bytes() {
    value="$1"
    unit=$(printf "%s" "$value" | grep -o '[A-Za-z]*')
    number=$(printf "%s" "$value" | grep -o '[0-9.]*')

    case "$unit" in
        B)
            multiplier=1
            ;;
        KiB)
            multiplier=1024
            ;;
        MiB)
            multiplier=1048576  # 1024^2
            ;;
        GiB)
            multiplier=1073741824  # 1024^3
            ;;
        TiB)
            multiplier=1099511627776  # 1024^4
            ;;
        *)
            multiplier=0
            ;;
    esac

    # Calculate bytes using bc for floating point multiplication
    if [ "$multiplier" -eq 0 ]; then
        printf "0"
    else
        echo "$number * $multiplier" | bc | awk '{printf "%d", $0}'
    fi
}

# Function to get total system memory in bytes
get_total_memory_bytes() {
    if command -v free >/dev/null 2>&1; then
        # Linux
        total_mem=$(free -b | awk '/^Mem:/ {print $2}')
    elif command -v sysctl >/dev/null 2>&1; then
        # macOS
        total_mem=$(sysctl -n hw.memsize)
    else
        # Unable to determine
        printf "0"
        return
    fi
    printf "%s" "$total_mem"
}

# Function to validate memory allocation using docker stats --no-stream
validate_memory_allocation() {
    cluster_name="$1"
    # Get the node name using kind
    node_name=$(kind get nodes --name "$cluster_name" | head -n 1)
    container_name="$node_name"

    echo_info "Validating memory allocation for Kind cluster '$cluster_name'"

    # Get memory usage and limit using docker stats --no-stream
    docker_stats_output=$(docker stats --no-stream --format "{{.Name}} {{.MemUsage}} {{.MemPerc}}" "$container_name" 2>/dev/null)

    if [ -z "$docker_stats_output" ]; then
        echo_error "Failed to retrieve memory stats for container '$container_name'. Ensure the container is running."
        exit 1
    fi

    # Example output:
    # opengovernance-control-plane 741.8MiB / 7.752GiB 9.34%

    # Extract MEM LIMIT (e.g., "7.752GiB")
    mem_limit=$(printf "%s" "$docker_stats_output" | awk '{print $4}')

    # Convert mem_limit to bytes
    mem_limit_bytes=$(convert_to_bytes "$mem_limit")

    # Define the minimum required memory in bytes (93% of 8GiB)
    MIN_MEM_BYTES=7999255104  # 7.44 * 1024^3 ≈ 7.44GiB in bytes

    # Validate that mem_limit_bytes is set and is a valid integer
    if [ -z "$mem_limit_bytes" ]; then
        echo_error "Memory limit not retrieved for Kind cluster '$cluster_name'."
        exit 1
    fi

    case "$mem_limit_bytes" in
        ''|*[!0-9]*)
            echo_error "Invalid memory limit '$mem_limit_bytes' for Kind cluster '$cluster_name'. Expected a numeric value."
            exit 1
            ;;
    esac

    if [ "$mem_limit_bytes" -eq 0 ]; then
        echo_error "No memory limit set for Kind cluster '$cluster_name'. Expected at least 7.44GiB (93% of 8GiB)."
        exit 1
    fi

    if [ "$mem_limit_bytes" -lt "$MIN_MEM_BYTES" ]; then
        # Convert bytes to GiB for logging
        mem_limit_gib=$(bytes_to_gib "$mem_limit_bytes")
        echo_error "Kind cluster '$cluster_name' has insufficient memory allocated: ${mem_limit_gib}GiB (< 7.44GiB)."
        exit 1
    else
        # Convert bytes to GiB for logging
        mem_limit_gib=$(bytes_to_gib "$mem_limit_bytes")
        echo_info "Kind cluster '$cluster_name' has sufficient memory allocated: ${mem_limit_gib}GiB."
    fi
}

# Function to create a new Kind cluster with 8GB memory limit
create_kind_cluster() {
    initial_cluster_name="$1"
    cluster_name="$initial_cluster_name"

    # Check if the cluster already exists
    while kind get clusters | grep -w "^$cluster_name$" >/dev/null 2>&1; do
        echo_error "Kind cluster '$cluster_name' already exists."

        # Prompt the user for a new cluster name
        echo_prompt "Please enter a new cluster name (or type 'exit' to cancel):"
        read -r cluster_name

        # Check if the user wants to exit
        if [ "$cluster_name" = "exit" ]; then
            echo_info "Exiting cluster creation as per user request."
            exit 0
        fi

        # Ensure the new cluster name is not empty
        if [ -z "$cluster_name" ]; then
            echo_error "Cluster name cannot be empty. Please try again."
        fi
    done

    # Inform the user about the RAM requirement
    echo_primary "---------------------------------------------------------"
    echo_primary "  IMPORTANT: OpenGovernance requires a minimum 8 GB RAM"
    echo_primary "---------------------------------------------------------"
    echo_primary ""

    # Check if the system has at least 8 GB of RAM
    required_mem_bytes=8589934592  # 8 * 1024^3 = 8,589,934,592 bytes
    total_mem_bytes=$(get_total_memory_bytes)

    if [ "$total_mem_bytes" -lt "$required_mem_bytes" ]; then
        echo_error "Insufficient system memory. This script requires at least 8 GB of RAM."
        exit 1
    else
        # Convert bytes to GiB for logging
        total_mem_gib=$(bytes_to_gib "$total_mem_bytes")
        echo_info "System memory check passed: Available memory is ${total_mem_gib} GiB."
    fi

    echo_primary "Creating a new Kind Cluster '$cluster_name'"

    # Define Kind cluster configuration with 8GB memory limit

    # Create the cluster using the configuration
    kind create cluster --name "$cluster_name" >> "$DEBUG_LOGFILE" 2>&1 || { echo_error "Failed to create Kind cluster '$cluster_name'."; exit 1; }

    # Set kubectl context to the new cluster
    kubectl config use-context "kind-$cluster_name" >> "$DEBUG_LOGFILE" 2>&1 || { echo_error "Failed to set kubectl context to 'kind-$cluster_name'."; exit 1; }

    echo_info "Set kubectl context to 'kind-$cluster_name'"

    # Validate memory allocation
    validate_memory_allocation "$cluster_name"
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

    echo_info "Completed in ${mins} mins ${secs} secs"
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
