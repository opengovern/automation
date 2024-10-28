
#!/bin/bash

# -----------------------------
# Configuration Variables
# -----------------------------

# Kubernetes namespace for OpenGovernance
KUBE_NAMESPACE="opengovernance"

# Kubernetes cluster name for OpenGovernance
KUBE_CLUSTER_NAME="opengovernance"

# Kubernetes cluster region for OpenGovernance
KUBE_REGION="nyc3"

# -----------------------------
# Logging Configuration
# -----------------------------
LOGFILE="$HOME/opengovernance_install.log"

# Ensure the log directory exists
mkdir -p "$(dirname "$LOGFILE")"

# Redirect all output to the log file only
exec > >(tee -a "$LOGFILE") 2>&1

# Open file descriptor 3 for appending to the log file only
exec 3>> "$LOGFILE"

# -----------------------------
# Function Definitions
# -----------------------------

# Function to display informational messages to the log
function echo_info() {
  local message="$1"
  # Log detailed message
  echo "$message" >&3
}

# Function to display error messages to console and log
function echo_error() {
  local message="$1"
  # Always print concise error message to console
  printf "Error: %s\n" "$message"
  # Log detailed error message
  echo "Error: $message" >&3
}

# Function to display usage information
function usage() {
  echo "Usage: $0 [--silent-install] [-d DOMAIN] [-e EMAIL] [-t INSTALL_TYPE] [--kube-namespace NAMESPACE] [--kube-cluster-name CLUSTER_NAME] [--kube-region REGION] [-h|--help]"
  echo ""
  echo "Options:"
  echo "  --silent-install        Run the script in non-interactive mode. DOMAIN and EMAIL must be provided as arguments."
  echo "  -d, --domain            Specify the domain for OpenGovernance."
  echo "  -e, --email             Specify the email for Let's Encrypt certificate generation."
  echo "  -t, --type              Specify the installation type:"
  echo "                           1) Install with HTTPS and Hostname (DNS records required after installation)"
  echo "                           2) Install without HTTPS (DNS records required after installation)"
  echo "                           3) Minimal Install (Access via public IP)"
  echo "                           4) Basic Install (No Ingress, use port-forwarding)"
  echo "                           Default: 1"
  echo "  --kube-namespace        Specify the Kubernetes namespace. Default: $KUBE_NAMESPACE"
  echo "  --kube-cluster-name     Specify the Kubernetes cluster name. Default: $KUBE_CLUSTER_NAME"
  echo "  --kube-region           Specify the Kubernetes cluster region. Default: $KUBE_REGION"
  echo "  -h, --help              Display this help message."
  exit 1
}

# Function to redirect Helm commands to the log only
function helm_quiet() {
  helm "$@" >&3 2>&1
}

# Function to validate the domain
function validate_domain() {
  local domain="$DOMAIN"
  # Simple regex for domain validation
  if [[ "$domain" =~ ^(([a-zA-Z0-9](-*[a-zA-Z0-9])*)\.)+[a-zA-Z]{2,}$ ]]; then
      echo_info "Domain '$domain' is valid."
  else
      echo_error "Invalid domain: '$domain'. Please enter a valid domain."
      exit 1
  fi
}

# Function to validate the email
function validate_email() {
  local email="$EMAIL"
  # Simple regex for email validation
  if [[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
      echo_info "Email '$email' is valid."
  else
      echo_error "Invalid email: '$email'. Please enter a valid email address."
      exit 1
  fi
}

# Function to parse command-line arguments
function parse_args() {
  SILENT_INSTALL=false
  while [[ "$#" -gt 0 ]]; do
    case $1 in
      --silent-install)
        SILENT_INSTALL=true
        shift
        ;;
      -d|--domain)
        DOMAIN="$2"
        shift 2
        ;;
      -e|--email)
        EMAIL="$2"
        shift 2
        ;;
      -t|--type)
        INSTALL_TYPE="$2"
        shift 2
        ;;
      --kube-namespace)
        KUBE_NAMESPACE="$2"
        shift 2
        ;;
      --kube-cluster-name)
        KUBE_CLUSTER_NAME="$2"
        shift 2
        ;;
      --kube-region)
        KUBE_REGION="$2"
        shift 2
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

  # Set default installation type if not provided
  INSTALL_TYPE=${INSTALL_TYPE:-1}

  # Validate INSTALL_TYPE
  if ! [[ "$INSTALL_TYPE" =~ ^[1-4]$ ]]; then
    echo_error "Invalid installation type: $INSTALL_TYPE"
    usage
  fi

  # Validate DOMAIN and EMAIL based on INSTALL_TYPE and SILENT_INSTALL
  case $INSTALL_TYPE in
    1)
      # Install with HTTPS and Hostname
      if [ "$SILENT_INSTALL" = true ]; then
        if [ -z "$DOMAIN" ]; then
          echo_error "Installation type 1 requires a DOMAIN in silent mode."
          usage
        else
          validate_domain
        fi

        if [ -z "$EMAIL" ]; then
          echo_error "Installation type 1 requires an EMAIL in silent mode."
          usage
        else
          validate_email
        fi
      fi
      ENABLE_HTTPS=true
      ;;
    2)
      # Install without HTTPS
      if [ "$SILENT_INSTALL" = true ]; then
        if [ -z "$DOMAIN" ]; then
          echo_error "Installation type 2 requires a DOMAIN in silent mode."
          usage
        else
          validate_domain
        fi
      fi
      ENABLE_HTTPS=false
      ;;
    3)
      # Minimal Install
      ENABLE_HTTPS=false
      ;;
    4)
      # Basic Install with no Ingress
      ENABLE_HTTPS=false
      ;;
    *)
      echo_error "Unsupported installation type: $INSTALL_TYPE"
      usage
      ;;
  esac
}

