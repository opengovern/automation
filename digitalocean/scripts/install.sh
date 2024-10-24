#!/bin/bash

set -e

# -----------------------------
# Logging Configuration
# -----------------------------
LOGFILE="/var/log/opengovernance_install.log"

# Ensure the log directory exists
mkdir -p "$(dirname "$LOGFILE")"

# Redirect all output to the log file and the console
exec > >(tee -i "$LOGFILE") 2>&1

# -----------------------------
# Function Definitions
# -----------------------------

# Function to display informational messages
function echo_info() {
  printf "\n\033[1;34m%s\033[0m\n\n" "$1"
}

# Function to display error messages
function echo_error() {
  printf "\n\033[0;31m%s\033[0m\n\n" "$1"
}

# Function to display usage information
function usage() {
  echo "Usage: $0 [-d DOMAIN] [-e EMAIL] [--dry-run]"
  echo ""
  echo "Options:"
  echo "  -d, --domain    Specify the domain for OpenGovernance."
  echo "  -e, --email     Specify the email for Let's Encrypt certificate generation."
  echo "  --dry-run       Perform a trial run with no changes made."
  echo "  -h, --help      Display this help message."
  exit 1
}

# Function to validate email format
function validate_email() {
  local email_regex="^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"
  if [[ ! "$EMAIL" =~ $email_regex ]]; then
    echo_error "Invalid email format: $EMAIL"
    exit 1
  fi
}

# Function to validate domain format
function validate_domain() {
  local domain_regex="^(([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)\.)+([A-Za-z]{2,})$"
  if [[ ! "$DOMAIN" =~ $domain_regex ]]; then
    echo_error "Invalid domain format: $DOMAIN"
    exit 1
  fi
}

# Function to parse command-line arguments
function parse_args() {
  DRY_RUN=false
  while [[ "$#" -gt 0 ]]; do
    case $1 in
      -d|--domain)
        DOMAIN="$2"
        shift 2
        ;;
      -e|--email)
        EMAIL="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
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

  # Validate DOMAIN and EMAIL if they are set
  if [ -n "$DOMAIN" ]; then
    validate_domain
  fi

  if [ -n "$EMAIL" ]; then
    validate_email
  fi
}

# Function to check prerequisites (Step 1)
function check_prerequisites() {
  echo_info "Step 1 of 10: Checking Prerequisites"

  # Check if kubectl is connected to a cluster
  if ! kubectl cluster-info > /dev/null 2>&1; then
    echo_error "Error: kubectl is not connected to a cluster."
    echo "Please configure kubectl to connect to a Kubernetes cluster and try again."
    exit 1
  fi

  # Check if Helm is installed
  if ! command -v helm &> /dev/null; then
    echo_error "Error: Helm is not installed."
    echo "Please install Helm and try again."
    exit 1
  fi

  # Check if necessary Kubernetes resources are available
  REQUIRED_KUBECTL_RESOURCES=("ingress" "svc" "pods" "namespace")
  for resource in "${REQUIRED_KUBECTL_RESOURCES[@]}"; do
    if ! kubectl api-resources | grep -qw "$resource"; then
      echo_error "Error: Kubernetes resource '$resource' is not available."
      exit 1
    fi
  done
}

