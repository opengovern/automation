#!/bin/bash

set -e

# Function to display messages
function echo_info() {
  echo -e "\n\033[1;34m$1\033[0m\n"
}

# Check if EMAIL and DOMAIN variables are set
if [ -z "$EMAIL" ] || [ -z "$DOMAIN" ]; then
  echo -e "\033[0;31mError: EMAIL and DOMAIN environment variables must be set.\033[0m"
  echo "Please set them using:"
  echo 'export EMAIL="your-email@example.com"'
  echo 'export DOMAIN="demo.opengovernance.io"'
  exit 1
fi

# 1. Configure cert-manager only if it's not already installed
echo_info "=== Checking if cert-manager is installed ==="

# Check if cert-manager is installed by looking for its Helm release in the cert-manager namespace
if helm list -n cert-manager | grep cert-manager > /dev/null 2>&1; then
  echo_info "cert-manager is already installed. Skipping installation."
else
  echo_info "cert-manager not found. Installing cert-manager."

  # Add Jetstack Helm repository if it's not already added
  if helm repo list | grep jetstack > /dev/null 2>&1; then
    echo_info "Jetstack Helm repository already exists. Skipping add."
  else
    helm repo add jetstack https://charts.jetstack.io
    echo_info "Added Jetstack Helm repository."
  fi

  helm repo update

  # Install cert-manager with CRDs
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

# 2. Create Issuer for Let's Encrypt only if it doesn't exist
echo_info "=== Checking if Issuer for Let's Encrypt exists ==="

# Check if the Issuer exists in the opengovernance namespace
if kubectl get issuer letsencrypt-nginx -n opengovernance > /dev/null 2>&1; then
  echo_info "Issuer 'letsencrypt-nginx' already exists. Skipping creation."
else
  echo_info "Issuer 'letsencrypt-nginx' not found. Creating Issuer."

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

  echo_info "Waiting for Issuer to be ready..."
  kubectl wait --namespace opengovernance \
    --for=condition=Ready issuer/letsencrypt-nginx \
    --timeout=120s
fi

# 3. Install Ingress Controller only if it's not already installed
echo_info "=== Checking if NGINX Ingress Controller is installed ==="

# Check if ingress-nginx is installed by looking for its Helm release in the opengovernance namespace
if helm list -n opengovernance | grep ingress-nginx > /dev/null 2>&1; then
  echo_info "NGINX Ingress Controller is already installed. Skipping installation."
else
  echo_info "NGINX Ingress Controller not found. Installing Ingress Controller."

  # Add ingress-nginx Helm repository if it's not already added
  if helm repo list | grep ingress-nginx > /dev/null 2>&1; then
    echo_info "Ingress-nginx Helm repository already exists. Skipping add."
  else
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
    echo_info "Added ingress-nginx Helm repository."
  fi

  helm repo update

  # Install Ingress Controller
  helm install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace opengovernance \
    --create-namespace \
    --set controller.replicaCount=2 \
    --set controller.resources.requests.cpu=100m \
    --set controller.resources.requests.memory=90Mi

  echo_info "Waiting for Ingress Controller to obtain an external IP..."
  # Wait until the EXTERNAL-IP is assigned
  while true; do
    EXTERNAL_IP=$(kubectl get svc ingress-nginx-controller -n opengovernance -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    if [ -n "$EXTERNAL_IP" ]; then
      echo "Ingress Controller External IP: $EXTERNAL_IP"
      break
    fi
    echo "Waiting for EXTERNAL-IP assignment..."
    sleep 10
  done
fi

echo_info "=== Setup Completed Successfully ==="
echo "CERT-MANAGER and NGINX Ingress Controller are installed and configured."
echo "Email: $EMAIL"
echo "Domain: $DOMAIN"
echo "Ingress Controller External IP: $EXTERNAL_IP"
