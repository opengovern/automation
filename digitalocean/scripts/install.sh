#!/bin/bash

set -e

# Default values for EMAIL and DOMAIN
DEFAULT_EMAIL="your-email@example.com"
DEFAULT_DOMAIN="opengovernance.example.io"

# Function to display informational messages
function echo_info() {
  printf "\n\033[1;34m%s\033[0m\n\n" "$1"
}

# Function to display error messages
function echo_error() {
  printf "\n\033[0;31m%s\033[0m\n\n" "$1"
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
}

# Function to capture EMAIL and DOMAIN variables (Step 2)
function configure_email_and_domain() {
  echo_info "Step 2 of 10: Configuring EMAIL and DOMAIN"

  # Capture EMAIL if not set
  if [ -z "$EMAIL" ]; then
    echo_info "EMAIL is not set."
    while true; do
      read -p "Please enter your email: " EMAIL < /dev/tty
      if [ -z "$EMAIL" ]; then
        echo_error "Email cannot be empty. Please enter a valid email."
        continue
      fi
      echo "You entered: $EMAIL"
      read -p "Is this correct? (y/n): " yn < /dev/tty
      case $yn in
          [Yy]* ) break;;
          [Nn]* ) echo "Let's try again.";;
          * ) echo "Please answer y or n.";;
      esac
    done
  fi

  # Capture EMAIL if set to default
  if [ "$EMAIL" = "$DEFAULT_EMAIL" ]; then
    echo_info "EMAIL is set to the default value."
    while true; do
      read -p "Do you want to enter a different email? (y/n): " yn < /dev/tty
      case $yn in
          [Yy]* )
            read -p "Please enter your email: " EMAIL < /dev/tty
            if [ -z "$EMAIL" ]; then
              echo_error "Email cannot be empty. Please enter a valid email."
              continue
            fi
            echo "You entered: $EMAIL"
            read -p "Is this correct? (y/n): " yn_confirm < /dev/tty
            case $yn_confirm in
                [Yy]* ) break;;
                [Nn]* ) echo "Let's try again.";;
                * ) echo "Please answer y or n.";;
            esac
            ;;
          [Nn]* )
            echo_info "Proceeding with the default email."
            break
            ;;
          * ) echo "Please answer y or n.";;
      esac
    done
  fi

  # Capture DOMAIN if not set or default
  if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "$DEFAULT_DOMAIN" ]; then
    if [ -z "$DOMAIN" ]; then
      echo_info "DOMAIN is not set."
    else
      echo_info "DOMAIN is set to the default value."
    fi
    while true; do
      read -p "Please enter your domain for OpenGovernance: " DOMAIN < /dev/tty
      if [ -z "$DOMAIN" ]; then
        echo_error "Domain cannot be empty. Please enter a valid domain."
        continue
      fi
      echo "You entered: $DOMAIN"
      read -p "Is this correct? (y/n): " yn < /dev/tty
      case $yn in
          [Yy]* ) break;;
          [Nn]* ) echo "Let's try again.";;
          * ) echo "Please answer y or n.";;
      esac
    done
  fi
}