# Function to capture DOMAIN and EMAIL variables when needed
function configure_email_and_domain() {
  echo_info "Configuring DOMAIN and EMAIL"

  # Capture DOMAIN if not set via arguments
  if [ -z "$DOMAIN" ]; then
    while true; do
      echo ""
      echo "Enter your domain for OpenGovernance (required for HTTPS)."
      echo "Without a domain, HTTPS cannot be configured. The app will still be accessible on an IP address."
      read -p "Domain (or press Enter to skip): " DOMAIN < /dev/tty
      if [ -z "$DOMAIN" ]; then
        echo_info "No domain entered. Skipping domain configuration."
        break
      fi
      echo "You entered: $DOMAIN"
      read -p "Is this correct? (Y/n): " yn < /dev/tty
      case $yn in
          "" | [Yy]* ) 
              validate_domain
              break
              ;;
          [Nn]* ) 
              echo "Let's try again."
              DOMAIN=""
              ;;
          * ) 
              echo "Please answer y or n.";;
      esac
    done
  fi

  # Proceed to capture EMAIL if DOMAIN is set
  if [ -n "$DOMAIN" ]; then
    if [ -z "$EMAIL" ]; then
      while true; do
        echo "Enter your email for HTTPS certificate generation via Let's Encrypt."
        echo "A valid email is required; invalid email will cause certificate errors and installation failure."
        echo "If you prefer to use your own certificate, you can configure it post-install."
        read -p "Email (or press Enter to skip HTTPS setup): " EMAIL < /dev/tty
        if [ -z "$EMAIL" ]; then
          echo_info "No email entered. Skipping HTTPS configuration."
          break
        fi
        echo "You entered: $EMAIL"
        read -p "Is this correct? (Y/n): " yn < /dev/tty
        case $yn in
            "" | [Yy]* ) 
                validate_email
                break
                ;;
            [Nn]* ) 
                echo "Let's try again."
                EMAIL=""
                ;;
            * ) 
                echo "Please answer y or n.";;
        esac
      done
    fi
  else
    EMAIL=""
  fi
}

# Function to check if OpenGovernance is installed and healthy (Step 2)
function check_opengovernance_status() {
  echo_info "Step 2 of 10: Checking if OpenGovernance is installed and healthy."

  APP_INSTALLED=false
  APP_HEALTHY=false

  # Check if app is installed
  if helm ls -n opengovernance | grep -qw opengovernance; then
    APP_INSTALLED=true
    echo_info "OpenGovernance is installed. Checking health status."

    # Check if all pods are healthy
    UNHEALTHY_PODS=$(kubectl get pods -n opengovernance --no-headers | awk '{print $1,$3}' | grep -E "CrashLoopBackOff|Error|Failed|Pending|Terminating" || true)
    if [ -z "$UNHEALTHY_PODS" ]; then
      APP_HEALTHY=true
      echo_info "All OpenGovernance pods are healthy."
    else
      echo_error "Detected unhealthy pods:"
      echo "$UNHEALTHY_PODS"
    fi
  else
    echo_info "OpenGovernance is not installed."
  fi
}

# Function to uninstall and reinstall OpenGovernance (Reinstallation)
function uninstall_and_reinstall_opengovernance() {
  echo_info "Reinstalling OpenGovernance due to unhealthy pods."

  # Prompt for confirmation
  while true; do
    read -p "Are you sure you want to uninstall and reinstall OpenGovernance? (y/N): " yn < /dev/tty
    case $yn in
        [Yy]* )
          # Uninstall OpenGovernance
          if helm uninstall opengovernance -n opengovernance; then
            echo_info "Helm release 'opengovernance' uninstalled successfully."
          else
            echo_error "Failed to uninstall Helm release 'opengovernance'."
            exit 1
          fi

          if kubectl delete namespace opengovernance; then
            echo_info "Namespace 'opengovernance' deleted successfully."
          else
            echo_error "Failed to delete namespace 'opengovernance'."
            exit 1
          fi

          # Wait for namespace deletion
          echo_info "Waiting for namespace 'opengovernance' to be deleted."
          while kubectl get namespace opengovernance > /dev/null 2>&1; do
            sleep 5
          done
          echo_info "Namespace 'opengovernance' has been deleted."

          # Run installation logic again
          run_installation_logic
          break
          ;;
        [Nn]* | "" )
          echo_info "Skipping uninstallation and reinstallation of OpenGovernance."
          echo_info "Please resolve the pod issues manually or rerun the script."
          exit 0
          ;;
        * ) echo "Please answer y or n.";;
    esac
  done
}

