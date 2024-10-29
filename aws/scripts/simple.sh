#!/bin/bash

set -euo pipefail

# -----------------------------
# Logging Configuration
# -----------------------------
DEBUG_MODE=false  # Set to true to enable debug mode
LOGFILE="$HOME/opengovernance_install.log"

# Ensure the log directory exists
mkdir -p "$(dirname "$LOGFILE")"

# Redirect all output to the log file and the console
exec > >(tee -i "$LOGFILE") 2>&1

# Open file descriptor 3 for appending to the log file only
exec 3>> "$LOGFILE"

# Initialize variables
SKIP_INFRA_SETUP=false  # Default value for --skip-infra-setup

# -----------------------------
# Function Definitions
# -----------------------------

# Function to display informational messages to console and log
echo_info() {
    local message="$1"
    # Only display message if in debug mode
    if [ "$DEBUG_MODE" = true ]; then
        printf "%s\n" "$message"
    fi
    # Log detailed message
    echo "$message" >&3
}

# Function to display primary messages to console and log
echo_primary() {
    local message="$1"
    printf "%s\n" "$message"
    # Log detailed message
    echo "$message" >&3
}

# Function to display error messages to console and log
echo_error() {
    local message="$1"
    # Always print concise error message to console
    printf "Error: %s\n" "$message"
    # Log detailed message
    echo "Error: $message" >&3
}

# Function to display usage information
usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --debug                 Enable debug mode for detailed output."
    echo "  --skip-infra-setup      Skip infrastructure setup if prerequisites are met."
    echo "  -h, --help              Display this help message."
    exit 1
}

# Function to append --debug to all Helm commands
helm_quiet() {
    helm "$@" --debug
}

# Function to check if a command exists
check_command() {
    local cmd=$1
    if ! command -v "$cmd" &> /dev/null; then
        echo_error "Required command '$cmd' is not installed."
        exit 1
    fi
}

# Function to check if either Terraform or OpenTofu is installed
check_terraform_or_opentofu() {
    if command -v terraform &> /dev/null; then
        INFRA_TOOL="terraform"
        echo_info "Terraform is installed."
    elif command -v tofu &> /dev/null; then
        INFRA_TOOL="tofu"
        echo_info "OpenTofu is installed."
    else
        echo_error "Neither Terraform nor OpenTofu is installed. Please install one of them and retry."
        exit 1
    fi
}

# Function to check AWS CLI authentication
check_aws_auth() {
    if ! aws sts get-caller-identity &> /dev/null; then
        echo_error "AWS CLI is not configured or authenticated. Please run 'aws configure' and ensure you have the necessary permissions."
        exit 1
    fi
    echo_info "AWS CLI is authenticated."
}

# Function to get cluster info
get_cluster_info() {
    kubectl cluster-info | head -n 1
}

# Function to confirm the Kubernetes provider is AWS
confirm_provider_is_aws() {
    local cluster_info
    cluster_info=$(get_cluster_info)
    if [[ -z "$cluster_info" ]]; then
        echo_error "Unable to retrieve cluster info."
        return 1
    fi
    echo_info "Cluster info: $cluster_info"
    if [[ "$cluster_info" == *eks.amazonaws.com* ]]; then
        echo_info "Cluster is running on AWS EKS."
        return 0
    else
        echo_error "Cluster is not running on AWS EKS."
        return 1
    fi
}

# Function to check if there are at least three ready nodes
check_ready_nodes() {
    local ready_nodes
    ready_nodes=$(kubectl get nodes --no-headers | grep -c ' Ready ')
    if [ "$ready_nodes" -lt 3 ]; then
        echo_error "At least three Kubernetes nodes must be ready. Currently, $ready_nodes node(s) are ready."
        return 1
    else
        echo_info "There are $ready_nodes ready nodes."
        return 0
    fi
}

