#!/bin/bash

set -e

# Function to display informational messages
function echo_info() {
  echo -e "\n\033[1;34m$1\033[0m\n"
}

# Function to display error messages
function echo_error() {
  echo -e "\n\033[0;31m$1\033[0m\n"
}

# Step 1: Confirm that kubectl is connected to a cluster
echo_info "Step 1: Confirming kubectl configuration"

if ! kubectl cluster-info > /dev/null 2>&1; then
  echo_error "Error: kubectl is not connected to a cluster."
  echo "Please configure your kubectl to connect to a Kubernetes cluster and try again."
  exit 1
else
  echo_info "kubectl is connected to a cluster."
fi

# Step 2: Check if Helm is installed
echo_info "Step 2: Confirming helm installation"

if ! command -v helm &> /dev/null; then
  echo_error "Error: Helm is not installed."
  echo "Please install Helm and try again."
  exit 1
else
  echo_info "Helm is installed."
fi

# Step 3: Add the OpenGovernance Helm repository and update
echo_info "Step 3: Adding OpenGovernance Helm repository and updating"

helm repo add opengovernance https://opengovern.github.io/charts
helm repo update

# Step 4: Install OpenGovernance using Helm if not already installed
echo_info "Step 4: Installing OpenGovernance using Helm (if not already installed)"

# Check if the release 'opengovernance' exists in the 'opengovernance' namespace
if helm ls -n opengovernance | grep opengovernance > /dev/null 2>&1; then
  echo_info "OpenGovernance is already installed. Skipping installation."
else
  helm install -n opengovernance opengovernance \
    opengovernance/opengovernance --create-namespace --timeout=10m
fi

# Step 5: Ensure all Pods are running and/or healthy
echo_info "Step 5: Ensuring all Pods are running and/or healthy"

echo_info "Waiting for all Pods in 'opengovernance' namespace to be ready..."

TIMEOUT=600  # Timeout in seconds (10 minutes)
SLEEP_INTERVAL=10  # Check every 10 seconds
ELAPSED=0

while true; do
  NOT_READY_PODS=$(kubectl get pods -n opengovernance --no-headers | awk '{print $3}' | grep -v -E 'Running|Succeeded|Completed' | wc -l)
  if [ "$NOT_READY_PODS" -eq 0 ]; then
    echo_info "All Pods are running and/or healthy."
    break
  fi

  if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    echo_error "Error: Some Pods are not running or healthy after $TIMEOUT seconds."
    kubectl get pods -n opengovernance
    exit 1
  fi

  echo "Waiting for Pods to be ready... ($ELAPSED/$TIMEOUT seconds elapsed)"
  sleep $SLEEP_INTERVAL
  ELAPSED=$((ELAPSED + SLEEP_INTERVAL))
done

echo_info "All steps completed successfully."