# Function to choose installation type in interactive mode
function choose_install_type() {
  echo ""
  echo "Select Installation Type:"
  echo "1) Install with HTTPS and Hostname (DNS records required after installation)"
  echo "2) Install without HTTPS (DNS records required after installation)"
  echo "3) Minimal Install (Access via public IP)"
  echo "4) Basic Install (No Ingress, use port-forwarding)"
  echo "5) Exit"

  # Prompt the user, with default 1 after timeout or pressing Enter
  read -t 10 -p "Enter the number corresponding to your choice [Default: 1]: " choice < /dev/tty || choice=1

  # If no choice is made, default to 1
  choice=${choice:-1}

  # Ensure the choice is within 1-5
  if ! [[ "$choice" =~ ^[1-5]$ ]]; then
    echo "Invalid option. Defaulting to 1) Install with HTTPS and Hostname."
    choice=1
  fi

  echo ""
  echo "You selected: $choice) $(get_install_type_description $choice)"

  # Set INSTALL_TYPE and possibly set ENABLE_HTTPS based on choice
  case $choice in
    1)
      INSTALL_TYPE=1
      ENABLE_HTTPS=true
      ;;
    2)
      INSTALL_TYPE=2
      ENABLE_HTTPS=false
      ;;
    3)
      INSTALL_TYPE=3
      ENABLE_HTTPS=false
      ;;
    4)
      INSTALL_TYPE=4
      ENABLE_HTTPS=false
      ;;
    5)
      echo_info "Exiting the script."
      exit 0
      ;;
    *)
      INSTALL_TYPE=1
      ENABLE_HTTPS=true
      ;;
  esac

  # Inform user that installation will start shortly
  echo_info "Installation will start in 5 seconds..."
  sleep 5
}

# Function to get installation type description
function get_install_type_description() {
  local type="$1"
  case $type in
    1) echo "Install with HTTPS and Hostname (DNS records required after installation)" ;;
    2) echo "Install without HTTPS (DNS records required after installation)" ;;
    3) echo "Minimal Install (Access via public IP)" ;;
    4) echo "Basic Install (No Ingress, use port-forwarding)" ;;
    5) echo "Exit" ;;
    *) echo "Unknown" ;;
  esac
}

