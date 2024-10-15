# DigitalOcean

## Overview

This guide helps configure access to Opengovernance deployed on DigitalOcean Kubernetes using the NGINX Ingress Controller.

## Contents 

- [Prerequisites](#prerequisites)
- [Step 1: Installing NGINX Ingress Controller](#step-1-installing-nginx-ingress-controller)
- [Step 2: Update DNS Record](#step-2-update-dns-record)
- [Step 3: Configuring TLS Certificate using `cert-manager`](#step-3-configuring-tls-certificate-using-cert-manager)
- [Step 4: Update the Application Configuration](#step-4-update-the-application-configuration)
- [Step 5: Deploying the Ingress](#step-5-deploying-the-ingress)

## Prerequisites

- **Helm** - [Installation guide](https://helm.sh/docs/intro/install/).
- **Kubectl** - [Installation guide](https://kubernetes.io/docs/tasks/tools/)
- **Opengovernance** installed on a DigitalOcean Kubernetes Cluster.
- Access to modify DNS records of a domain.

## Step 1: Installing NGINX Ingress Controller

Add the official NGINX Helm repository and update Helm.

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx && helm repo update
```

Install the NGINX Ingress Controller using Helm:

```bash
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.replicaCount=2 \
  --set controller.resources.requests.cpu=100m \
  --set controller.resources.requests.memory=90Mi
```

It may take a few minutes for the load balancer IP to be available. You can watch the status by running:

```bash
kubectl get service --namespace ingress-nginx ingress-nginx-controller --output wide --watch
```

Look for the IP address provided in the `EXTERNAL-IP` field.

## Step 2: Update DNS Record

Create a DNS record pointing to the `A` value. In this example, we will use `demo.opengovernance.io` to create the DNS record.

## Step 3: Configuring TLS Certificate using `cert-manager`

> **Skip to [Step 4](#step-4-update-the-application-configuration) if you already have `cert-manager` installed.**

First, export the `EMAIL` environment variable with your desired email address. This variable will be used in the Kubernetes manifest.

```bash
export EMAIL=your-email@example.com
```

Replace `your-email@example.com` with your actual email address.

Install `cert-manager` using Helm:

```bash
helm repo add jetstack https://charts.jetstack.io && \
helm repo update && \
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --set prometheus.enabled=false
```

### Create and Apply the Issuer Manifest, Then Verify

```bash
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: letsencrypt-nginx
  namespace: opengovernance
spec:
  acme:
    email: \$EMAIL
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-nginx-private-key
    solvers:
      - http01:
          ingress:
            class: nginx
EOF
```

Verify the issuer is ready:

```bash
kubectl get issuer -n opengovernance
```

The output should be similar to the image below. The field `READY` should be `True`.

## Step 4: Update the Application Configuration

First, export the necessary environment variables for the domain name and HTTPS configuration. By default, `DISABLE_HTTPS` is set to `false`. To disable HTTPS, you can explicitly set `DISABLE_HTTPS=true`.

```bash
export DOMAIN="demo5.opengovernance.io"
export DISABLE_HTTPS=${DISABLE_HTTPS:-false}
```

Apply these changes to the cluster using the following command:

```bash
helm upgrade opengovernance opengovernance/open-governance -n opengovernance -f <(cat <<EOF
global:
  domain: ${DOMAIN}
dex:
  config:
    issuer: $(if [ "$DISABLE_HTTPS" = "true" ]; then echo "http://${DOMAIN}/dex"; else echo "https://${DOMAIN}/dex"; fi)
EOF
)
```

## Step 5: Deploying the Ingress

Create a Kubernetes manifest `ingress.yaml` to define an ingress. Make sure to replace `<your-custom-domain>` with your domain.

```bash
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kaytu-ingress
  namespace: opengovernance
  annotations:
    cert-manager.io/issuer: letsencrypt-nginx
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
```

### Optional Verification Command

After applying the ingress manifest, you may want to verify that the ingress has been successfully created and is configured correctly.

```bash
kubectl get ingress -n opengovernance
```

> **Note:** If you have disabled HTTPS by setting `DISABLE_HTTPS=true`, ensure that the TLS configuration is appropriately adjusted.

## Verification

After deploying the ingress, verify that it has been successfully created and configured correctly.

```bash
kubectl get ingress -n ${OPENGOVERNANCE_NAMESPACE}
```

The output should display the ingress resource with the correct configuration.

---