#!/bin/bash

# -------------------------------
# Configuration: Define Groupings
# -------------------------------

declare -A GROUPINGS=(
    ["postgres"]="*-postgresql-*"
    ["opensearch"]="opensearch-*"
    ["vault"]="*-vault-*"
    ["keda"]="keda-*"
    ["demo"]="*-demo-*"
    ["nats"]="*-nats-*"
    ["auth"]="auth-*"
)

# Namespace to monitor
NAMESPACE="opengovernance"

# -------------------------------
# Initialize Group Variables
# -------------------------------

for group in "${!GROUPINGS[@]}"; do
    declare "${group}_pods=0"
    declare "${group}_start_epoch=0"
    declare "${group}_latest_ready_epoch=0"
done

# Function to process pods and display readiness times
process_pods() {
    # Fetch all pods in JSON format
    PODS_JSON=$(kubectl get pods -n "$NAMESPACE" -o json)

    # Check if kubectl command was successful
    if [ $? -ne 0 ] || [ -z "$PODS_JSON" ]; then
        echo "$(gdate '+%Y-%m-%d %H:%M:%S') - Error: Unable to fetch pods or received empty JSON. Please check your kubectl configuration."
        return
    fi

    # Reset group variables for each iteration
    for group in "${!GROUPINGS[@]}"; do
        eval "${group}_pods=0"
        eval "${group}_start_epoch=0"
        eval "${group}_latest_ready_epoch=0"
    done

    # Header for individual pod readiness times
    echo -e "POD_NAME\tDURATION (HH:MM:SS)"

    # Use jq to extract pod name, startTime, and Ready condition's lastTransitionTime
    echo "$PODS_JSON" | jq -r '.items[] | "\(.metadata.name)\t\(.status.startTime // "N/A")\t\(.status.conditions[]? | select(.type=="Ready") | .lastTransitionTime // "N/A")"' | \
    while IFS=$'\t' read -r pod start_time ready_time; do
        # Check for missing start_time or ready_time
        if [ "$start_time" = "N/A" ] || [ "$ready_time" = "N/A" ]; then
            echo -e "${pod}\tTimestamp Unavailable"
            continue
        fi

        # Convert timestamps to epoch seconds using gdate (use date if on Linux)
        start_epoch=$(gdate -d "$start_time" +%s 2>/dev/null)
        ready_epoch=$(gdate -d "$ready_time" +%s 2>/dev/null)

        # Validate epoch conversion
        if [ -z "$start_epoch" ] || [ -z "$ready_epoch" ]; then
            echo -e "${pod}\tInvalid Timestamp Format"
            continue
        fi

        # Calculate the difference in seconds
        diff_seconds=$((ready_epoch - start_epoch))

        # Validate the time difference
        if [ "$diff_seconds" -lt 0 ] || [ "$diff_seconds" -gt 86400 ]; then
            echo -e "${pod}\tUnrealistic Time Difference"
            continue
        fi

        # Determine which group the pod belongs to
        matched_group=""
        for group in "${!GROUPINGS[@]}"; do
            pattern="${GROUPINGS[$group]}"
            if [[ $pod == $pattern ]]; then
                matched_group="$group"
                break
            fi
        done

        if [ -n "$matched_group" ]; then
            # Increment pod count for the group
            eval "${matched_group}_pods=\$(( ${matched_group}_pods + 1 ))"

            # Update earliest start time for the group
            current_group_start=$(eval echo \${${matched_group}_start_epoch})
            if [ "$current_group_start" -eq 0 ] || [ "$start_epoch" -lt "$current_group_start" ]; then
                eval "${matched_group}_start_epoch=$start_epoch"
            fi

            # Update latest readiness time for the group
            current_group_ready=$(eval echo \${${matched_group}_latest_ready_epoch})
            if [ "$ready_epoch" -gt "$current_group_ready" ]; then
                eval "${matched_group}_latest_ready_epoch=$ready_epoch"
            fi
        else
            # Pod does not belong to any predefined group; display individually
            # Format the difference into HH:MM:SS
            hours=$((diff_seconds / 3600))
            minutes=$(((diff_seconds % 3600) / 60))
            seconds=$((diff_seconds % 60))
            diff_hms=$(printf '%02d:%02d:%02d' "$hours" "$minutes" "$seconds")
            echo -e "${pod}\t${diff_hms}"
        fi
    done

    # -------------------------------
    # Display Group Readiness Times
    # -------------------------------

    echo -e "\nGrouped Workload Readiness Times:"

    for group in "${!GROUPINGS[@]}"; do
        pods_var="${group}_pods"
        start_var="${group}_start_epoch"
        ready_var="${group}_latest_ready_epoch"

        pod_count=$(eval echo \${$pods_var})
        start_epoch=$(eval echo \${$start_var})
        latest_ready_epoch=$(eval echo \${$ready_var})

        if [ "$pod_count" -gt 0 ] && [ "$start_epoch" -gt 0 ] && [ "$latest_ready_epoch" -gt 0 ]; then
            # Calculate the difference in seconds
            group_diff_seconds=$((latest_ready_epoch - start_epoch))

            # Validate the time difference
            if [ "$group_diff_seconds" -ge 0 ] && [ "$group_diff_seconds" -le 86400 ]; then
                # Format the difference into HH:MM:SS
                hours=$((group_diff_seconds / 3600))
                minutes=$(((group_diff_seconds % 3600) / 60))
                seconds=$((group_diff_seconds % 60))
                group_diff_hms=$(printf '%02d:%02d:%02d' "$hours" "$minutes" "$seconds")
                echo -e "${group}[${pod_count}]\t${group_diff_hms}"
            else
                echo -e "${group}[${pod_count}]\tUnrealistic Time Difference"
            fi
        else
            echo -e "${group}[${pod_count}]\tIncomplete Data"
        fi
    done

    echo -e "----------------------------------------"
}

# -------------------------------
# Main Loop: Monitor Continuously
# -------------------------------

# Infinite loop to monitor pod readiness every 15 seconds
while true; do
    process_pods
    sleep 15
done
