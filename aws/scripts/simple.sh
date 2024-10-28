#!/bin/bash

set -euo pipefail

# -----------------------------
# Configuration Variables
# -----------------------------

# Repository URL
REPO_URL="https://github.com/opengovern/deploy-opengovernance.git"

# Directory where the repository will be cloned
REPO_DIR="deploy-opengovernance"

# Path to Terraform/OpenTofu configuration
INFRA_DIR="$REPO_DIR/aws/eks"

# Helm release name and chart repository
HELM_RELEASE="opengovernance"
HELM_CHART="opengovernance/opengovernance"

# Kubernetes namespace and Ingress name
NAMESPACE="opengovernance"
INGRESS_NAME="opengovernance-ingress"

# -----------------------------
# Function Definitions
# -----------------------------

# Function to print error messages
echo_error() {
    echo -e "\e[31mERROR:\e[0m $1" >&2
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
        echo "Terraform is installed."
    elif command -v tofu &> /dev/null; then
        INFRA_TOOL="tofu"
        echo "OpenTofu is installed."
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
    echo "AWS CLI is authenticated."
}

# Function to clone the repository
clone_repository() {
    if [ -d "$REPO_DIR" ]; then
        echo "Repository '$REPO_DIR' already exists. Pulling the latest changes..."
        git -C "$REPO_DIR" pull
    else
        echo "Cloning repository from $REPO_URL..."
        git clone "$REPO_URL"
    fi
}

# Function to deploy infrastructure using Terraform or OpenTofu
deploy_infrastructure() {
    echo "Navigating to infrastructure directory: $INFRA_DIR"
    cd "$INFRA_DIR"

    if [ "$INFRA_TOOL" == "terraform" ]; then
        echo "Initializing Terraform..."
        terraform init

        echo "Planning Terraform deployment..."
        terraform plan

        echo "Applying Terraform deployment..."
        terraform apply --auto-approve
    elif [ "$INFRA_TOOL" == "tofu" ]; then
        echo "Initializing OpenTofu..."
        tofu init

        echo "Planning OpenTofu deployment..."
        tofu plan

        echo "Applying OpenTofu deployment..."
        tofu apply -auto-approve
    fi

    echo "Connecting to the Kubernetes cluster..."
    eval "$("$INFRA_TOOL" output -raw configure_kubectl)"
}

# Function to provide port-forwarding instructions
provide_port_forward_instructions() {
    echo_error "OpenGovernance is running but not accessible via Ingress."
    echo "You can access it using port-forwarding as follows:"
    echo "kubectl port-forward -n $NAMESPACE service/nginx-proxy 8080:80"
    echo "Then, access it at http://localhost:8080"
    echo ""
    echo "To sign in, use the following default credentials:"
    echo "  Username: admin@opengovernance.io"
    echo "  Password: password"
}