# Function to install OpenGovernance with custom domain and with HTTPS
function install_opengovernance_with_custom_domain_with_https() {
  echo_info "Step 4 of 10: Installing OpenGovernance with custom domain and HTTPS"

  # Add the OpenGovernance Helm repository and update
  if ! helm repo list | grep -qw opengovernance; then
    helm repo add opengovernance https://opengovern.github.io/charts
    echo_info "Added OpenGovernance Helm repository."
  else
    echo_info "OpenGovernance Helm repository already exists. Skipping add."
  fi
  helm repo update

  # Install OpenGovernance
  echo_info "Note: The Helm installation can take 5-7 minutes to complete. Please be patient."

  if [ "$DRY_RUN" = true ]; then
    helm install -n opengovernance opengovernance \
      opengovernance/opengovernance --create-namespace --timeout=10m \
      --dry-run \
      -f - <<EOF
global:
  domain: ${DOMAIN}
dex:
  config:
    issuer: https://${DOMAIN}/dex
EOF
  else
    helm install -n opengovernance opengovernance \
      opengovernance/opengovernance --create-namespace --timeout=10m \
      -f - <<EOF
global:
  domain: ${DOMAIN}
dex:
  config:
    issuer: https://${DOMAIN}/dex
EOF
  fi

  echo_info "OpenGovernance application installation completed."
}

# Function to install OpenGovernance with custom domain and without HTTPS
function install_opengovernance_with_custom_domain_no_https() {
  echo_info "Step 4 of 10: Installing OpenGovernance with custom domain and without HTTPS"

  # Add the OpenGovernance Helm repository and update
  if ! helm repo list | grep -qw opengovernance; then
    helm repo add opengovernance https://opengovern.github.io/charts
    echo_info "Added OpenGovernance Helm repository."
  else
    echo_info "OpenGovernance Helm repository already exists. Skipping add."
  fi
  helm repo update

  # Install OpenGovernance
  echo_info "Note: The Helm installation can take 5-7 minutes to complete. Please be patient."

  if [ "$DRY_RUN" = true ]; then
    helm install -n opengovernance opengovernance \
      opengovernance/opengovernance --create-namespace --timeout=10m \
      --dry-run \
      -f - <<EOF
global:
  domain: ${DOMAIN}
dex:
  config:
    issuer: http://${DOMAIN}/dex
EOF
  else
    helm install -n opengovernance opengovernance \
      opengovernance/opengovernance --create-namespace --timeout=10m \
      -f - <<EOF
global:
  domain: ${DOMAIN}
dex:
  config:
    issuer: http://${DOMAIN}/dex
EOF
  fi

  echo_info "OpenGovernance application installation completed."
}

# Function to install OpenGovernance without custom domain
function install_opengovernance() {
  echo_info "Step 4 of 10: Installing OpenGovernance without custom domain"

  # Add the OpenGovernance Helm repository and update
  if ! helm repo list | grep -qw opengovernance; then
    helm repo add opengovernance https://opengovern.github.io/charts
    echo_info "Added OpenGovernance Helm repository."
  else
    echo_info "OpenGovernance Helm repository already exists. Skipping add."
  fi
  helm repo update

  # Install OpenGovernance
  echo_info "Note: The Helm installation can take 5-7 minutes to complete. Please be patient."

  if [ "$DRY_RUN" = true ]; then
    helm install -n opengovernance opengovernance \
      opengovernance/opengovernance --create-namespace --timeout=10m \
      --dry-run
  else
    helm install -n opengovernance opengovernance \
      opengovernance/opengovernance --create-namespace --timeout=10m
  fi

  echo_info "OpenGovernance application installation completed."
}

# Function to check pods and migrator jobs (Step 5)
function check_pods_and_jobs() {
  echo_info "Step 5 of 10: Checking Pods and Migrator Jobs"

  echo_info "Waiting for all Pods to be ready..."

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

  # Check the status of 'migrator-job' pods
  echo_info "Checking the status of 'migrator-job' pods"

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
}