# Function to check prerequisites and handle cluster creation if necessary
function check_prerequisites() {
  # Function to check if there are at least three ready nodes, retrying every 30 seconds for up to 5 minutes
  function check_ready_nodes() {
    local attempts=0
    local max_attempts=10  # 10 attempts * 30 seconds = 5 minutes
    local sleep_time=30

    while [ $attempts -lt $max_attempts ]; do
      READY_NODES=$(kubectl get nodes --no-headers | grep -c ' Ready ')
      if [ "$READY_NODES" -ge 3 ]; then
        echo_info "Required nodes are ready. ($READY_NODES nodes)"
        return 0
      fi

      attempts=$((attempts + 1))
      echo_info "Waiting for nodes to become ready... ($attempts/$max_attempts)"
      sleep $sleep_time
    done

    echo_error "At least three Kubernetes nodes must be ready, but only $READY_NODES node(s) are ready after 5 minutes."
    exit 1
  }

  # Function to prompt the user with a yes/no question
  function prompt_yes_no() {
    local prompt_message="$1"
    local user_input

    while true; do
      read -p "$prompt_message [y/n]: " user_input < /dev/tty
      case "$user_input" in
        [Yy]* ) return 0;;
        [Nn]* ) return 1;;
        * ) echo "Please answer yes (y) or no (n).";;
      esac
    done
  }

  # Function to prompt the user for a new cluster name
  function prompt_new_cluster_name() {
    local new_name
    while true; do
      read -p "Enter a new name for the Kubernetes cluster: " new_name < /dev/tty
      if [[ -n "$new_name" ]]; then
        echo "$new_name"
        return 0
      else
        echo_error "Cluster name cannot be empty. Please enter a valid name."
      fi
    done
  }

  # Function to handle existing cluster scenarios
  # Updated handle_existing_cluster() function to merge prompts into a single question

  function handle_existing_cluster() {
    echo_error "A Kubernetes cluster named '$KUBE_CLUSTER_NAME' already exists."

    echo ""
    echo "Please choose an option:"
    echo "1) Delete the existing cluster and recreate it"
    echo "2) Connect to the existing cluster"
    echo "3) Create a new Kubernetes cluster with a different name"
    echo "4) Exit"

    read -p "Enter the number corresponding to your choice: " choice < /dev/tty

    case "$choice" in
      1)
        echo_info "Deleting existing cluster '$KUBE_CLUSTER_NAME'..."
        doctl kubernetes cluster delete "$KUBE_CLUSTER_NAME" --force --wait
        echo_info "Existing cluster deleted."
        create_cluster "$KUBE_CLUSTER_NAME"
        ;;
      2)
        echo_info "Configuring kubectl to connect to the existing '$KUBE_CLUSTER_NAME' cluster..."
        doctl kubernetes cluster kubeconfig save "$KUBE_CLUSTER_NAME"
        echo_info "'kubectl' is now configured to connect to '$KUBE_CLUSTER_NAME'."
        ;;
      3)
        local new_cluster_name
        new_cluster_name=$(prompt_new_cluster_name)
        create_cluster "$new_cluster_name"
        ;;
      4)
        echo_info "Exiting the script."
        exit 0
        ;;
      *)
        echo_error "Invalid choice. Exiting."
        exit 1
        ;;
    esac
  }


  # Function to create a Kubernetes cluster with a given name
  function create_cluster() {
    local cluster_name="$1"

    echo_info "A DigitalOcean Kubernetes cluster named '$cluster_name' will be created in 10 seconds..."
    sleep 10

    echo_info "Creating DigitalOcean Kubernetes cluster '$cluster_name' in region '$KUBE_REGION'..."
    doctl kubernetes cluster create "$cluster_name" --region "$KUBE_REGION" \
      --node-pool "name=main-pool;size=g-4vcpu-16gb-intel;count=3" --wait

    # Wait for nodes to become ready
    check_ready_nodes
  }

  # Check if kubectl is connected to a cluster
  if kubectl cluster-info > /dev/null 2>&1; then
    echo_info "kubectl is connected to a cluster."
  else
    echo_error "kubectl is not connected to a cluster."

    # Check if doctl is installed
    if command -v doctl &> /dev/null; then
      echo_info "doctl is installed."

      # Check if doctl is configured
      if doctl account get > /dev/null 2>&1; then
        echo_info "doctl is configured."

        # Check if a cluster with the specified name already exists
        if doctl kubernetes cluster list --format Name --no-header | grep -qw "^$KUBE_CLUSTER_NAME$"; then
          # Handle existing cluster
          handle_existing_cluster
        else
          # Create the cluster since it doesn't exist
          create_cluster "$KUBE_CLUSTER_NAME"
        fi
      else
        echo_error "doctl is installed but not configured."
        echo ""
        echo "Please configure doctl or connect kubectl to your Kubernetes cluster by following these steps:"
        echo "1. Visit the OpenGovernance DigitalOcean Deployment Guide: https://docs.opengovernance.io/oss/getting-started/introduction/digitalocean-deployment-guide"
        echo "2. If you have already created a cluster, configure kubectl to connect by clicking 'Connect to Cluster' in the DigitalOcean portal or refer to:"
        echo "   https://docs.digitalocean.com/products/kubernetes/how-to/connect-to-cluster/"
        echo ""
        exit 1
      fi
    else
      echo_error "doctl is not installed."
      echo ""
      echo "Please install doctl or connect kubectl to an existing Kubernetes cluster by following these steps:"
      echo "1. Visit the OpenGovernance DigitalOcean Deployment Guide: https://docs.opengovernance.io/oss/getting-started/introduction/digitalocean-deployment-guide"
      echo "2. If you have already created a cluster, configure kubectl to connect by clicking 'Connect to Cluster' in the DigitalOcean portal or refer to:"
      echo "   https://docs.digitalocean.com/products/kubernetes/how-to/connect-to-cluster/"
      echo ""
      exit 1
    fi
  fi

  # At this point, kubectl is connected to a cluster
  # Check if Helm is installed
  if ! command -v helm &> /dev/null; then
    echo_error "Helm is not installed. Please install Helm and try again."
    exit 1
  fi

  # Check if there are at least three ready nodes
  check_ready_nodes

  echo_info "Checking Prerequisites...Completed"
}

# Function to clean up failed OpenGovernance installation
function cleanup_failed_install() {
  echo_error "OpenGovernance installation failed. Initiating cleanup..."
  echo_info "Cleaning up failed installation..."
  
  # Uninstall the Helm release quietly
  helm_quiet uninstall opengovernance -n "$KUBE_NAMESPACE" || echo_error "Failed to uninstall Helm release."
  
  # Delete the namespace
  kubectl delete namespace "$KUBE_NAMESPACE" || echo_error "Failed to delete namespace."
  
  echo_info "Cleanup of failed OpenGovernance installation completed."
}

# Function to check if OpenGovernance is installed
function check_opengovernance_installation() {
  # Check if OpenGovernance Helm repo is added and OpenGovernance is installed
  if helm repo list | grep -qw "opengovernance" && helm ls -n "$KUBE_NAMESPACE" | grep -qw opengovernance; then
    # Ensure jq is installed
    if ! command -v jq &> /dev/null; then
      echo_error "jq is not installed. Please install jq to enable JSON parsing."
      exit 1
    fi

    # Check Helm release status using jq
    local helm_release_status
    helm_release_status=$(helm list -n "$KUBE_NAMESPACE" --filter '^opengovernance$' -o json | jq -r '.[0].status // "unknown"')

    if [ "$helm_release_status" == "deployed" ]; then
      echo_info "Checking for any existing OpenGovernance Installation...Existing installation found."
      APP_INSTALLED=true
      return 0
    elif [ "$helm_release_status" == "failed" ]; then
      echo_error "OpenGovernance is installed but not in 'deployed' state (current status: $helm_release_status)."
      cleanup_failed_install
      APP_INSTALLED=false
      return 1
    else
      echo_error "OpenGovernance is in an unexpected state ('$helm_release_status'). Attempting cleanup..."
      cleanup_failed_install
      APP_INSTALLED=false
      return 1
    fi
  else
    echo_info "Checking for any existing OpenGovernance Installation...No existing Installations found."
    APP_INSTALLED=false
    return 1
  fi
}