# Function to prompt the user for OpenGovernance setup options
prompt_user_options() {
    echo ""
    echo "========================================="
    echo "OpenGovernance Setup Configuration Options"
    echo "========================================="
    echo "Please choose the setup configuration:"
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

# Function to configure OpenGovernance based on user input
configure_opengovernance() {
    if [ "${SETUP_DOMAIN_AND_SSL:-0}" -eq 1 ]; then
        echo "Setting up OpenGovernance with Domain and SSL..."
        setup_with_domain_and_ssl
    elif [ "${SETUP_DOMAIN_NO_SSL:-0}" -eq 1 ]; then
        echo "Setting up OpenGovernance with Domain but Without SSL..."
        setup_with_domain_no_ssl
    elif [ "${CONNECT_AS_IS:-0}" -eq 1 ]; then
        echo "Providing port-forwarding instructions to access OpenGovernance..."
        provide_port_forward_instructions
    else
        echo_error "No valid setup option selected. Exiting."
        exit 1
    fi
}

# -----------------------------
# Setup Functions
# -----------------------------

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
        echo "Requesting a new ACM certificate for domain: $DOMAIN"

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
        echo "Certificate ARN: $CERTIFICATE_ARN"
    }

    # Function to retrieve existing ACM certificate ARN
    get_certificate_arn() {
        echo "Searching for existing ACM certificates for domain: $DOMAIN"
        CERTIFICATE_ARN=$(aws acm list-certificates \
            --region "$REGION" \
            --query "CertificateSummaryList[?DomainName=='$DOMAIN'].CertificateArn" \
            --output text)

        if [[ -z "$CERTIFICATE_ARN" ]]; then
            echo "No existing ACM certificate found for domain: $DOMAIN"
            CERTIFICATE_ARN=""
        else
            echo "Found existing Certificate ARN: $CERTIFICATE_ARN"
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
        echo "Retrieving DNS validation records..."
        VALIDATION_RECORDS=$(aws acm describe-certificate \
            --certificate-arn "$arn" \
            --region "$REGION" \
            --query "Certificate.DomainValidationOptions[].ResourceRecord" \
            --output json)
    }

    # Function to create Ingress with SSL
    create_ingress() {
        echo "Creating or updating Kubernetes Ingress: $INGRESS_NAME in namespace: $NAMESPACE"

        kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
 namespace: $NAMESPACE
 name: $INGRESS_NAME
 annotations:
   alb.ingress.kubernetes.io/scheme: internet-facing
   alb.ingress.kubernetes.io/target-type: ip
   alb.ingress.kubernetes.io/backend-protocol: HTTP
   alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS":443}]'
   alb.ingress.kubernetes.io/certificate-arn: "$CERTIFICATE_ARN"
   kubernetes.io/ingress.class: alb
spec:
 ingressClassName: alb
 rules:
   - host: "$DOMAIN"
     http:
       paths:
         - path: /
           pathType: Prefix
           backend:
             service:
               name: nginx-proxy  # Replace with your actual service name if different
               port:
                 number: 80
EOF

        echo "Ingress $INGRESS_NAME has been created/updated."
    }

    # Function to retrieve Load Balancer DNS Name with polling
    get_load_balancer_dns() {
        echo "Retrieving Load Balancer DNS name..."
        local attempt=1
        while [[ $attempt -le $CHECK_COUNT_LB ]]; do
            LB_DNS=$(kubectl get ingress "$INGRESS_NAME" -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)

            if [[ -n "$LB_DNS" ]]; then
                echo "Load Balancer DNS: $LB_DNS"
                return 0
            else
                echo "Attempt $attempt/$CHECK_COUNT_LB: Load Balancer DNS not available yet. Waiting for $CHECK_INTERVAL_LB seconds..."
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

        echo "Starting to monitor the certificate status. This may take some time..."

        while [[ $attempts -lt $CHECK_COUNT_CERT ]]; do
            STATUS=$(check_certificate_status "$arn")
            echo "Certificate Status: $STATUS"

            if [[ "$STATUS" == "ISSUED" ]]; then
                echo "Certificate is now ISSUED."
                return 0
            elif [[ "$STATUS" == "PENDING_VALIDATION" ]]; then
                echo "Certificate is still PENDING_VALIDATION. Waiting for $CHECK_INTERVAL_CERT seconds before retrying..."
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
        echo "Retrieving AWS region from Terraform outputs..."
        REGION=$("$INFRA_TOOL" output -raw aws_region)
    else
        echo "Retrieving AWS region from OpenTofu outputs..."
        REGION=$("$INFRA_TOOL" output -raw aws_region)
    fi

    # Fallback to AWS CLI configuration if REGION is empty
    if [[ -z "$REGION" ]]; then
        echo "Retrieving AWS region from AWS CLI configuration..."
        REGION=$(aws configure get region)
    fi

    # Verify the extracted region
    if [[ -z "$REGION" ]]; then
        echo_error "AWS region is not set in your Terraform/OpenTofu outputs or AWS CLI configuration."
        echo "Please configure it using 'terraform apply' or 'tofu apply', or set the AWS_REGION environment variable."
        exit 1
    fi

    echo "Using AWS Region: $REGION"

    # Check if ACM Certificate exists and its status
    get_certificate_arn

    if [[ -n "$CERTIFICATE_ARN" ]]; then
        STATUS=$(check_certificate_status "$CERTIFICATE_ARN")
        echo "Certificate Status: $STATUS"
        if [[ "$STATUS" == "ISSUED" ]]; then
            echo "Existing ACM certificate is ISSUED. Proceeding to create/update Ingress."
        elif [[ "$STATUS" == "PENDING_VALIDATION" ]]; then
            echo "Existing ACM certificate is PENDING_VALIDATION."
            get_validation_records "$CERTIFICATE_ARN"
            prompt_cname_validation_creation
            echo "Waiting for ACM certificate to be issued..."
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
        echo "Certificate Status: $STATUS"

        if [[ "$STATUS" == "PENDING_VALIDATION" ]]; then
            get_validation_records "$CERTIFICATE_ARN"
            prompt_cname_validation_creation
            echo "Waiting for ACM certificate to be issued..."
            wait_for_certificate_issuance "$CERTIFICATE_ARN"
        elif [[ "$STATUS" == "ISSUED" ]]; then
            echo "Certificate is already ISSUED."
        else
            echo_error "Certificate status is '$STATUS'. Exiting."
            exit 1
        fi
    fi

    # Create or Update Ingress with SSL
    create_ingress

    # Retrieve Load Balancer DNS with polling
    get_load_balancer_dns

    # Prompt user to create CNAME record for domain mapping
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
        echo "Creating or updating Kubernetes Ingress: $INGRESS_NAME in namespace: $NAMESPACE"

        kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
 namespace: $NAMESPACE
 name: $INGRESS_NAME
 annotations:
   alb.ingress.kubernetes.io/scheme: internet-facing
   alb.ingress.kubernetes.io/target-type: ip
   alb.ingress.kubernetes.io/backend-protocol: HTTP
   alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'
   kubernetes.io/ingress.class: alb
spec:
 ingressClassName: alb
 rules:
   - host: "$DOMAIN"
     http:
       paths:
         - path: /
           pathType: Prefix
           backend:
             service:
               name: nginx-proxy  # Replace with your actual service name if different
               port:
                 number: 80
EOF

        echo "Ingress $INGRESS_NAME has been created/updated."
    }

    # Function to retrieve Load Balancer DNS Name with polling
    get_load_balancer_dns_no_ssl() {
        echo "Retrieving Load Balancer DNS name..."
        local attempt=1
        while [[ $attempt -le $CHECK_COUNT_LB ]]; do
            LB_DNS=$(kubectl get ingress "$INGRESS_NAME" -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)

            if [[ -n "$LB_DNS" ]]; then
                echo "Load Balancer DNS: $LB_DNS"
                return 0
            else
                echo "Attempt $attempt/$CHECK_COUNT_LB: Load Balancer DNS not available yet. Waiting for $CHECK_INTERVAL_LB seconds..."
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
        echo "Retrieving AWS region from Terraform outputs..."
        REGION=$("$INFRA_TOOL" output -raw aws_region)
    else
        echo "Retrieving AWS region from OpenTofu outputs..."
        REGION=$("$INFRA_TOOL" output -raw aws_region)
    fi

    # Fallback to AWS CLI configuration if REGION is empty
    if [[ -z "$REGION" ]]; then
        echo "Retrieving AWS region from AWS CLI configuration..."
        REGION=$(aws configure get region)
    fi

    # Verify the extracted region
    if [[ -z "$REGION" ]]; then
        echo_error "AWS region is not set in your Terraform/OpenTofu outputs or AWS CLI configuration."
        echo "Please configure it using 'terraform apply' or 'tofu apply', or set the AWS_REGION environment variable."
        exit 1
    fi

    echo "Using AWS Region: $REGION"

    # Create or Update Ingress without SSL
    create_ingress_no_ssl

    # Retrieve Load Balancer DNS with polling
    get_load_balancer_dns_no_ssl

    # Prompt user to create CNAME record for domain mapping
    prompt_cname_domain_creation_no_ssl
}

