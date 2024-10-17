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

# 1. Configure cert-manager
echo_info "=== Installing cert-manager ==="

# Add Jetstack Helm repository
helm repo add jetstack https://charts.jetstack.io
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

# Create Issuer for Let's Encrypt
echo_info "=== Creating Issuer for Let's Encrypt ==="
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

# 2. Install Ingress Controller
echo_info "=== Installing NGINX Ingress Controller ==="

# Add ingress-nginx Helm repository
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
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

echo_info "=== Setup Completed Successfully ==="
echo "CERT-MANAGER and NGINX Ingress Controller are installed and configured."
echo "Email: $EMAIL"
echo "Domain: $DOMAIN"
echo "Ingress Controller External IP: $EXTERNAL_IP"