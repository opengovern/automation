#!/bin/bash

set -e

# Function to display informational messages
function echo_info() {
  echo -e "\n\033[1;34m$1\033[0m\n"
}

# Function to display error messages
function echo_error() {
  echo -e "\n\033[0;31m$1\033[0m\n"
}

# Check if EMAIL and DOMAIN variables are set
if [ -z "$EMAIL" ] || [ -z "$DOMAIN" ]; then
  echo_error "Error: EMAIL and DOMAIN environment variables must be set."
  echo "Please set them using:"
  echo 'export EMAIL="your-email@example.com"'
  echo 'export DOMAIN="demo.opengovernance.io"'
  exit 1
fi

### Begin setup-ingress steps

# Step 1 (of 7): Checking if cert-manager is installed (ETA: 20 seconds)
echo_info "=== Step 1 of 7: Checking if cert-manager is installed ==="
echo_info "Estimated time: 20 seconds"

if helm list -n cert-manager | grep cert-manager > /dev/null 2>&1; then
  echo_info "cert-manager is already installed. Skipping installation."
else
  echo_info "cert-manager not found. Installing cert-manager."

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

echo_info "Step 1 completed. 6 steps remaining."

# Step 2 (of 7): Creating Issuer for Let's Encrypt (ETA: 30 seconds - 6 minutes)
echo_info "=== Step 2 of 7: Creating Issuer for Let's Encrypt ==="
echo_info "Estimated time: 30 seconds - 6 minutes"

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

  echo_info "Waiting for Issuer to be ready (up to 6 minutes)..."
  kubectl wait --namespace opengovernance \
    --for=condition=Ready issuer/letsencrypt-nginx \
    --timeout=360s
fi

echo_info "Step 2 completed. 5 steps remaining."

# Step 3 (of 7): Installing NGINX Ingress Controller (ETA: 2-3 minutes)
echo_info "=== Step 3 of 7: Installing NGINX Ingress Controller ==="
echo_info "Estimated time: 2-3 minutes"

if helm list -n opengovernance | grep ingress-nginx > /dev/null 2>&1; then
  echo_info "NGINX Ingress Controller is already installed. Skipping installation."
else
  echo_info "NGINX Ingress Controller not found. Installing Ingress Controller."

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

echo_info "Waiting for Ingress Controller to obtain an external IP (up to 4 minutes)..."
START_TIME=$(date +%s)
TIMEOUT=240
while true; do
  INGRESS_EXTERNAL_IP=$(kubectl get svc ingress-nginx-controller -n opengovernance -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
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

echo_info "Step 3 completed. 4 steps remaining."

# Step 4 (of 7): Retrieving Ingress Controller External IP (ETA: 20 seconds)
echo_info "=== Step 4 of 7: Retrieving Ingress Controller External IP ==="
echo_info "Estimated time: 20 seconds"

if [ -z "$INGRESS_EXTERNAL_IP" ]; then
  echo_info "Retrieving Ingress Controller External IP..."
  INGRESS_EXTERNAL_IP=$(kubectl get svc ingress-nginx-controller -n opengovernance -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  if [ -n "$INGRESS_EXTERNAL_IP" ]; then
    echo "Ingress Controller External IP: $INGRESS_EXTERNAL_IP"
  else
    echo_error "Error: Ingress Controller External IP not found."
    exit 1
  fi
else
  echo "Ingress Controller External IP: $INGRESS_EXTERNAL_IP"
fi

echo_info "Step 4 completed. 3 steps remaining."

echo_info "=== Setup Completed Successfully ==="
echo "CERT-MANAGER and NGINX Ingress Controller are installed and configured."
echo "Email: $EMAIL"
echo "Domain: $DOMAIN"
echo "Ingress Controller External IP: $INGRESS_EXTERNAL_IP"

### Begin deploy-ingress steps

# Step 5 (of 7): Updating OpenGovernance Configuration (ETA: 3-5 minutes)
echo_info "=== Step 5 of 7: Updating OpenGovernance Configuration ==="
echo_info "Estimated time: 3-5 minutes"

helm upgrade opengovernance opengovernance/opengovernance \
  -n opengovernance \
  --reuse-values \
  -f - <<EOF
global:
  domain: ${DOMAIN}
dex:
  config:
    issuer: https://${DOMAIN}/dex
EOF

echo_info "OpenGovernance application configuration updated."

echo_info "Step 5 completed. 2 steps remaining."

# Step 6 (of 7): Deploying Ingress Resources (ETA: 20 seconds)
echo_info "=== Step 6 of 7: Deploying Ingress Resources ==="
echo_info "Estimated time: 20 seconds"

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

echo_info "Ingress resource deployed."

echo_info "Step 6 completed. 1 step remaining."

# Step 7 (of 7): Restarting Relevant Pods (ETA: 20 seconds)
echo_info "=== Step 7 of 7: Restarting Relevant Pods ==="
echo_info "Estimated time: 20 seconds"

kubectl delete pods -l app=nginx-proxy -n opengovernance
kubectl delete pods -l app.kubernetes.io/name=dex -n opengovernance

echo_info "Relevant pods have been restarted."

echo_info "=== Setup Completed Successfully ==="
echo "Please allow a few minutes for the changes to propagate and for services to become fully operational."

echo_info "Next Steps:"
echo "1. Create a DNS A record pointing your domain to the Ingress Controller's external IP."
echo "   - Type: A"
echo "   - Name (Key): ${DOMAIN}"
echo "   - Value: ${INGRESS_EXTERNAL_IP}"
echo "2. After the DNS changes take effect, Open your web browser and navigate to https://${DOMAIN}."
echo "   - To sign in, use 'admin@opengovernance.io' as the username and 'password' as the password."