# -----------------------------
# Update Application Functions
# -----------------------------

# Function to retrieve DOMAIN, CERTIFICATE_ARN, LB_DNS, and LISTEN_PORTS from Ingress
get_ingress_details() {
    echo "Retrieving Ingress details from Kubernetes..."

    # Get DOMAIN from the Ingress rules
    DOMAIN=$(kubectl get ingress "$INGRESS_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.rules[0].host}')

    if [[ -z "$DOMAIN" ]]; then
        echo_error "Unable to retrieve DOMAIN from Ingress rules."
        exit 1
    fi
    echo "DOMAIN: $DOMAIN"

    # Get CERTIFICATE_ARN from Ingress annotations
    CERTIFICATE_ARN=$(kubectl get ingress "$INGRESS_NAME" -n "$NAMESPACE" -o jsonpath='{.metadata.annotations.alb\.ingress\.kubernetes\.io/certificate-arn}')

    if [[ -z "$CERTIFICATE_ARN" ]]; then
        echo_error "Unable to retrieve CERTIFICATE_ARN from Ingress annotations."
        exit 1
    fi
    echo "CERTIFICATE_ARN: $CERTIFICATE_ARN"

    # Get Load Balancer DNS from Ingress status
    LB_DNS=$(kubectl get ingress "$INGRESS_NAME" -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

    if [[ -z "$LB_DNS" ]]; then
        echo_error "Load Balancer DNS not available yet. Ensure Ingress is properly deployed."
        exit 1
    fi
    echo "Load Balancer DNS: $LB_DNS"

    # Get Listen Ports from Ingress annotations
    LISTEN_PORTS=$(kubectl get ingress "$INGRESS_NAME" -n "$NAMESPACE" -o jsonpath='{.metadata.annotations.alb\.ingress\.kubernetes\.io/listen-ports}')

    if [[ -z "$LISTEN_PORTS" ]]; then
        echo_error "Unable to retrieve LISTEN_PORTS from Ingress annotations."
        exit 1
    fi
    echo "Listen Ports: $LISTEN_PORTS"
}

# Function to determine the protocol (http or https) based on listen-ports
determine_protocol() {
    echo "Determining protocol based on Ingress listen ports..."

    # Check if HTTPS is present in the listen ports
    if echo "$LISTEN_PORTS" | grep -q '"HTTPS"'; then
        PROTOCOL="https"
    else
        PROTOCOL="http"
    fi

    echo "Determined Protocol: $PROTOCOL"
}

# Function to check DNS resolution without dig
check_dns_resolution() {
    echo "Checking if $DOMAIN is resolving correctly..."

    # Use nslookup if available, otherwise use host, otherwise use getent
    if command -v nslookup &> /dev/null; then
        RESOLVED=$(nslookup "$DOMAIN" | awk '/name = / {print $NF}' | sed 's/\.$//')
    elif command -v host &> /dev/null; then
        RESOLVED=$(host "$DOMAIN" | awk '/alias for / {print $NF}' | sed 's/\.$//')
    elif command -v getent &> /dev/null; then
        RESOLVED=$(getent hosts "$DOMAIN" | awk '{print $1}')
    else
        echo_error "No suitable DNS resolution command found (nslookup, host, getent). Please install one."
        return 1
    fi

    if [[ -z "$RESOLVED" ]]; then
        echo_error "$DOMAIN is not resolving correctly."
        return 1
    fi

    echo "$DOMAIN is resolving to: $RESOLVED"
    echo "Ensure that $DOMAIN is correctly pointing to your Load Balancer or proxy service (e.g., Cloudflare)."

    return 0
}

# Function to check DNS resolution with retries and option to skip
check_dns_resolution_with_retries() {
    local max_attempts=12
    local interval=30
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        echo "Attempt $attempt/$max_attempts: Checking DNS resolution for $DOMAIN..."
        if check_dns_resolution; then
            echo "DNS resolution successful."
            return 0
        else
            echo "DNS resolution failed."
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            echo "Waiting for $interval seconds before retrying..."
            sleep "$interval"
        fi

        ((attempt++))
    done

    echo_error "DNS resolution for $DOMAIN failed after $max_attempts attempts."

    # Prompt user to skip or exit
    while true; do
        read -rp "Do you want to skip DNS resolution check and proceed? (y/N): " choice
        case "$choice" in
            y|Y )
                echo "Skipping DNS resolution check."
                return 0
                ;;
            n|N|"" )
                echo "Exiting script due to DNS resolution failure."
                exit 1
                ;;
            * )
                echo "Invalid input. Please enter 'y' or 'n'."
                ;;
        esac
    done
}