# Function to check if kubectl is connected to a cluster, Helm is installed, and at least three nodes are ready
check_prerequisites() {
    # Check if kubectl is connected to a cluster
    if ! kubectl cluster-info > /dev/null 2>&1; then
        echo_error "kubectl is not connected to a cluster."
        echo "Please configure kubectl to connect to a Kubernetes cluster and try again."
        exit 1
    fi

    # Check if Helm is installed
    if ! command -v helm &> /dev/null; then
        echo_error "Helm is not installed."
        echo "Please install Helm and try again."
        exit 1
    fi

    # Check if there are at least three ready nodes
    READY_NODES=$(kubectl get nodes --no-headers | grep -c ' Ready ')
    if [ "$READY_NODES" -lt 3 ]; then
        echo_error "At least three Kubernetes nodes must be ready. Currently, $READY_NODES node(s) are ready."
        exit 1
    fi

    # If all checks pass
    echo_info "Checking Prerequisites...Completed"
}

# Function to clone the repository
clone_repository() {
    REPO_URL="https://github.com/opengovern/deploy-opengovernance.git"
    REPO_DIR="deploy-opengovernance"
    if [ -d "$REPO_DIR" ]; then
        echo_info "Repository '$REPO_DIR' already exists. Pulling the latest changes..."
        git -C "$REPO_DIR" pull
    else
        echo_info "Cloning repository from $REPO_URL..."
        git clone "$REPO_URL"
    fi
}

# Function to deploy infrastructure using Terraform or OpenTofu
deploy_infrastructure() {
    INFRA_DIR="deploy-opengovernance/aws/infra"

    echo_info "Deploying infrastructure. This step may take 10-15 minutes..."
    echo_info "Navigating to infrastructure directory: $INFRA_DIR"
    cd "$INFRA_DIR"

    if [ "$INFRA_TOOL" == "terraform" ]; then
        echo_info "Initializing Terraform..."
        terraform init

        echo_info "Planning Terraform deployment..."
        terraform plan

        echo_info "Applying Terraform deployment..."
        terraform apply --auto-approve
    elif [ "$INFRA_TOOL" == "tofu" ]; then
        echo_info "Initializing OpenTofu..."
        tofu init

        echo_info "Planning OpenTofu deployment..."
        tofu plan

        echo_info "Applying OpenTofu deployment..."
        tofu apply -auto-approve
    fi

    echo_info "Connecting to the Kubernetes cluster..."
    eval "$("$INFRA_TOOL" output -raw configure_kubectl)"
}

# Function to check OpenGovernance readiness
check_opengovernance_readiness() {
    # Check the readiness of all pods in the 'opengovernance' namespace
    local not_ready_pods
    # Extract the STATUS column (3rd column) and exclude 'Running' and 'Completed'
    not_ready_pods=$(kubectl get pods -n "$NAMESPACE" --no-headers | awk '{print $3}' | grep -v -E 'Running|Completed' || true)

    if [ -z "$not_ready_pods" ]; then
        APP_HEALTHY=true
    else
        echo_error "Some OpenGovernance pods are not healthy."
        kubectl get pods -n "$NAMESPACE"
        APP_HEALTHY=false
    fi
}

# Function to check pods and migrator jobs
check_pods_and_jobs() {
    local attempts=0
    local max_attempts=12  # 12 attempts * 30 seconds = 6 minutes
    local sleep_time=30

    while [ $attempts -lt $max_attempts ]; do
        check_opengovernance_readiness
        if [ "${APP_HEALTHY:-false}" = true ]; then
            return 0
        fi
        attempts=$((attempts + 1))
        echo_info "Waiting for pods to become ready... ($attempts/$max_attempts)"
        sleep "$sleep_time"
    done

    echo_error "OpenGovernance did not become ready within expected time."
    exit 1
}

