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
echo_info "Step 1: Checking Cluster"

if ! kubectl cluster-info > /dev/null 2>&1; then
  echo_error "Error: kubectl is not connected to a cluster."
  echo "Please configure kubectl to connect to a Kubernetes cluster and try again."
  exit 1
fi

# Step 2: Check if Helm is installed
echo_info "Step 2: Checking Helm"

if ! command -v helm &> /dev/null; then
  echo_error "Error: Helm is not installed."
  echo "Please install Helm and try again."
  exit 1
fi

# Step 3: Add the OpenGovernance Helm repository and update
echo_info "Step 3: Adding Helm repository"

helm repo add opengovernance https://opengovern.github.io/charts
helm repo update

# Step 4: Install OpenGovernance using Helm if not already installed
echo_info "Step 4: Installing OpenGovernance using Helm"

# Check if the release 'opengovernance' exists in the 'opengovernance' namespace
if helm ls -n opengovernance | grep opengovernance > /dev/null 2>&1; then
  echo_info "OpenGovernance is already installed. Skipping installation."
else
  helm install -n opengovernance opengovernance \
    opengovernance/opengovernance --create-namespace --timeout=10m
fi

# Step 5: Ensure all Pods are running and/or healthy
echo_info "Step 5: Checking Pods"

echo_info "Waiting for all Pod to be ready..."

TIMEOUT=600  # Timeout in seconds (10 minutes)
SLEEP_INTERVAL=10  # Check every 10 seconds
ELAPSED=0

while true; do
  # Get the count of pods that are not in Running, Succeeded, or Completed state
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

# Step 6: Check the status of 'migrator-job' pods
echo_info "Step 6: Checking the status of 'migrator-job' pods"

# Get the list of pods starting with 'migrator-job'
MIGRATOR_PODS=$(kubectl get pods -n opengovernance -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep '^migrator-job')

if [ -z "$MIGRATOR_PODS" ]; then
  echo_info "No 'migrator-job' pods found."
else
  # Flag to check if all migrator-job pods are completed
  ALL_COMPLETED=true
  for POD in $MIGRATOR_PODS; do
    STATUS=$(kubectl get pod "$POD" -n opengovernance -o jsonpath='{.status.phase}')
    if [ "$STATUS" != "Succeeded" ] && [ "$STATUS" != "Completed" ]; then
      echo_error "Pod '$POD' is in '$STATUS' state. It needs to be in 'Completed' state."
      ALL_COMPLETED=false
    else
      echo_info "Pod '$POD' is in 'Completed' state."
    fi
  done

  if [ "$ALL_COMPLETED" = false ]; then
    echo_error "One or more 'migrator-job' pods are not in 'Completed' state."
    exit 1
  else
    echo_info "All 'migrator-job' pods are in 'Completed' state."
  fi
fi

echo_info "All steps completed successfully."