# Function to set up cert-manager and Let's Encrypt Issuer (Step 6)
function setup_cert_manager_and_issuer() {
  echo_info "Step 6 of 10: Setting up cert-manager and Let's Encrypt Issuer"

  # Check if cert-manager is installed in any namespace
  if helm list --all-namespaces | grep -qw cert-manager; then
    echo_info "cert-manager is already installed in the cluster. Skipping installation."
  else
    # Add Jetstack Helm repository if not already added
    if ! helm repo list | grep -qw jetstack; then
      helm repo add jetstack https://charts.jetstack.io
      echo_info "Added Jetstack Helm repository."
    else
      echo_info "Jetstack Helm repository already exists. Skipping add."
    fi

    helm repo update

    # Install cert-manager in the 'cert-manager' namespace
    echo_info "Installing cert-manager in the 'cert-manager' namespace."
    if [ "$DRY_RUN" = true ]; then
      helm install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --create-namespace \
        --set installCRDs=true \
        --set prometheus.enabled=false \
        --dry-run
    else
      helm install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --create-namespace \
        --set installCRDs=true \
        --set prometheus.enabled=false
    fi

    echo_info "Waiting for cert-manager pods to be ready..."
    if ! kubectl wait --for=condition=ready pod --all --namespace cert-manager --timeout=120s; then
      echo_error "cert-manager pods did not become ready in time."
      exit 1
    fi
  fi

  # Check if the Let's Encrypt Issuer already exists in 'opengovernance' namespace
  if kubectl get issuer letsencrypt-nginx -n opengovernance > /dev/null 2>&1; then
    echo_info "Issuer 'letsencrypt-nginx' already exists in 'opengovernance' namespace. Skipping creation."
  else
    # Create the Let's Encrypt Issuer in the 'opengovernance' namespace
    echo_info "Creating Let's Encrypt Issuer in 'opengovernance' namespace."
    if [ "$DRY_RUN" = true ]; then
      kubectl apply -f - <<EOF --dry-run=client
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: letsencrypt-nginx
  namespace: opengovernance
spec:
  acme:
    email: ${EMAIL}
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-nginx-private-key
    solvers:
      - http01:
          ingress:
            class: nginx
EOF
    else
      kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: letsencrypt-nginx
  namespace: opengovernance
spec:
  acme:
    email: ${EMAIL}
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-nginx-private-key
    solvers:
      - http01:
          ingress:
            class: nginx
EOF
    fi

    echo_info "Waiting for Issuer to be ready (up to 6 minutes)..."
    if ! kubectl wait --namespace opengovernance \
      --for=condition=Ready issuer/letsencrypt-nginx \
      --timeout=360s; then
      echo_error "Issuer 'letsencrypt-nginx' did not become ready in time."
      exit 1
    fi
  fi
}