# Function to prompt the user for OpenGovernance setup options
prompt_user_options() {
    echo ""
    echo "========================================="
    echo "OpenGovernance Application Installed Successfully!"
    echo "========================================="
    echo "Please choose how you would like to configure access to OpenGovernance:"
    echo "1. Configure with Domain and SSL"
    echo "2. Configure with Domain but Without SSL"
    echo "3. Connect to the app as is (Provide Port-Forwarding Instructions)"
    read -rp "Enter your choice (1/2/3): " USER_CHOICE

    case "$USER_CHOICE" in
        1)
            SETUP_DOMAIN_AND_SSL=1
            ;;
        2)
            SETUP_DOMAIN_NO_SSL=1
            ;;
        3)
            CONNECT_AS_IS=1
            ;;
        *)
            echo_error "Invalid choice. Please run the script again and select a valid option."
            exit 1
            ;;
    esac
}

# Function to provide port-forwarding instructions
provide_port_forward_instructions() {
    echo ""
    echo "========================================="
    echo "Port-Forwarding Instructions"
    echo "========================================="
    echo "OpenGovernance is running but not accessible via Ingress."
    echo "You can access it using port-forwarding as follows:"
    echo ""
    echo "kubectl port-forward -n $NAMESPACE service/nginx-proxy 8080:80"
    echo ""
    echo "Then, access it at http://localhost:8080"
    echo ""
    echo "To sign in, use the following default credentials:"
    echo "  Username: admin@opengovernance.io"
    echo "  Password: password"
    echo ""
}

# Function to configure OpenGovernance based on user input
configure_opengovernance() {
    if [ "${SETUP_DOMAIN_AND_SSL:-0}" -eq 1 ]; then
        echo_info "Setting up OpenGovernance with Domain and SSL..."
        setup_with_domain_and_ssl
    elif [ "${SETUP_DOMAIN_NO_SSL:-0}" -eq 1 ]; then
        echo_info "Setting up OpenGovernance with Domain but Without SSL..."
        setup_with_domain_no_ssl
    elif [ "${CONNECT_AS_IS:-0}" -eq 1 ]; then
        echo_info "Providing port-forwarding instructions to access OpenGovernance..."
        provide_port_forward_instructions
    else
        echo_error "No valid setup option selected. Exiting."
        exit 1
    fi
}