# Function to check if OpenGovernance is installed and healthy
function check_opengovernance_status() {
  echo_info "Checking if OpenGovernance is installed and healthy."

  APP_INSTALLED=false
  APP_HEALTHY=false

  # Check if app is installed
  if helm ls -n opengovernance | grep opengovernance > /dev/null 2>&1; then
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

# Function to install OpenGovernance with custom domain (Step 3)
function install_opengovernance_with_custom_domain() {
  echo_info "Step 3 of 10: Installing OpenGovernance with custom domain"

  # Add the OpenGovernance Helm repository and update
  helm repo add opengovernance https://opengovern.github.io/charts 2> /dev/null || true
  helm repo update

  # Install OpenGovernance
  echo_info "Note: The Helm installation can take 5-7 minutes to complete. Please be patient."
  helm install -n opengovernance opengovernance \
    opengovernance/opengovernance --create-namespace --timeout=10m \
    -f - <<EOF
global:
  domain: ${DOMAIN}
dex:
  config:
    issuer: https://${DOMAIN}/dex
EOF
  echo_info "OpenGovernance application installation completed."
}

# Function to install OpenGovernance without custom domain (Step 3 alternative)
function install_opengovernance() {
  echo_info "Step 3 of 10: Installing OpenGovernance using Helm"

  # Add the OpenGovernance Helm repository and update
  helm repo add opengovernance https://opengovern.github.io/charts 2> /dev/null || true
  helm repo update

  # Install OpenGovernance
  echo_info "Note: The Helm installation can take 5-7 minutes to complete. Please be patient."
  helm install -n opengovernance opengovernance \
    opengovernance/opengovernance --create-namespace --timeout=10m
  echo_info "OpenGovernance application installation completed."
}

# Function to check pods and migrator jobs (Step 4)
function check_pods_and_jobs() {
  echo_info "Step 4 of 10: Checking Pods and Migrator Jobs"

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

# Function to set up cert-manager and Let's Encrypt Issuer (Step 5)
function setup_cert_manager_and_issuer() {
  echo_info "Step 5 of 10: Setting up cert-manager and Let's Encrypt Issuer"

  # Install cert-manager if not already installed
  if helm list -n cert-manager | grep cert-manager > /dev/null 2>&1; then
    echo_info "cert-manager is already installed. Skipping installation."
  else
    if helm repo list | grep jetstack > /dev/null 2>&1; then
      echo_info "Jetstack Helm repository already exists. Skipping add."
    else
      helm repo add jetstack https://charts.jetstack.io
      echo_info "Added Jetstack Helm repository."
    fi

    helm repo update

    helm install cert-manager jetstack/cert-manager \
      --namespace cert-manager \
      --create-namespace \
      --set installCRDs=true \
      --set prometheus.enabled=false

    echo_info "Waiting for cert-manager pods to be ready..."
    kubectl wait --namespace cert-manager \
      --for=condition=ready pod \
      --selector=app.kubernetes.io/name=cert-manager \
      --timeout=120s
  fi

  # Create Let's Encrypt Issuer
  if kubectl get issuer letsencrypt-nginx -n opengovernance > /dev/null 2>&1; then
    echo_info "Issuer 'letsencrypt-nginx' already exists. Skipping creation."
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

    echo_info "Waiting for Issuer to be ready (up to 6 minutes)..."
    kubectl wait --namespace opengovernance \
      --for=condition=Ready issuer/letsencrypt-nginx \
      --timeout=360s
  fi
}

# Function to install NGINX Ingress Controller and get External IP (Step 6)
function setup_ingress_controller() {
  echo_info "Step 6 of 10: Installing NGINX Ingress Controller and Retrieving External IP"

  # Install NGINX Ingress Controller if not already installed
  if helm list -n opengovernance | grep ingress-nginx > /dev/null 2>&1; then
    echo_info "NGINX Ingress Controller is already installed. Skipping installation."
  else
    if helm repo list | grep ingress-nginx > /dev/null 2>&1; then
      echo_info "Ingress-nginx Helm repository already exists. Skipping add."
    else
      helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
      echo_info "Added ingress-nginx Helm repository."
    fi

    helm repo update

    helm install ingress-nginx ingress-nginx/ingress-nginx \
      --namespace opengovernance \
      --create-namespace \
      --set controller.replicaCount=2 \
      --set controller.resources.requests.cpu=100m \
      --set controller.resources.requests.memory=90Mi
  fi

  echo_info "Waiting for Ingress Controller to obtain an external IP (up to 5 minutes)... This usually takes between 2-5 minutes."
  START_TIME=$(date +%s)
  TIMEOUT=300
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
}

# Function to deploy Ingress Resources (Step 8)
function deploy_ingress_resources() {
  echo_info "Step 8 of 10: Deploying Ingress Resources"

  kubectl apply -f - <<EOF
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
}

# Function to restart relevant pods (Step 9)
function restart_pods() {
  echo_info "Step 9 of 10: Restarting Relevant Pods"

  kubectl delete pods -l app=nginx-proxy -n opengovernance
  kubectl delete pods -l app.kubernetes.io/name=dex -n opengovernance

  echo_info "Relevant pods have been restarted."
}

# Function to display completion message (Step 10)
function display_completion_message() {
  echo_info "Step 10 of 10: Setup Completed Successfully"

  echo "Please allow a few minutes for the changes to propagate and for services to become fully operational."

  echo_info "After Setup:"
  echo "1. Create a DNS A record pointing your domain to the Ingress Controller's external IP."
  echo "   - Type: A"
  echo "   - Name (Key): ${DOMAIN}"
  echo "   - Value: ${INGRESS_EXTERNAL_IP}"
  echo "2. After the DNS changes take effect, open https://${DOMAIN}."
  echo "   - You can log in with the following credentials:"
  echo "     - Username: admin@opengovernance.io"
  echo "     - Password: password"
}

# Function to provide port-forwarding instructions
function provide_port_forward_instructions() {
  echo_info "Installation completed successfully."

  echo_info "To access the OpenGovernance application, please run the following command in a separate terminal:"
  printf "\033[1;32m%s\033[0m\n" "kubectl port-forward -n opengovernance svc/nginx-proxy 8080:80"
  echo "Then open http://localhost:8080/ in your browser, and sign in with the following credentials:"
  echo "Username: admin@opengovernance.io"
  echo "Password: password"
}

# -----------------------------
# Main Execution Flow
# -----------------------------

check_prerequisites
configure_email_and_domain
check_opengovernance_status

# Decision-making logic

if [ "$EMAIL" = "$DEFAULT_EMAIL" ] && [ "$DOMAIN" = "$DEFAULT_DOMAIN" ]; then
  # Both EMAIL and DOMAIN are set to default values
  echo_info "EMAIL and DOMAIN are set to default values."
  echo "You can enter valid EMAIL and DOMAIN values or proceed without a custom domain."
  while true; do
    read -p "Do you want to enter valid EMAIL and DOMAIN values? (y/n): " yn < /dev/tty
    case $yn in
      [Yy]* )
        configure_email_and_domain
        # Re-evaluate after capturing new values
        if [ "$EMAIL" != "$DEFAULT_EMAIL" ] && [ "$DOMAIN" != "$DEFAULT_DOMAIN" ]; then
          break
        else
          echo_info "EMAIL and DOMAIN are still set to default values."
        fi
        ;;
      [Nn]* )
        echo_info "Proceeding without custom domain."
        EMAIL=""
        DOMAIN=""
        break
        ;;
      * ) echo "Please answer y or n.";;
    esac
  done
