#!/bin/bash

# Function to check if AWS CLI is installed
check_aws_cli_installed() {
    if ! command -v aws &> /dev/null; then
        echo "AWS CLI is not installed. Please install it before running this script."
        exit 1
    fi
}

# Function to check if AWS CLI is configured
check_aws_cli_configured() {
    if ! aws sts get-caller-identity &> /dev/null; then
        echo "AWS CLI is not configured. Please configure your AWS credentials."
        exit 1
    fi
    echo "AWS CLI is installed and configured."
}

# Function to download the CloudFormation template using curl
download_template() {
    echo "Downloading the CloudFormation template..."
    curl -s -o AWSOrganizationDeployment.yml https://raw.githubusercontent.com/opengovern/integration-automation/main/aws-accounts/AWSOrganizationDeployment.yml
    if [ $? -ne 0 ]; then
        echo "Failed to download the CloudFormation template."
        exit 1
    fi
}

# Function to retrieve the ROOT_ID from AWS Organizations
get_root_id() {
    echo "Retrieving the ROOT_ID from AWS Organizations..."
    ROOT_ID=$(aws organizations list-roots --query 'Roots[0].Id' --output text)
    if [ -z "$ROOT_ID" ]; then
        echo "Failed to retrieve ROOT_ID."
        exit 1
    fi
    echo "ROOT_ID obtained: $ROOT_ID"
}

# Function to check if the CloudFormation stack exists
stack_exists() {
    aws cloudformation describe-stacks --stack-name OpenGovernance-Deploy &> /dev/null
    if [ $? -eq 0 ]; then
        return 0  # Stack exists
    else
        return 1  # Stack does not exist
    fi
}

# Function to deploy or update the CloudFormation stack
deploy_stack() {
    echo "Deploying the CloudFormation stack..."
    if stack_exists; then
        echo "Stack exists. Updating the existing stack..."
        aws cloudformation update-stack \
            --stack-name OpenGovernance-Deploy \
            --template-body file://AWSOrganizationDeployment.yml \
            --capabilities CAPABILITY_NAMED_IAM \
            --parameters ParameterKey=OrganizationUnitList,ParameterValue=$ROOT_ID
        if [ $? -ne 0 ]; then
            echo "Failed to update the CloudFormation stack."
            exit 1
        fi
        ACTION="update"
    else
        echo "Stack does not exist. Creating a new stack..."
        aws cloudformation create-stack \
            --stack-name OpenGovernance-Deploy \
            --template-body file://AWSOrganizationDeployment.yml \
            --capabilities CAPABILITY_NAMED_IAM \
            --parameters ParameterKey=OrganizationUnitList,ParameterValue=$ROOT_ID
        if [ $? -ne 0 ]; then
            echo "Failed to create the CloudFormation stack."
            exit 1
        fi
        ACTION="create"
    fi
}

# Function to wait until the stack status is COMPLETE
wait_for_stack_completion() {
    if [ "$ACTION" == "create" ]; then
        echo "Waiting for the CloudFormation stack to reach CREATE_COMPLETE status..."
        aws cloudformation wait stack-create-complete --stack-name OpenGovernance-Deploy
        if [ $? -ne 0 ]; then
            echo "CloudFormation stack creation failed or timed out."
            exit 1
        fi
        echo "CloudFormation stack has been successfully created."
    elif [ "$ACTION" == "update" ]; then
        echo "Waiting for the CloudFormation stack to reach UPDATE_COMPLETE status..."
        aws cloudformation wait stack-update-complete --stack-name OpenGovernance-Deploy
        if [ $? -ne 0 ]; then
            # Check if the error is due to no updates being necessary
            OUTPUT=$(aws cloudformation describe-stacks --stack-name OpenGovernance-Deploy 2>&1)
            if echo "$OUTPUT" | grep -q "No updates are to be performed"; then
                echo "No updates are to be performed."
            else
                echo "CloudFormation stack update failed or timed out."
                exit 1
            fi
        else
            echo "CloudFormation stack has been successfully updated."
        fi
    fi
}

# Function to retrieve the IAM username from the CloudFormation stack outputs
retrieve_iam_user() {
    echo "Retrieving the IAM username from the stack outputs..."
    IAM_USER=$(aws cloudformation describe-stacks \
        --stack-name OpenGovernance-Deploy \
        --query "Stacks[0].Outputs[?OutputKey=='IAMUserNameInMasterAccount'].OutputValue" \
        --output text)
    if [ -z "$IAM_USER" ]; then
        echo "Failed to retrieve the IAM username."
        exit 1
    fi
    echo "IAM username obtained: $IAM_USER"
}

# Function to generate IAM access keys for the user
generate_access_keys() {
    echo "Generating IAM access keys for the user..."
    aws iam create-access-key --user-name $IAM_USER
    if [ $? -ne 0 ]; then
        echo "Failed to create access keys for the IAM user."
        exit 1
    fi
    echo "Access keys have been successfully created for user $IAM_USER."
}

# Main execution control flow
main() {
    check_aws_cli_installed
    check_aws_cli_configured
    download_template
    get_root_id
    deploy_stack
    wait_for_stack_completion
    retrieve_iam_user
    generate_access_keys
}

# Execute the main function
main