# Function to set up OpenGovernance with Domain and SSL
setup_with_domain_and_ssl() {
    # Ensure required commands are installed
    check_command "jq"
    check_command "aws"
    check_command "kubectl"
    check_command "helm"

    # Prompt for domain name
    read -rp "Enter the domain name (e.g., demo.opengovernance.io): " DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        echo_error "Domain name cannot be empty."
        exit 1
    fi

    # Time between status checks (in seconds)
    CHECK_INTERVAL_CERT=60      # For certificate status
    CHECK_INTERVAL_LB=20        # For Load Balancer DNS
    CHECK_COUNT_CERT=60         # Maximum number of certificate checks (~1 hour)
    CHECK_COUNT_LB=6            # Maximum number of Load Balancer DNS checks (~120 seconds)

    # Function to request a new ACM certificate
    request_certificate() {
        echo_info "Requesting a new ACM certificate for domain: $DOMAIN"

        REQUEST_OUTPUT=$(aws acm request-certificate \
            --domain-name "$DOMAIN" \
            --validation-method DNS \
            --idempotency-token "deploy_$(date +%Y%m%d%H%M%S)" \
            --region "$REGION")

        CERTIFICATE_ARN=$(echo "$REQUEST_OUTPUT" | jq -r '.CertificateArn')
        if [[ -z "$CERTIFICATE_ARN" || "$CERTIFICATE_ARN" == "null" ]]; then
            echo_error "Failed to retrieve Certificate ARN after requesting."
            exit 1
        fi
        echo_info "Certificate ARN: $CERTIFICATE_ARN"
    }

    # Function to retrieve existing ACM certificate ARN
    get_certificate_arn() {
        echo_info "Searching for existing ACM certificates for domain: $DOMAIN"
        CERTIFICATE_ARN=$(aws acm list-certificates \
            --region "$REGION" \
            --query "CertificateSummaryList[?DomainName=='$DOMAIN'].CertificateArn" \
            --output text)

        if [[ -z "$CERTIFICATE_ARN" ]]; then
            echo_info "No existing ACM certificate found for domain: $DOMAIN"
            CERTIFICATE_ARN=""
        else
            echo_info "Found existing Certificate ARN: $CERTIFICATE_ARN"
        fi
    }

    # Function to check certificate status
    check_certificate_status() {
        local arn=$1
        STATUS=$(aws acm describe-certificate \
            --certificate-arn "$arn" \
            --region "$REGION" \
            --query "Certificate.Status" \
            --output text)

        echo "$STATUS"
    }

    # Function to get DNS validation records
    get_validation_records() {
        local arn=$1
        echo_info "Retrieving DNS validation records..."
        VALIDATION_RECORDS=$(aws acm describe-certificate \
            --certificate-arn "$arn" \
            --region "$REGION" \
            --query "Certificate.DomainValidationOptions[].ResourceRecord" \
            --output json)
    }

    # Function to create Ingress with SSL
    create_ingress() {
        echo_info "Creating or updating Kubernetes Ingress: $INGRESS_NAME in namespace: $NAMESPACE"

        helm_quiet upgrade --install "$HELM_RELEASE" "$HELM_CHART" -n "$NAMESPACE" --create-namespace -f - <<EOF
global:
  domain: ${DOMAIN}
dex:
  config:
    issuer: https://${DOMAIN}/dex
EOF

        echo_info "Ingress $INGRESS_NAME has been created/updated."
    }

    # Function to retrieve Load Balancer DNS Name with polling
    get_load_balancer_dns() {
        echo_info "Retrieving Load Balancer DNS name..."
        local attempt=1
        while [[ $attempt -le $CHECK_COUNT_LB ]]; do
            LB_DNS=$(kubectl get ingress "$INGRESS_NAME" -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)

            if [[ -n "$LB_DNS" ]]; then
                echo_info "Load Balancer DNS: $LB_DNS"
                return 0
            else
                echo_info "Attempt $attempt/$CHECK_COUNT_LB: Load Balancer DNS not available yet. Waiting for $CHECK_INTERVAL_LB seconds..."
                ((attempt++))
                sleep "$CHECK_INTERVAL_LB"
            fi
        done

        echo_error "Failed to retrieve Load Balancer DNS after $CHECK_COUNT_LB attempts."
        echo "Please check your Kubernetes Ingress resource manually."
        echo ""
        return 1
    }

    # Function to prompt user to create CNAME records for certificate validation
    prompt_cname_validation_creation() {
        echo ""
        echo "==============================="
        echo "CNAME Record Creation Required"
        echo "==============================="
        echo "Please create the following CNAME records in your DNS provider to validate the certificate:"
        echo ""

        # Iterate over each validation record and display details
        echo "$VALIDATION_RECORDS" | jq -c '.[]' | while read -r RECORD; do
            CNAME_HOST=$(echo "$RECORD" | jq -r '.Name')
            CNAME_VALUE=$(echo "$RECORD" | jq -r '.Value')

            # Remove trailing dot for user-friendliness, if present
            CNAME_HOST="${CNAME_HOST%.}"
            CNAME_VALUE="${CNAME_VALUE%.}"

            echo "Host/Name: $CNAME_HOST"
            echo "Type: CNAME"
            echo "Value/Points to: $CNAME_VALUE"
            echo "TTL: 300 (or default)"
            echo ""
        done

        echo "After creating the CNAME records, please wait for DNS propagation to complete."
        echo "You can use tools like [DNS Checker](https://dnschecker.org/) to verify the propagation."
        read -rp "Press Enter to continue after creating the CNAME records..."
    }

    # Function to prompt user to create CNAME records for domain mapping
    prompt_cname_domain_creation() {
        echo ""
        echo "==============================="
        echo "CNAME Record Creation Required"
        echo "==============================="
        echo "Please create the following CNAME record in your DNS provider to map your domain to the Load Balancer:"
        echo ""
        echo "Host/Name: $DOMAIN"
        echo "Type: CNAME"
        echo "Value/Points to: $LB_DNS"
        echo "TTL: 300 (or default)"
        echo ""
        echo "After creating the CNAME record, your service should be accessible at https://$DOMAIN"
        echo ""
    }

    # Function to wait for ACM certificate to be issued
    wait_for_certificate_issuance() {
        local arn=$1
        local attempts=0

        echo_info "Starting to monitor the certificate status. This may take some time..."

        while [[ $attempts -lt $CHECK_COUNT_CERT ]]; do
            STATUS=$(check_certificate_status "$arn")
            echo_info "Certificate Status: $STATUS"

            if [[ "$STATUS" == "ISSUED" ]]; then
                echo_info "Certificate is now ISSUED."
                return 0
            elif [[ "$STATUS" == "PENDING_VALIDATION" ]]; then
                echo_info "Certificate is still PENDING_VALIDATION. Waiting for $CHECK_INTERVAL_CERT seconds before retrying..."
                ((attempts++))
                sleep "$CHECK_INTERVAL_CERT"
            else
                echo_error "Certificate status is '$STATUS'. Exiting."
                exit 1
            fi
        done

        echo_error "Reached maximum number of checks ($CHECK_COUNT_CERT). Certificate was not issued within the expected time."
        exit 1
    }

    # Main Execution Flow within setup_with_domain_and_ssl
    # Check if terraform exists and retrieve the region, fallback to AWS CLI if terraform is not available
    if [ "$INFRA_TOOL" == "terraform" ]; then
        echo_info "Retrieving AWS region from Terraform outputs..."
        REGION=$("$INFRA_TOOL" output -raw aws_region)
    else
        echo_info "Retrieving AWS region from OpenTofu outputs..."
        REGION=$("$INFRA_TOOL" output -raw aws_region)
    fi

    # Fallback to AWS CLI configuration if REGION is empty
    if [[ -z "$REGION" ]]; then
        echo_info "Retrieving AWS region from AWS CLI configuration..."
        REGION=$(aws configure get region)
    fi

    # Verify the extracted region
    if [[ -z "$REGION" ]]; then
        echo_error "AWS region is not set in your Terraform/OpenTofu outputs or AWS CLI configuration."
        echo "Please configure it using 'terraform apply' or 'tofu apply', or set the AWS_REGION environment variable."
        exit 1
    fi

    echo_info "Using AWS Region: $REGION"

    # Check if ACM Certificate exists and its status
    get_certificate_arn

    if [[ -n "$CERTIFICATE_ARN" ]]; then
        STATUS=$(check_certificate_status "$CERTIFICATE_ARN")
        echo_info "Certificate Status: $STATUS"
        if [[ "$STATUS" == "ISSUED" ]]; then
            echo_info "Existing ACM certificate is ISSUED. Proceeding to create/update Ingress."
        elif [[ "$STATUS" == "PENDING_VALIDATION" ]]; then
            echo_info "Existing ACM certificate is PENDING_VALIDATION."
            get_validation_records "$CERTIFICATE_ARN"
            prompt_cname_validation_creation
            echo_info "Waiting for ACM certificate to be issued..."
            wait_for_certificate_issuance "$CERTIFICATE_ARN"
        else
            echo_error "Certificate status is '$STATUS'. Exiting."
            exit 1
        fi
    else
        # Create ACM Certificate
        request_certificate
        get_certificate_arn

        if [[ -z "$CERTIFICATE_ARN" ]]; then
            echo_error "Failed to retrieve Certificate ARN after requesting."
            exit 1
        fi

        STATUS=$(check_certificate_status "$CERTIFICATE_ARN")
        echo_info "Certificate Status: $STATUS"

        if [[ "$STATUS" == "PENDING_VALIDATION" ]]; then
            get_validation_records "$CERTIFICATE_ARN"
            prompt_cname_validation_creation
            echo_info "Waiting for ACM certificate to be issued..."
            wait_for_certificate_issuance "$CERTIFICATE_ARN"
        elif [[ "$STATUS" == "ISSUED" ]]; then
            echo_info "Certificate is already ISSUED."
        else
            echo_error "Certificate status is '$STATUS'. Exiting."
            exit 1
        fi
    fi

    # Create or Update Ingress with SSL
    echo_info "Configuring Helm with hostname and SSL. This step may take 3-5 minutes..."
    create_ingress

    # Retrieve Load Balancer DNS with polling
    get_load_balancer_dns

    # Prompt user to create CNAME record for domain mapping
    prompt_cname_domain_creation
}