# Function to install NGINX Ingress Controller and get External IP (Step 7)
function setup_ingress_controller() {
  echo_info "Step 7 of 10: Installing NGINX Ingress Controller and Retrieving External IP"

  # Install NGINX Ingress Controller if not already installed
  if helm list -n opengovernance | grep -qw ingress-nginx; then
    echo_info "NGINX Ingress Controller is already installed. Skipping installation."
  else
    if ! helm repo list | grep -qw ingress-nginx; then
      helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
      echo_info "Added ingress-nginx Helm repository."
    else
      echo_info "Ingress-nginx Helm repository already exists. Skipping add."
    fi

    helm repo update

    echo_info "Installing NGINX Ingress Controller in 'opengovernance' namespace."
    if [ "$DRY_RUN" = true ]; then
      helm install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace opengovernance \
        --create-namespace \
        --set controller.replicaCount=2 \
        --set controller.resources.requests.cpu=100m \
        --set controller.resources.requests.memory=90Mi \
        --dry-run
    else
      helm install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace opengovernance \
        --create-namespace \
        --set controller.replicaCount=2 \
        --set controller.resources.requests.cpu=100m \
        --set controller.resources.requests.memory=90Mi
    fi
  fi

  echo_info "Waiting for Ingress Controller to obtain an external IP (2-6 minutes)..."
  START_TIME=$(date +%s)
  TIMEOUT=360  # 6 minutes

  while true; do
    INGRESS_EXTERNAL_IP=$(kubectl get svc ingress-nginx-controller -n opengovernance -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [ -n "$INGRESS_EXTERNAL_IP" ]; then
      echo "Ingress Controller External IP: $INGRESS_EXTERNAL_IP"
      break
    fi
    CURRENT_TIME=$(date +%s)
    ELAPSED_TIME=$((CURRENT_TIME - START_TIME))
    if [ $ELAPSED_TIME -ge $TIMEOUT ]; then
      echo_error "Error: Ingress Controller External IP not assigned within timeout period."
      exit 1
    fi
    echo "Waiting for EXTERNAL-IP assignment..."
    sleep 15
  done

  # Export the external IP for later use
  export INGRESS_EXTERNAL_IP
}

# Function to deploy Ingress Resources (Step 8)
function deploy_ingress_resources() {
  echo_info "Step 8 of 10: Deploying Ingress Resources"

  # Define desired Ingress configuration based on the installation case
  if [ "$ENABLE_HTTPS" = true ]; then
    # Custom Domain with HTTPS
    DESIRED_INGRESS=$(cat <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: opengovernance-ingress
  namespace: opengovernance
  annotations:
    cert-manager.io/issuer: letsencrypt-nginx
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  tls:
    - hosts:
        - ${DOMAIN}
      secretName: letsencrypt-nginx
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
)
  elif [ -n "$DOMAIN" ]; then
    # Custom Domain without HTTPS
    DESIRED_INGRESS=$(cat <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: opengovernance-ingress
  namespace: opengovernance
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
)
  else
    # No Custom Domain, use external IP, no host field
    DESIRED_INGRESS=$(cat <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: opengovernance-ingress
  namespace: opengovernance
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
)
  fi

  # Apply the Ingress configuration
  echo_info "Applying Ingress configuration."
  if [ "$DRY_RUN" = true ]; then
    echo "$DESIRED_INGRESS" | kubectl apply -f - --dry-run=client
  else
    echo "$DESIRED_INGRESS" | kubectl apply -f -
  fi
  echo_info "Ingress 'opengovernance-ingress' has been applied."
}

# Function to perform Helm upgrade with external IP (for no custom domain) (Step 9)
function perform_helm_upgrade_no_custom_domain() {
  echo_info "Step 9 of 10: Performing Helm Upgrade with External IP"

  if [ -z "$INGRESS_EXTERNAL_IP" ]; then
    echo_error "Error: Ingress External IP is not set."
    exit 1
  fi

  echo_info "Upgrading OpenGovernance Helm release with external IP: $INGRESS_EXTERNAL_IP"

  if [ "$DRY_RUN" = true ]; then
    helm upgrade -n opengovernance opengovernance opengovernance/opengovernance --timeout=10m --dry-run -f - <<EOF
global:
  domain: "${INGRESS_EXTERNAL_IP}"
  debugMode: true
dex:
  config:
    issuer: "http://${INGRESS_EXTERNAL_IP}/dex"
EOF
  else
    helm upgrade -n opengovernance opengovernance opengovernance/opengovernance --timeout=10m -f - <<EOF
global:
  domain: "${INGRESS_EXTERNAL_IP}"
  debugMode: true
dex:
  config:
    issuer: "http://${INGRESS_EXTERNAL_IP}/dex"
EOF
  fi

  echo_info "Helm upgrade completed successfully."
}

# Function to restart relevant pods (Step 10)
function restart_pods() {
  echo_info "Step 10 of 10: Restarting Relevant Pods"

  if kubectl get pods -n opengovernance -l app=nginx-proxy | grep -qw nginx-proxy; then
    kubectl delete pods -l app=nginx-proxy -n opengovernance
    echo_info "nginx-proxy pods have been restarted."
  else
    echo_info "No nginx-proxy pods found to restart."
  fi

  if kubectl get pods -n opengovernance -l app.kubernetes.io/name=dex | grep -qw dex; then
    kubectl delete pods -l app.kubernetes.io/name=dex -n opengovernance
    echo_info "dex pods have been restarted."
  else
    echo_info "No dex pods found to restart."
  fi
}

# Function to display completion message (Step 11)
function display_completion_message() {
  echo_info "Step 11 of 11: Setup Completed Successfully"

  echo "Please allow a few minutes for the changes to propagate and for services to become fully operational."

  if [ "$ENABLE_HTTPS" = true ]; then
    PROTOCOL="https"
  else
    PROTOCOL="http"
  fi

  echo_info "After Setup:"
  if [ -n "$DOMAIN" ]; then
    echo "1. Create a DNS A record pointing your domain to the Ingress Controller's external IP."
    echo "   - Type: A"
    echo "   - Name (Key): ${DOMAIN}"
    echo "   - Value: ${INGRESS_EXTERNAL_IP}"
    echo "2. After the DNS changes take effect, open ${PROTOCOL}://${DOMAIN}."
    echo "   - You can log in with the following credentials:"
    echo "     - Username: admin@opengovernance.io"
    echo "     - Password: password"
  else
    echo "1. Access the OpenGovernance application using the Ingress Controller's external IP:"
    echo "   - URL: ${PROTOCOL}://${INGRESS_EXTERNAL_IP}"
    echo "   - Alternatively, use port-forwarding as described below."
    echo "2. You can log in with the following credentials:"
    echo "   - Username: admin@opengovernance.io"
    echo "   - Password: password"
  fi
}

# Function to provide port-forwarding instructions (Fallback)
function provide_port_forward_instructions() {
  echo_info "Installation partially completed."

  echo_error "Failed to set up Ingress resources. Providing port-forwarding instructions as a fallback."

  echo_info "To access the OpenGovernance application, please run the following command in a separate terminal:"
  printf "\033[1;32m%s\033[0m\n" "kubectl port-forward -n opengovernance svc/nginx-proxy 8080:80"
  echo "Then open http://localhost:8080/ in your browser, and sign in with the following credentials:"
  echo "Username: admin@opengovernance.io"
  echo "Password: password"
}

# Function to run installation logic based on user input
function run_installation_logic() {
  if [ "$APP_INSTALLED" = false ]; then
    # New installation
    if [ -z "$DOMAIN" ]; then
      # Install without custom domain
      echo_info "Installing OpenGovernance without custom domain."
      echo_info "The installation will start in 10 seconds. Press Ctrl+C to cancel."
      sleep 10
      install_opengovernance
      check_pods_and_jobs

      # Attempt to set up Ingress Controller and related resources
      set +e  # Temporarily disable exit on error
      setup_ingress_controller
      DEPLOY_SUCCESS=true

      deploy_ingress_resources || DEPLOY_SUCCESS=false
      perform_helm_upgrade_no_custom_domain || DEPLOY_SUCCESS=false
      restart_pods || DEPLOY_SUCCESS=false
      set -e  # Re-enable exit on error

      if [ "$DEPLOY_SUCCESS" = true ]; then
        display_completion_message
      else
        provide_port_forward_instructions
      fi
    else
      # Install with custom domain
      # Configure email and domain if not already set
      configure_email_and_domain

      if [ -n "$EMAIL" ]; then
        ENABLE_HTTPS=true
        echo_info "Installing OpenGovernance with custom domain: $DOMAIN and HTTPS"
        echo_info "The installation will start in 10 seconds. Press Ctrl+C to cancel."
        sleep 10
        install_opengovernance_with_custom_domain_with_https
        check_pods_and_jobs
        setup_ingress_controller
        setup_cert_manager_and_issuer
        deploy_ingress_resources
        restart_pods
        display_completion_message
      else
        ENABLE_HTTPS=false
        echo_info "Proceeding with installation with custom domain without HTTPS in 10 seconds. Press Ctrl+C to cancel."
        sleep 10
        install_opengovernance_with_custom_domain_no_https
        check_pods_and_jobs
        setup_ingress_controller
        deploy_ingress_resources
        restart_pods
        display_completion_message
      fi
    fi
  elif [ "$APP_INSTALLED" = true ] && [ "$APP_HEALTHY" = false ]; then
    # Uninstall and reinstall with user's consent
    uninstall_and_reinstall_opengovernance
  elif [ "$APP_INSTALLED" = true ] && [ "$APP_HEALTHY" = true ]; then
    # App is installed and healthy
    if [ -z "$DOMAIN" ]; then
      echo_info "OpenGovernance is already installed and healthy."
      echo_info "No further actions are required."
    else
      # Configure email and domain if not already set
      configure_email_and_domain

      if [ -n "$EMAIL" ]; then
        ENABLE_HTTPS=true
        echo_info "Completing post-installation steps for custom domain configuration with HTTPS."
        setup_ingress_controller
        setup_cert_manager_and_issuer
        deploy_ingress_resources
        restart_pods
        display_completion_message
      else
        ENABLE_HTTPS=false
        echo_info "Completing post-installation steps for custom domain configuration without HTTPS."
        setup_ingress_controller
        deploy_ingress_resources
        restart_pods
        display_completion_message
      fi
    fi
  fi
}

# -----------------------------
# Main Execution Flow
# -----------------------------

parse_args "$@"
check_prerequisites
check_opengovernance_status
run_installation_logic