# Function to update Helm release
update_helm_release() {
    echo "Updating Helm release: $HELM_RELEASE with domain: $DOMAIN and protocol: $PROTOCOL"

    helm upgrade "$HELM_RELEASE" "$HELM_CHART" -n "$NAMESPACE" -f <(cat <<EOF
global:
 domain: ${DOMAIN}
dex:
 config:
   issuer: ${PROTOCOL}://${DOMAIN}/dex
EOF
)
    echo "Helm release $HELM_RELEASE has been updated."
}

# Function to restart Kubernetes pods
restart_pods() {
    echo "Restarting relevant Kubernetes pods to apply changes..."

    # Restart nginx-proxy pods
    kubectl delete pods -l app=nginx-proxy -n "$NAMESPACE"

    # Restart dex pods
    kubectl delete pods -l app.kubernetes.io/name=dex -n "$NAMESPACE"

    echo "Pods are restarting..."
}

# -----------------------------
# Main Execution Flow
# -----------------------------

echo "======================================="
echo "Starting OpenGovernance Deployment Script"
echo "======================================="

# Step 1: Check if required commands are installed
echo "Checking for required tools..."
check_command "git"
check_terraform_or_opentofu
check_command "kubectl"
check_command "aws"
check_command "jq"
check_command "helm"

