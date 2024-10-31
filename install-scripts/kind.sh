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
DEBUG_MODE=true  # Helm operates in debug mode
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

# Function to run helm commands with a timeout of 15 minutes in debug mode
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
        echo_info "Adding Helm repository '$REPO_NAME'."
        helm repo add "$REPO_NAME" "$REPO_URL" || { echo_error "Failed to add Helm repository '$REPO_NAME'."; exit 1; }
    else
        echo_info "Helm repository '$REPO_NAME' already exists."
    fi

    echo_info "Updating Helm repositories."
    helm repo update || { echo_error "Failed to update Helm repositories."; exit 1; }
}


# Function to check prerequisites
check_prerequisites() {
    # List of required commands
    REQUIRED_COMMANDS="kind kubectl helm yq"

    echo_info "Checking for required tools..."

    # Check if each command is installed
    for cmd in $REQUIRED_COMMANDS; do
        check_command "$cmd"
    done


    # Ensure Helm repository is added and updated
    ensure_helm_repo

    echo_info "Checking Prerequisites...Completed"
}

# -----------------------------
# Main Deployment Steps
# -----------------------------

# Start of the script
echo_primary "Starting OpenGovernance deployment script."

# Check prerequisites
check_prerequisites

# Step 1: Create a Kind cluster named 'opengovernance'
echo_info "Creating Kind cluster named '$NAMESPACE'."
kind create cluster --name "$NAMESPACE" || { echo_error "Failed to create Kind cluster '$NAMESPACE'."; exit 1; }

# Step 2: Tell kubectl to use the 'opengovernance' context
CONTEXT_NAME="kind-$NAMESPACE"
echo_info "Setting kubectl context to '$CONTEXT_NAME'."
kubectl config use-context "$CONTEXT_NAME" || { echo_error "Failed to set kubectl context to '$CONTEXT_NAME'."; exit 1; }

# Step 3: Add the Helm repository and update
echo_info "Adding Helm repository 'opengovernance'."
helm repo add opengovernance https://opengovern.github.io/charts/ || { echo_error "Failed to add Helm repository 'opengovernance'."; exit 1; }

echo_info "Updating Helm repositories."
helm repo update || { echo_error "Failed to update Helm repositories."; exit 1; }

# Step 4: Install the 'opengovernance' chart into the specified namespace
echo_info "Installing 'opengovernance' Helm chart into namespace '$NAMESPACE'."
helm_install_with_timeout -n "$NAMESPACE" opengovernance opengovernance/opengovernance --create-namespace || { echo_error "Helm installation failed."; exit 1; }

# Completion message
echo_primary "OpenGovernance deployment completed successfully."

# -----------------------------
# End of Script
# -----------------------------