# Function to set up OpenGovernance with Domain but Without SSL
setup_with_domain_no_ssl() {
    # Ensure required commands are installed
    check_command "jq"
    check_command "aws"
    check_command "kubectl"
    check_command "helm"

    # Prompt for domain name
    read -rp "Enter the domain name (e.g., demo.opengovernance.io): " DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        echo_error "Domain name cannot be empty."
        exit 1
    fi

    # Time between status checks (in seconds)
    CHECK_INTERVAL_LB=20        # For Load Balancer DNS
    CHECK_COUNT_LB=6            # Maximum number of Load Balancer DNS checks (~120 seconds)

    # Function to create Ingress without SSL
    create_ingress_no_ssl() {
        echo_info "Creating or updating Kubernetes Ingress: $INGRESS_NAME in namespace: $NAMESPACE"

        helm_quiet upgrade --install "$HELM_RELEASE" "$HELM_CHART" -n "$NAMESPACE" --create-namespace -f - <<EOF
global:
  domain: ${DOMAIN}
dex:
  config:
    issuer: http://${DOMAIN}/dex
EOF

        echo_info "Ingress $INGRESS_NAME has been created/updated."
    }

    # Function to retrieve Load Balancer DNS Name with polling
    get_load_balancer_dns_no_ssl() {
        echo_info "Retrieving Load Balancer DNS name..."
        local attempt=1
        while [[ $attempt -le $CHECK_COUNT_LB ]]; do
            LB_DNS=$(kubectl get ingress "$INGRESS_NAME" -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)

            if [[ -n "$LB_DNS" ]]; then
                echo_info "Load Balancer DNS: $LB_DNS"
                return 0
            else
                echo_info "Attempt $attempt/$CHECK_COUNT_LB: Load Balancer DNS not available yet. Waiting for $CHECK_INTERVAL_LB seconds..."
                ((attempt++))
                sleep "$CHECK_INTERVAL_LB"
            fi
        done

        echo_error "Failed to retrieve Load Balancer DNS after $CHECK_COUNT_LB attempts."
        echo "Please check your Kubernetes Ingress resource manually."
        echo ""
        return 1
    }

    # Function to prompt user to create CNAME records for domain mapping
    prompt_cname_domain_creation_no_ssl() {
        echo ""
        echo "==============================="
        echo "CNAME Record Creation Required"
        echo "==============================="
        echo "Please create the following CNAME record in your DNS provider to map your domain to the Load Balancer:"
        echo ""
        echo "Host/Name: $DOMAIN"
        echo "Type: CNAME"
        echo "Value/Points to: $LB_DNS"
        echo "TTL: 300 (or default)"
        echo ""
        echo "After creating the CNAME record, your service should be accessible at http://$DOMAIN"
        echo ""
    }

    # Main Execution Flow within setup_with_domain_no_ssl
    # Check if terraform exists and retrieve the region, fallback to AWS CLI if terraform is not available
    if [ "$INFRA_TOOL" == "terraform" ]; then
        echo_info "Retrieving AWS region from Terraform outputs..."
        REGION=$("$INFRA_TOOL" output -raw aws_region)
    else
        echo_info "Retrieving AWS region from OpenTofu outputs..."
        REGION=$("$INFRA_TOOL" output -raw aws_region)
    fi

    # Fallback to AWS CLI configuration if REGION is empty
    if [[ -z "$REGION" ]]; then
        echo_info "Retrieving AWS region from AWS CLI configuration..."
        REGION=$(aws configure get region)
    fi

    # Verify the extracted region
    if [[ -z "$REGION" ]]; then
        echo_error "AWS region is not set in your Terraform/OpenTofu outputs or AWS CLI configuration."
        echo "Please configure it using 'terraform apply' or 'tofu apply', or set the AWS_REGION environment variable."
        exit 1
    fi

    echo_info "Using AWS Region: $REGION"

    # Create or Update Ingress without SSL
    echo_info "Configuring Helm with hostname without SSL. This step may take 3-5 minutes..."
    create_ingress_no_ssl

    # Retrieve Load Balancer DNS with polling
    get_load_balancer_dns_no_ssl

    # Prompt user to create CNAME record for domain mapping
    prompt_cname_domain_creation_no_ssl
}

