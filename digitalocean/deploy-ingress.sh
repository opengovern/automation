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

# Step 2: Verify DNS A Record
echo_info "=== Verifying DNS A Record for ${DOMAIN} ==="

# Attempt to resolve the domain using 'getent'
DNS_IPS=$(getent hosts "$DOMAIN" | awk '{ print $1 }')

if [ -z "$DNS_IPS" ]; then
  echo_error "Warning: No DNS A record found for ${DOMAIN}. Proceeding without DNS verification."
else
  # Check if any of the DNS A records match the Ingress External IP
  DNS_MATCH=false
  for ip in $DNS_IPS; do
    if [ "$ip" == "$INGRESS_EXTERNAL_IP" ]; then
      DNS_MATCH=true
      break
    fi
  done

  if [ "$DNS_MATCH" == true ]; then
    echo "DNS A record for ${DOMAIN} is correctly pointing to ${INGRESS_EXTERNAL_IP}."
  else
    echo_error "Warning: DNS A record for ${DOMAIN} does not point to ${INGRESS_EXTERNAL_IP}."
    echo "Current A records:"
    for ip in $DNS_IPS; do
      echo "- $ip"
    done
    echo "Please update your DNS A record to point ${DOMAIN} to ${INGRESS_EXTERNAL_IP}."
    echo "Continuing with the configuration..."
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

echo_info "=== Update Config, Deploy Ingress, and Restart Services Completed Successfully ==="
echo "Please allow a few minutes for the changes to propagate and for services to become fully operational."