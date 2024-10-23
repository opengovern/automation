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

# Step 1: Retrieve Ingress Controller External IP
echo_info "=== Retrieving Ingress Controller External IP ==="

INGRESS_EXTERNAL_IP=$(kubectl get svc ingress-nginx-controller -n opengovernance -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

if [ -z "$INGRESS_EXTERNAL_IP" ]; then
  echo_error "Error: Ingress Controller External IP not found. Ensure that the Ingress Controller is properly installed and has an external IP."
  exit 1
fi

echo "Ingress Controller External IP: $INGRESS_EXTERNAL_IP"

# Step 2: Check DNS A Record Existence
echo_info "=== Checking if DNS A Record for ${DOMAIN} Exists ==="

# Attempt to resolve the domain using 'dig' or 'nslookup'
if command -v dig &> /dev/null; then
  DNS_LOOKUP_RESULT=$(dig +short A "$DOMAIN")
elif command -v nslookup &> /dev/null; then
  DNS_LOOKUP_RESULT=$(nslookup -type=A "$DOMAIN" | grep 'Address:' | awk '{ print $2 }' | tail -n +2)
else
  echo_info "DNS tools not found ('dig' or 'nslookup'). Skipping DNS A record check."
  DNS_LOOKUP_RESULT=""
fi

if [ -n "$DNS_LOOKUP_RESULT" ]; then
  echo "DNS A record for ${DOMAIN} exists."
else
  if [ -n "$(command -v dig)" ] || [ -n "$(command -v nslookup)" ]; then
    echo_error "Warning: No DNS A record found for ${DOMAIN}."
    echo "Please ensure that a DNS A record exists for your domain."
    echo "Continuing with the configuration..."
  else
    echo_info "Proceeding without DNS verification as DNS tools are unavailable."
  fi
fi

# Step 3: Update App Configuration using Helm Upgrade
echo_info "=== Updating OpenGovernance Configuration ==="

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

# Step 4: Deploy Ingress Resources
echo_info "=== Deploying Ingress Resources ==="

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

# Step 5: Restart Relevant Pods to Apply Changes
echo_info "=== Restarting Relevant Pods ==="

kubectl delete pods -l app=nginx-proxy -n opengovernance
kubectl delete pods -l app.kubernetes.io/name=dex -n opengovernance

echo_info "Relevant pods have been restarted."

# Final Instructions
echo_info "=== Setup Completed Successfully ==="
echo "Please allow a few minutes for the changes to propagate and for services to become fully operational."

echo_info "Open your web browser and navigate to https://${DOMAIN}. To sign in, use 'admin@opengovernance.io' as the username and 'password' as the password."