# Function to restart Kubernetes pods
restart_pods() {
    echo_info "Restarting OpenGovernance Pods to Apply Changes."

    # Restart only the specified deployments
    kubectl rollout restart deployment nginx-proxy -n "$NAMESPACE"
    kubectl rollout restart deployment opengovernance-dex -n "$NAMESPACE"

    echo_info "Pods restarted successfully."
}

# -----------------------------
# Main Execution Flow
# -----------------------------

echo "======================================="
echo "Starting OpenGovernance Deployment Script"
echo "======================================="

# Parse command-line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --debug)
            DEBUG_MODE=true
            shift
            ;;
        --skip-infra-setup)
            SKIP_INFRA_SETUP=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo_error "Unknown parameter passed: $1"
            usage
            ;;
    esac
done

# Step 1: Check if required commands are installed and prerequisites are met
echo_info "Checking for required tools and prerequisites..."
check_command "git"
check_terraform_or_opentofu
check_command "kubectl"
check_command "aws"
check_command "jq"
check_command "helm"
check_prerequisites

# Check AWS CLI authentication
check_aws_auth

if [ "$SKIP_INFRA_SETUP" = true ]; then
    echo_info "Skipping infrastructure setup as per --skip-infra-setup flag."
    # Step 2: Confirm provider is AWS
    if confirm_provider_is_aws && check_ready_nodes; then
        echo_info "Cluster is on AWS and has sufficient ready nodes. Skipping infrastructure setup."
    else
        echo_error "Prerequisites for skipping infrastructure setup are not met."
        exit 1
    fi