# Step 2: Check AWS CLI authentication
check_aws_auth

# Step 3: Clone repository and deploy infrastructure
clone_repository
deploy_infrastructure

# Step 4: Run Helm install without any configuration
echo "Running Helm install without any configuration..."
helm install "$HELM_RELEASE" "$HELM_CHART" -n "$NAMESPACE" --create-namespace

echo "Helm install completed."

# Step 5: Prompt user for OpenGovernance setup options
prompt_user_options
configure_opengovernance

# If the user chose to configure with hostname, proceed with application update
if [[ "${SETUP_DOMAIN_AND_SSL:-0}" -eq 1 || "${SETUP_DOMAIN_NO_SSL:-0}" -eq 1 ]]; then
    echo "======================================="
    echo "Starting Application Update Process"
    echo "======================================="

    # Retrieve Ingress details
    get_ingress_details

    # Determine protocol based on Ingress listen ports
    determine_protocol

    # Check DNS resolution if not skipped
    check_dns_resolution_with_retries

    # Update Helm release with new configurations
    update_helm_release

    # Restart relevant Kubernetes pods to apply changes
    restart_pods

    echo ""
    echo "======================================="
    echo "Application Update Completed Successfully!"
    echo "======================================="
    echo "Your service should now be fully operational at ${PROTOCOL}://${DOMAIN}"
    echo "======================================="
fi

# If the user chose to connect as is, instructions have already been provided
echo "Deployment script completed."