# Function to check OpenGovernance health status
function check_opengovernance_health() {
  # Check the health of the OpenGovernance deployment
  local unhealthy_pods
  # Extract the STATUS column (3rd column) and exclude 'Running' and 'Completed'
  unhealthy_pods=$(kubectl get pods -n "$KUBE_NAMESPACE" --no-headers | awk '{print $3}' | grep -v -E 'Running|Completed' || true)

  if [ -z "$unhealthy_pods" ]; then
    APP_HEALTHY=true
  else
    echo_error "Some OpenGovernance pods are not healthy."
    kubectl get pods -n "$KUBE_NAMESPACE"
    APP_HEALTHY=false
  fi
}

# Function to check OpenGovernance configuration
function check_opengovernance_config() {
  # Retrieve the current Helm values
  CURRENT_HELM_VALUES=$(helm get values opengovernance -n "$KUBE_NAMESPACE" --output yaml 2>/dev/null || true)

  # Extract HELM_VALUES_DEX_ISSUER using awk
  HELM_VALUES_DEX_ISSUER=$(echo "$CURRENT_HELM_VALUES" | awk '
    /^\s*dex:/ { in_dex=1; next }
    /^\s*global:/ { in_dex=0 }
    in_dex && /^\s*config:/ { in_config=1; next }
    in_config && /^\s*issuer:/ {
      sub(/^\s*issuer:[[:space:]]*/, "")
      print
      exit
    }
  ')

  # Check if HELM_VALUES_DEX_ISSUER is not null and starts with "https://"
  if [[ -n "$HELM_VALUES_DEX_ISSUER" && "$HELM_VALUES_DEX_ISSUER" == https://* ]]; then
    dex_configuration_ok=true
  else
    dex_configuration_ok=false
  fi

  # Retrieve the app hostname by looking up the environment variables
  ENV_VARS=$(kubectl get deployment metadata-service -n "$KUBE_NAMESPACE" \
    -o jsonpath='{.spec.template.spec.containers[0].env[*]}')

  # Extract the primary domain from the environment variables
  CURRENT_DOMAIN=$(echo "$ENV_VARS" | grep -o '"name":"METADATA_PRIMARY_DOMAIN_URL","value":"[^"]*"' | awk -F'"' '{print $8}')

  # Determine if it's a custom hostname or not
  if [[ "$CURRENT_DOMAIN" == "og.app.domain" || -z "$CURRENT_DOMAIN" ]]; then
    custom_host_name=false
  elif [[ "$CURRENT_DOMAIN" =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]]; then
    custom_host_name=true
  fi

  # Retrieve redirect Uris
  redirect_uris=$(echo "$ENV_VARS" | grep -o '"name":"METADATA_DEX_PUBLIC_CLIENT_REDIRECT_URIS","value":"[^"]*"' | awk -F'"' '{print $8}')

  # Check if the primary domain is present in the redirect Uris
  if echo "$redirect_uris" | grep -q "$CURRENT_DOMAIN"; then
    dex_configuration_ok=true
  fi

  # Retrieve Ingress external IP
  INGRESS_EXTERNAL_IP=$(kubectl get svc ingress-nginx-controller -n "$KUBE_NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

  # Enhanced SSL configuration check based on the new criteria
  if [ "$APP_HEALTHY" = true ] && [ -n "$INGRESS_EXTERNAL_IP" ] && [[ "$HELM_VALUES_DEX_ISSUER" == https://* ]]; then
    ssl_configured=true
  else
    ssl_configured=false
  fi

  # Output concise results
  echo_info "Checking SSL/TLS Configuration...${ssl_configured:+Configured}${!ssl_configured:+Not Configured}"

  # Export variables for use in other functions
  export custom_host_name
  export ssl_configured
  export CURRENT_DOMAIN
  export HELM_VALUES_DEX_ISSUER
  export INGRESS_EXTERNAL_IP
}

# Function to check OpenGovernance readiness
function check_opengovernance_readiness() {
  # Check the readiness of all pods in the specified namespace
  local not_ready_pods
  # Extract the STATUS column (3rd column) and exclude 'Running' and 'Completed'
  not_ready_pods=$(kubectl get pods -n "$KUBE_NAMESPACE" --no-headers | awk '{print $3}' | grep -v -E 'Running|Completed' || true)

  if [ -z "$not_ready_pods" ]; then
    APP_HEALTHY=true
  else
    echo_error "Some OpenGovernance pods are not healthy."
    kubectl get pods -n "$KUBE_NAMESPACE"
    APP_HEALTHY=false
  fi
}

# Function to check pods and migrator jobs
function check_pods_and_jobs() {
  local attempts=0
  local max_attempts=12  # 12 attempts * 30 seconds = 6 minutes
  local sleep_time=30

  while [ $attempts -lt $max_attempts ]; do
    check_opengovernance_readiness
    if [ "$APP_HEALTHY" = true ]; then
      return 0
    fi
    attempts=$((attempts + 1))
    echo_info "Waiting for pods to become ready... ($attempts/$max_attempts)"
    sleep $sleep_time
  done

  echo_error "OpenGovernance did not become ready within expected time."
  exit 1
}

# Function to configure email and domain
function configure_email_and_domain() {
  # Depending on the installation type, prompt for DOMAIN and EMAIL as needed
  case $INSTALL_TYPE in
    1)
      # Install with HTTPS and Hostname
      if [ "$SILENT_INSTALL" = false ]; then
        if [ -z "$DOMAIN" ]; then
          while true; do
            read -p "Enter your domain for OpenGovernance: " DOMAIN < /dev/tty
            if [ -z "$DOMAIN" ]; then
              echo_error "Domain is required for installation type 1."
              continue
            fi
            validate_domain
            break
          done
        fi

        if [ -z "$EMAIL" ]; then
          while true; do
            read -p "Enter your email for Let's Encrypt: " EMAIL < /dev/tty
            if [ -z "$EMAIL" ]; then
              echo_error "Email is required for installation type 1."
            else
              validate_email
              break
            fi
          done
        fi
      fi
      ;;
    2)
      # Install without HTTPS
      if [ "$SILENT_INSTALL" = false ] && [ -z "$DOMAIN" ]; then
        while true; do
          read -p "Enter your domain for OpenGovernance: " DOMAIN < /dev/tty
          if [ -z "$DOMAIN" ]; then
            echo_error "Domain is required for installation type 2."
            continue
          fi
          validate_domain
          break
        done
      fi
      ;;
    3)
      # Minimal Install
      # No DOMAIN or EMAIL required
      ;;
    4)
      # Basic Install with no Ingress
      # No DOMAIN or EMAIL required
      ;;
    *)
      echo_error "Unsupported installation type: $INSTALL_TYPE"
      usage
      ;;
  esac
}

# Function to install or upgrade OpenGovernance with HTTPS
function install_opengovernance_with_https() {
  echo_info "Proceeding with OpenGovernance installation with HTTPS."

  # Add Helm repository and update
  echo_info "Adding OpenGovernance Helm repository."
  helm_quiet repo add opengovernance https://opengovern.github.io/charts || true
  helm_quiet repo update

  # Perform Helm installation with custom configuration
  echo_info "Performing installation with custom configuration."

  helm_quiet install opengovernance opengovernance/opengovernance -n "$KUBE_NAMESPACE" --create-namespace --timeout=10m --wait \
    -f - <<EOF
global:
  domain: ${DOMAIN}
dex:
  config:
    issuer: https://${DOMAIN}/dex
EOF

  echo_info "OpenGovernance installation with HTTPS completed."
}

# Function to install or upgrade OpenGovernance with hostname only
function install_opengovernance_with_hostname_only() {
  echo_info "Proceeding with OpenGovernance installation without HTTPS."

  # Add Helm repository and update
  echo_info "Adding OpenGovernance Helm repository."
  helm_quiet repo add opengovernance https://opengovern.github.io/charts || true
  helm_quiet repo update

  # Perform Helm installation with custom configuration
  echo_info "Performing installation with custom configuration."

  helm_quiet install opengovernance opengovernance/opengovernance -n "$KUBE_NAMESPACE" --create-namespace --timeout=10m --wait \
    -f - <<EOF
global:
  domain: ${DOMAIN}
dex:
  config:
    issuer: http://${DOMAIN}/dex
EOF

  echo_info "OpenGovernance installation without HTTPS completed."
}

# Function to install OpenGovernance with public IP (Minimal Install)
function install_opengovernance_with_public_ip() {
  echo_info "Proceeding with Minimal Install of OpenGovernance."

  # a. Install Ingress Controller and wait for external IP
  setup_ingress_controller

  # b. Perform Helm installation with external IP as domain and issuer
  echo_info "Performing installation with external IP as domain and issuer."

  helm_quiet repo add opengovernance https://opengovern.github.io/charts || true
  helm_quiet repo update

  helm_quiet install opengovernance opengovernance/opengovernance -n "$KUBE_NAMESPACE" --create-namespace --timeout=10m --wait \
    -f - <<EOF
global:
  domain: ${INGRESS_EXTERNAL_IP}
dex:
  config:
    issuer: http://${INGRESS_EXTERNAL_IP}/dex
EOF

  # c. Check if the application is running
  check_pods_and_jobs

  # d. Deploy Ingress resources without host and TLS
  deploy_ingress_resources

  # e. Re-check if the application is running
  check_pods_and_jobs

  # f. Restart Dex and NGINX services by restarting their pods
  restart_pods

  echo_info "Minimal Install of OpenGovernance completed."
}

# Function to install OpenGovernance without Ingress (Basic Install)
function install_opengovernance_no_ingress() {
  echo_info "Proceeding with Basic Install of OpenGovernance without Network Ingress."

  # Add Helm repository and update
  echo_info "Adding OpenGovernance Helm repository."
  helm_quiet repo add opengovernance https://opengovern.github.io/charts || true
  helm_quiet repo update

  # Perform Helm installation
  echo_info "Installing OpenGovernance via Helm without Ingress."

  helm_quiet install opengovernance opengovernance/opengovernance -n "$KUBE_NAMESPACE" --create-namespace --timeout=10m --wait

  # Check if the application is up
  check_pods_and_jobs

  # Set up port-forwarding
  echo_info "Setting up port-forwarding to access OpenGovernance locally."

  # Start port-forwarding in the background
  kubectl port-forward -n "$KUBE_NAMESPACE" service/nginx-proxy 8080:80 &
  PORT_FORWARD_PID=$!

  # Give port-forwarding some time to establish
  sleep 5

  # Check if port-forwarding is still running
  if ps -p $PORT_FORWARD_PID > /dev/null 2>&1; then
    echo_info "Port-forwarding established successfully."
    echo_info "OpenGovernance is accessible at http://localhost:8080"
    echo "To sign in, use the following default credentials:"
    echo "  Username: admin@opengovernance.io"
    echo "  Password: password"
    echo "You can terminate port-forwarding by killing the background process (PID: $PORT_FORWARD_PID)."
  else
    provide_port_forward_instructions
  fi
}

# Function to set up Ingress Controller
function setup_ingress_controller() {
  echo_info "Setting up Ingress Controller."

  # Define the namespace for ingress-nginx (Using a separate namespace)
  local INGRESS_NAMESPACE="ingress-nginx"

  # Check if the namespace exists, if not, create it
  if ! kubectl get namespace "$INGRESS_NAMESPACE" > /dev/null 2>&1; then
    kubectl create namespace "$INGRESS_NAMESPACE"
    echo_info "Created namespace $INGRESS_NAMESPACE."
  fi

  # Handle existing ClusterRole ingress-nginx
  if kubectl get clusterrole ingress-nginx > /dev/null 2>&1; then
    # Check the current release namespace annotation
    CURRENT_RELEASE_NAMESPACE=$(kubectl get clusterrole ingress-nginx -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-namespace}' 2>/dev/null || true)
    if [ "$CURRENT_RELEASE_NAMESPACE" != "$INGRESS_NAMESPACE" ]; then
      echo_info "Deleting conflicting ClusterRole 'ingress-nginx'."
      kubectl delete clusterrole ingress-nginx
      kubectl delete clusterrolebinding ingress-nginx
    fi
  fi

  # Check if ingress-nginx is already installed in the ingress-nginx namespace
  if helm_quiet ls -n "$INGRESS_NAMESPACE" | grep -qw ingress-nginx; then
    echo_info "Ingress Controller already installed. Skipping installation."
  else
    echo_info "Installing ingress-nginx via Helm."
    helm_quiet repo add ingress-nginx https://kubernetes.github.io/ingress-nginx || true
    helm_quiet repo update
    helm_quiet install ingress-nginx ingress-nginx/ingress-nginx -n "$INGRESS_NAMESPACE" --create-namespace --wait
    echo_info "Ingress Controller installed."

    # Wait for ingress-nginx controller to obtain an external IP (up to 6 minutes)
    wait_for_ingress_ip "$INGRESS_NAMESPACE"
  fi
}

# Function to wait for ingress-nginx controller to obtain an external IP
function wait_for_ingress_ip() {
  local namespace="$1"
  local timeout=360  # 6 minutes
  local interval=30
  local elapsed=0

  echo_info "Waiting for Ingress Controller to obtain an external IP..."

  while [ $elapsed -lt $timeout ]; do
    EXTERNAL_IP=$(kubectl get svc ingress-nginx-controller -n "$namespace" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

    if [ -n "$EXTERNAL_IP" ]; then
      echo_info "Ingress Controller external IP obtained: $EXTERNAL_IP"
      export INGRESS_EXTERNAL_IP="$EXTERNAL_IP"
      return 0
    fi

    echo_info "Ingress Controller not ready yet. Retrying in $interval seconds..."
    sleep $interval
    elapsed=$((elapsed + interval))
  done

  echo_error "Ingress Controller did not obtain an external IP within the expected time."
  exit 1
}

# Function to deploy ingress resources
function deploy_ingress_resources() {
  case $INSTALL_TYPE in
    1)
      # Install with HTTPS and Hostname
      echo_info "Deploying Ingress with HTTPS."
      ;;
    2)
      # Install without HTTPS
      echo_info "Deploying Ingress without HTTPS."
      ;;
    3)
      # Minimal Install
      echo_info "Deploying Ingress without a custom hostname."
      ;;
    4)
      # Basic Install with no Ingress
      echo_info "Basic Install selected. Skipping Ingress deployment."
      return
      ;;
    *)
      echo_error "Unsupported installation type: $INSTALL_TYPE"
      exit 1
      ;;
  esac

  # Deploy Ingress based on installation type
  case $INSTALL_TYPE in
    1)
      # Install with HTTPS and Hostname
      cat <<EOF | kubectl apply -n "$KUBE_NAMESPACE" -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: opengovernance-ingress
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - ${DOMAIN}
      secretName: opengovernance-tls
  rules:
    - host: ${DOMAIN}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: nginx-proxy
                port:
                  number: 80