else
    # Step 2: Clone repository and deploy infrastructure
    clone_repository
    deploy_infrastructure
fi

# Step 3: Run Helm install without any configuration
echo_info "Installing Helm chart. This step may take 5-7 minutes..."
HELM_RELEASE="opengovernance"
HELM_CHART="https://charts.opengovernance.com/opengovernance-latest.tgz"
NAMESPACE="opengovernance"
INGRESS_NAME="opengovernance-ingress"

helm_quiet install "$HELM_RELEASE" "$HELM_CHART" -n "$NAMESPACE" --create-namespace

echo_info "Helm install completed."

# Step 4: Check pods and migrator jobs
echo_info "Checking OpenGovernance pod and migrator job readiness..."
check_pods_and_jobs

# Step 5: Prompt user for OpenGovernance setup options
prompt_user_options
configure_opengovernance

# Step 6: Restart relevant Kubernetes pods to apply changes
if [[ "${SETUP_DOMAIN_AND_SSL:-0}" -eq 1 || "${SETUP_DOMAIN_NO_SSL:-0}" -eq 1 ]]; then
    restart_pods
fi

echo ""
echo "======================================="
echo "Deployment Script Completed Successfully!"
echo "======================================="
if [[ "${SETUP_DOMAIN_AND_SSL:-0}" -eq 1 ]]; then
    echo "Your service should now be fully operational at https://$DOMAIN"
elif [[ "${SETUP_DOMAIN_NO_SSL:-0}" -eq 1 ]]; then
    echo "Your service should now be fully operational at http://$DOMAIN"
fi
echo "======================================="

exit 0