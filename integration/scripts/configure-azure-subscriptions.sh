#!/bin/bash

# =====================================================================
# Script Name: assign_reader_role.sh
# Description: Creates a Service Principal (SPN), assigns the "Reader"
#              role to it across all enabled Azure subscriptions, and
#              outputs essential SPN information, including Object ID.
# Requirements:
#   - Azure CLI installed and authenticated
#   - Sufficient permissions to create SPNs and assign roles at the
#     subscription level
# =====================================================================

# ----------------------------- Variables -----------------------------

# Service Principal Display Name
SPN_DISPLAY_NAME="OpenGovernanceSPN-Subscriptions"

# Role to Assign
ROLE_NAME="Reader"

# ------------------------- Function Definitions ----------------------

# Function to check if user is logged in
check_login() {
  if ! az account show &> /dev/null; then
    echo "Error: You are not logged in to Azure CLI."
    echo "Please run 'az login' to authenticate."
    exit 1
  fi
}

# Function to create SPN without jq dependency
create_spn() {
  local spn_name="$1"
  local spn_output
  local app_id
  local client_secret
  local tenant_id

  echo "Creating Service Principal '$spn_name'..."

  # Create SPN and capture the output as TSV
  spn_output=$(az ad sp create-for-rbac --name "$spn_name" \
    --query "[appId,password,tenant]" \
    -o tsv \
    --only-show-errors)

  if [ $? -ne 0 ]; then
    echo "Error: Failed to create Service Principal."
    echo "$spn_output"
    exit 1
  fi

  # Check if spn_output is empty
  if [ -z "$spn_output" ]; then
    echo "Error: SPN creation returned empty output."
    exit 1
  fi

  # Parse the TSV output into variables using 'set --'
  set -- $spn_output

  # Assign variables to positional parameters
  app_id="$1"
  client_secret="$2"
  tenant_id="$3"

  # Validate if all variables are set
  if [ -z "$app_id" ] || [ -z "$client_secret" ] || [ -z "$tenant_id" ]; then
    echo "Error: Failed to parse SPN details. Ensure the Azure CLI returned appId, password, and tenant."
    echo "Returned Output:"
    echo "$spn_output"
    exit 1
  fi


  # Export SPN details
  APP_DISPLAY_NAME="$spn_name"
  APP_ID="$app_id"
  CLIENT_ID="$app_id"    # Typically same as AppID
  CLIENT_SECRET="$client_secret"
  TENANT_ID="$tenant_id"
}

# Function to assign role to SPN in a subscription
assign_role() {
  local spn_id="$1"
  local subscription_id="$2"
  local role="$3"

  # Suppress all output except errors
  az role assignment create \
    --assignee "$spn_id" \
    --role "$role" \
    --scope "/subscriptions/$subscription_id" \
    --only-show-errors &> /dev/null

  if [ $? -eq 0 ]; then
    return 0  # Success
  else
    return 1  # Failure
  fi
}

# ----------------------------- Main Script ---------------------------

# Ensure the script is run with Bash
if [ -z "$BASH_VERSION" ]; then
  echo "Error: This script must be run with Bash."
  exit 1
fi

# Step 1: Check if the user is logged in
check_login

# Step 2: Create SPN
create_spn "$SPN_DISPLAY_NAME"

# Step 3: Retrieve the Application Object ID
APP_OBJECT_ID=$(az ad app show --id "$APP_ID" --query "id" -o tsv --only-show-errors)

if [ -z "$APP_OBJECT_ID" ]; then
  echo "Error: Unable to retrieve Application Object ID."
  exit 1
fi

# (Optional) Retrieve the Service Principal Object ID if needed
SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query "id" -o tsv --only-show-errors)

if [ -z "$SP_OBJECT_ID" ]; then
  echo "Error: Unable to retrieve Service Principal Object ID."
  exit 1
fi

# Display SPN details, including Object IDs
echo "---------------------------------"
echo "TenantID: $TENANT_ID"
echo "Application (Client) ID: $APP_ID"
echo "Object ID: $APP_OBJECT_ID"
echo "Client Secret: $CLIENT_SECRET"
echo "---------------------------------"

# Step 4: Retrieve all enabled subscriptions
ENABLED_SUBSCRIPTIONS=$(az account list --query "[?state=='Enabled'].id" -o tsv --only-show-errors)

# Check if there are any enabled subscriptions
if [ -z "$ENABLED_SUBSCRIPTIONS" ]; then
  echo "No enabled subscriptions found. Exiting."
  exit 0
fi

# Count the number of enabled subscriptions
SUBSCRIPTION_COUNT=$(echo "$ENABLED_SUBSCRIPTIONS" | wc -l | tr -d '[:space:]')

# Step 5: Assign the Reader role to the SPN across all enabled subscriptions
ASSIGNMENT_COUNT=0
FAILED_ASSIGNMENTS=0


for SUBSCRIPTION_ID in $ENABLED_SUBSCRIPTIONS; do
  assign_role "$APP_OBJECT_ID" "$SUBSCRIPTION_ID" "$ROLE_NAME"

  if [ $? -eq 0 ]; then
    ASSIGNMENT_COUNT=$((ASSIGNMENT_COUNT + 1))
  else
    FAILED_ASSIGNMENTS=$((FAILED_ASSIGNMENTS + 1))
  fi
done

# Step 6: Output Summary
if [ "$FAILED_ASSIGNMENTS" -eq 0 ]; then
  # No failures
  echo "Role Assignment completed successfully on $SUBSCRIPTION_COUNT subscriptions."
else
  # There were failures
  echo "Role Assignment failed on $FAILED_ASSIGNMENTS and completed successfully on $ASSIGNMENT_COUNT subscriptions."
fi