fi

if [ -z "$EMAIL" ] && [ -z "$DOMAIN" ]; then
  # EMAIL and DOMAIN are not set
  echo_info "EMAIL and DOMAIN are not set."
  echo_info "The installation will proceed without a custom domain and https."
  echo_info "Custom domain and HTTPS can also be configured post-installation."
  echo_info "The script will continue in 10 seconds. Press Ctrl+C to cancel."
  sleep 10
  if [ "$APP_INSTALLED" = false ]; then
    install_opengovernance
  else
    echo_info "OpenGovernance is already installed and healthy. Skipping installation."
  fi
  check_pods_and_jobs
  provide_port_forward_instructions
elif [ "$EMAIL" != "$DEFAULT_EMAIL" ] && [ "$DOMAIN" != "$DEFAULT_DOMAIN" ]; then
  # EMAIL and DOMAIN are set to user-provided values
  echo_info "EMAIL and DOMAIN are set as follows:"
  echo "Email: $EMAIL"
  echo "Domain: $DOMAIN"
  echo_info "The installation will proceed with these values in 10 seconds. Press Ctrl+C to cancel."
  sleep 10
  if [ "$APP_INSTALLED" = false ]; then
    install_opengovernance_with_custom_domain
    check_pods_and_jobs
  elif [ "$APP_INSTALLED" = true ] && [ "$APP_HEALTHY" = false ]; then
    echo_info "Reinstalling OpenGovernance due to unhealthy pods."
    # Uninstall and reinstall
    helm uninstall opengovernance -n opengovernance
    kubectl delete namespace opengovernance
    # Wait for namespace deletion
    echo_info "Waiting for namespace 'opengovernance' to be deleted."
    while kubectl get namespace opengovernance > /dev/null 2>&1; do
      sleep 5
    done
    install_opengovernance_with_custom_domain
    check_pods_and_jobs
  else
    echo_info "OpenGovernance is already installed and healthy. Skipping installation."
  fi
  # Proceed with the rest of the steps regardless
  setup_cert_manager_and_issuer
  setup_ingress_controller
  deploy_ingress_resources
  restart_pods
  display_completion_message
else
  # EMAIL and DOMAIN are mismatched or invalid
  echo_error "EMAIL and DOMAIN must both be set to proceed with custom domain installation."
  echo "Please ensure both EMAIL and DOMAIN are set to valid values."
  exit 1
fi