EOF
      ;;
    2)
      # Install without HTTPS
      cat <<EOF | kubectl apply -n "$KUBE_NAMESPACE" -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: opengovernance-ingress
  annotations:
    kubernetes.io/ingress.class: "nginx"
spec:
  ingressClassName: nginx
  rules:
    - host: ${DOMAIN}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: nginx-proxy
                port:
                  number: 80
EOF
      ;;
    3)
      # Minimal Install
      cat <<EOF | kubectl apply -n "$KUBE_NAMESPACE" -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: opengovernance-ingress
  annotations:
    kubernetes.io/ingress.class: "nginx"
spec:
  ingressClassName: nginx
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: nginx-proxy
                port:
                  number: 80
EOF
      ;;
  esac

  echo_info "Ingress resources deployed."
}

# Function to set up Cert-Manager and Issuer for Let's Encrypt
function setup_cert_manager_and_issuer() {
  echo_info "Setting up Cert-Manager and Let's Encrypt Issuer."

  # Function to check if Cert-Manager is installed
  function is_cert_manager_installed() {
    if helm_quiet list -A | grep -qw "cert-manager"; then
      return 0
    fi

    if kubectl get namespace cert-manager > /dev/null 2>&1 && kubectl get deployments -n cert-manager | grep -q "cert-manager"; then
      return 0
    fi

    return 1
  }

  # Function to wait for the ClusterIssuer to be ready
  function wait_for_clusterissuer_ready() {
    local max_attempts=10
    local sleep_time=30
    local attempts=0

    echo_info "Waiting for ClusterIssuer 'letsencrypt' to become ready..."

    while [ $attempts -lt $max_attempts ]; do
      local ready_status
      ready_status=$(kubectl get clusterissuer letsencrypt -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")

      if [ "$ready_status" == "True" ]; then
        echo_info "ClusterIssuer 'letsencrypt' is ready."
        return 0
      fi

      attempts=$((attempts + 1))
      echo_info "ClusterIssuer not ready yet. Retrying in $sleep_time seconds... ($attempts/$max_attempts)"
      sleep $sleep_time
    done

    echo_error "ClusterIssuer 'letsencrypt' did not become ready within the expected time."
    exit 1
  }

  # Check if Cert-Manager is already installed
  if is_cert_manager_installed; then
    echo_info "Cert-Manager is already installed. Skipping installation."
  else
    echo_info "Installing Cert-Manager via Helm."
    helm_quiet repo add jetstack https://charts.jetstack.io || true
    helm_quiet repo update
    helm_quiet install cert-manager jetstack/cert-manager -n cert-manager --create-namespace --version v1.11.0 --set installCRDs=true --wait
    echo_info "Cert-Manager installed."
  fi

  # Apply ClusterIssuer for Let's Encrypt
  kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${EMAIL}
    privateKeySecretRef:
      name: letsencrypt-private-key
    solvers:
    - http01:
        ingress:
          class: nginx
EOF

  echo_info "ClusterIssuer for Let's Encrypt created."

  # Wait for ClusterIssuer to be ready
  wait_for_clusterissuer_ready
}

# Function to restart pods
function restart_pods() {
  echo_info "Restarting OpenGovernance Pods to Apply Changes."

  # Restart only the specified deployments
  kubectl rollout restart deployment nginx-proxy -n "$KUBE_NAMESPACE"
  kubectl rollout restart deployment opengovernance-dex -n "$KUBE_NAMESPACE"

  echo_info "Pods restarted successfully."
}

# Function to provide port-forward instructions
function provide_port_forward_instructions() {
  echo_error "OpenGovernance is running but not accessible via Ingress."
  echo "You can access it using port-forwarding as follows:"
  echo "kubectl port-forward -n $KUBE_NAMESPACE service/nginx-proxy 8080:80"
  echo "Then, access it at http://localhost:8080"
  echo ""
  echo "To sign in, use the following default credentials:"
  echo "  Username: admin@opengovernance.io"
  echo "  Password: password"
}

# Function to display completion message with protocol, DNS instructions, and default login details
function display_completion_message() {
  # Determine the protocol (http or https)
  local protocol="http"
  if [ "$ENABLE_HTTPS" = true ]; then
    protocol="https"
  fi

  echo_info "Installation Complete"

  echo ""
  echo "-----------------------------------------------------"
  echo "OpenGovernance has been successfully installed and configured."
  echo ""
  if [ "$INSTALL_TYPE" -ne 3 ] && [ "$INSTALL_TYPE" -ne 4 ]; then
    echo "Access your OpenGovernance instance at: ${protocol}://${DOMAIN}"
  elif [ "$INSTALL_TYPE" -eq 4 ]; then
    echo "Access your OpenGovernance instance at: ${protocol}://${INGRESS_EXTERNAL_IP}"
  else
    echo "Access your OpenGovernance instance using the public IP: ${INGRESS_EXTERNAL_IP}"
  fi
  echo ""
  echo "To sign in, use the following default credentials:"
  echo "  Username: admin@opengovernance.io"
  echo "  Password: password"
  echo ""

  # DNS A record setup instructions if domain is configured and not minimal
  if [ -n "$DOMAIN" ] && [ "$INSTALL_TYPE" -ne 3 ]; then
    echo "To ensure proper access to your instance, please verify or set up the following DNS A records:"
    echo ""
    echo "  Domain: ${DOMAIN}"
    echo "  Record Type: A"
    echo "  Value: ${INGRESS_EXTERNAL_IP}"
    echo ""
    echo "Note: It may take some time for DNS changes to propagate."
  fi

  # If Ingress is not properly configured or it's a Basic Install, provide port-forward instructions
  if [ "$DEPLOY_SUCCESS" = false ] || [ "$INSTALL_TYPE" -eq 4 ]; then
    provide_port_forward_instructions
  fi

  echo "-----------------------------------------------------"
}

# Function to run installation logic
function run_installation_logic() {
  # Check if OpenGovernance is installed
  if ! check_opengovernance_installation; then
    # OpenGovernance is not installed, proceed with installation
    echo_info "OpenGovernance is not installed."

    # If not in silent mode, prompt for installation type
    if [ "$SILENT_INSTALL" = false ]; then
      echo_info "Starting interactive installation type selection..."
      choose_install_type
    fi

    # Configure email and domain based on installation type
    configure_email_and_domain

    # Perform installation based on INSTALL_TYPE
    case $INSTALL_TYPE in
      1)
        install_opengovernance_with_https  # Install with HTTPS and Hostname
        ;;
      2)
        install_opengovernance_with_hostname_only  # Install without HTTPS
        ;;
      3)
        install_opengovernance_with_public_ip  # Minimal Install
        ;;
      4)
        install_opengovernance_no_ingress  # Basic Install
        ;;
      *)
        echo_error "Unsupported installation type: $INSTALL_TYPE"
        exit 1
        ;;
    esac

    # Handle post-installation steps based on INSTALL_TYPE
    if [ "$INSTALL_TYPE" -eq 1 ] || [ "$INSTALL_TYPE" -eq 2 ]; then
      # For Install with HTTPS and Install without HTTPS
      # a. Check pod readiness
      check_pods_and_jobs

      # b. Set up Ingress Controller
      setup_ingress_controller
      DEPLOY_SUCCESS=true

      # c. Deploy Ingress resources
      deploy_ingress_resources || DEPLOY_SUCCESS=false

      # d. If HTTPS is enabled, set up Cert-Manager and Issuer
      if [ "$ENABLE_HTTPS" = true ]; then
        setup_cert_manager_and_issuer || DEPLOY_SUCCESS=false
      fi

      # e. Restart Dex and NGINX services by restarting their deployments
      restart_pods || DEPLOY_SUCCESS=false
    elif [ "$INSTALL_TYPE" -eq 3 ] || [ "$INSTALL_TYPE" -eq 4 ]; then
      # For Minimal Install and Basic Install
      DEPLOY_SUCCESS=true  # These install functions handle their own setup
    else
      DEPLOY_SUCCESS=false
    fi

    # Display completion message or provide port-forward instructions
    if [ "$DEPLOY_SUCCESS" = true ]; then
      display_completion_message
    else
      provide_port_forward_instructions
    fi
  else
    # OpenGovernance is already installed, check its health
    echo_info "OpenGovernance is already installed. Checking health status..."
    check_opengovernance_health

    if [ "$APP_HEALTHY" = false ]; then
      # OpenGovernance has health issues, attempt to upgrade
      echo_info "OpenGovernance has health issues. Attempting to upgrade."

      # Perform upgrade based on INSTALL_TYPE
      case $INSTALL_TYPE in
        1)
          install_opengovernance_with_https  # Upgrade with HTTPS and Hostname
          ;;
        2)
          install_opengovernance_with_hostname_only  # Upgrade without HTTPS
          ;;
        3)
          install_opengovernance_with_public_ip  # Minimal Install Upgrade
          ;;
        4)
          install_opengovernance_no_ingress  # Basic Install Upgrade
          ;;
        *)
          echo_error "Unsupported installation type: $INSTALL_TYPE"
          exit 1
          ;;
      esac

      # Re-check pod readiness after upgrade
      check_pods_and_jobs

      # Handle post-upgrade steps based on INSTALL_TYPE
      if [ "$INSTALL_TYPE" -eq 1 ] || [ "$INSTALL_TYPE" -eq 2 ]; then
        # a. Set up Ingress Controller
        setup_ingress_controller
        DEPLOY_SUCCESS=true

        # b. Deploy Ingress resources
        deploy_ingress_resources || DEPLOY_SUCCESS=false

        # c. If HTTPS is enabled, set up Cert-Manager and Issuer
        if [ "$ENABLE_HTTPS" = true ]; then
          setup_cert_manager_and_issuer || DEPLOY_SUCCESS=false
        fi

        # d. Restart Dex and NGINX services by restarting their deployments
        restart_pods || DEPLOY_SUCCESS=false
      elif [ "$INSTALL_TYPE" -eq 3 ] || [ "$INSTALL_TYPE" -eq 4 ]; then
        # Minimal Install and Basic Install handle their own setup
        DEPLOY_SUCCESS=true
      else
        DEPLOY_SUCCESS=false
      fi

      # Display completion message or provide port-forward instructions
      if [ "$DEPLOY_SUCCESS" = true ]; then
        display_completion_message
      else
        provide_port_forward_instructions
      fi
    else
      # OpenGovernance is healthy, check configuration
      echo_info "OpenGovernance is healthy. Verifying configuration..."
      check_opengovernance_config

      if [ "$ENABLE_HTTPS" = true ] && [ "$ssl_configured" = true ]; then
        echo_info "OpenGovernance is fully configured with HTTPS."
      else
        echo_info "OpenGovernance is installed but HTTPS is not fully configured."

        # Proceed with HTTPS configuration if applicable
        if [ "$ENABLE_HTTPS" = true ]; then
          echo_info "Proceeding with HTTPS configuration in 5 seconds..."
          sleep 5

          # a. Set up Cert-Manager and Issuer
          setup_cert_manager_and_issuer

          # b. Deploy Ingress resources
          deploy_ingress_resources

          # c. Restart Dex and NGINX services by restarting their deployments
          restart_pods

          # d. Display completion message
          display_completion_message
        fi
      fi
    fi
  fi
}

# -----------------------------
# Main Execution Flow
# -----------------------------

parse_args "$@"
check_prerequisites
run_installation_logic
