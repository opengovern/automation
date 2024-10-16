# DigitalOcean Deployment Guide

## Overview

This guide assists in creating a Kubernetes cluster, installing the Opengovernance application, setting up HTTPS, and establishing a custom hostname on DigitalOcean Kubernetes.

## Contents 

1. [Create Kubernetes Cluster](#1-create-kubernetes-cluster)
   - [Using DigitalOcean Web Interface](#using-digitalocean-web-interface)
   - [Using DigitalOcean CLI](#using-digitalocean-cli)
2. [Install App](#2-install-app)
   - [Adding the Helm Repository](#adding-the-helm-repository)
   - [Installing the Opengovernance App](#installing-the-opengovernance-app)
3. [Setup HTTPS and DNS](#3-setup-https-and-dns)
   - [Configuring `cert-manager`](#configuring-cert-manager)
   - [Installing NGINX Ingress Controller](#installing-nginx-ingress-controller)
   - [Update DNS Record](#update-dns-record)
   - [Update the Application Configuration](#update-the-application-configuration)
   - [Deploying the Ingress](#deploying-the-ingress)
4. [Verification](#verification)

## 1. Create Kubernetes Cluster

You can create a Kubernetes cluster on DigitalOcean using either the Web Interface or the DigitalOcean CLI.

### Using DigitalOcean Web Interface

1. **Navigate to Kubernetes > Create Cluster.**

2. **Configure a Single Node Pool:**

   - **Type:** Dedicated CPUs (General Purpose - Premium Intel, 10 Gbps)
   - **Nodes:** 3
   - **Specs per Node:**
     - **vCPU:** 4
     - **Memory:** 16GB RAM
     - **Storage:** 60GB SSD
     - **Instance Type:** `g-4vcpu-16gb-intel`

3. **Create the Cluster:**

   - Review the settings and click **Create Cluster**.
   - The cluster creation process will begin and may take several minutes.
   - Once creation is completed, navigate to the cluster details to access the Kubernetes dashboard and connection details.

### Using DigitalOcean CLI

1. **Install DigitalOcean CLI (`doctl`):**

   If you haven't installed `doctl`, follow the [official installation guide](https://docs.digitalocean.com/reference/doctl/how-to/install/).

2. **Authenticate `doctl`:**

   ```bash
   doctl auth init
   ```

   Follow the prompts to authenticate with your DigitalOcean account.

3. **Create the Kubernetes Cluster:**

   ```bash
   doctl kubernetes cluster create opengovernance \
     --region nyc3 \
     --node-pool "name=main-pool;size=g-4vcpu-16gb-intel;count=3" \
     --wait
   ```

   - **Cluster Name:** `opengovernance`
   - **Region:** `nyc3` (New York City 3)
   - **Node Pool Configuration:**
     - **Name:** `main-pool`
     - **Size:** `g-4vcpu-16gb-intel`
     - **Count:** 3

4. **Configure Kubectl to Use the Cluster:**

   ```bash
   doctl kubernetes cluster kubeconfig save opengovernance
   ```

   This command configures your local `kubectl` to communicate with the newly created cluster.

5. **Verify the Cluster Connection:**

   ```bash
   kubectl get nodes
   ```

   You should see a list of the 3 nodes in your cluster.

   ```plaintext
   NAME                                         STATUS   ROLES    AGE   VERSION
   opengovernance-main-pool-xxxxxxxx-xxxx       Ready    <none>   5m    v1.30.1-do.0
   opengovernance-main-pool-xxxxxxxx-xxxx       Ready    <none>   5m    v1.30.1-do.0
   opengovernance-main-pool-xxxxxxxx-xxxx       Ready    <none>   5m    v1.30.1-do.0
   ```

## 2. Install App

### Adding the Helm Repository

Add the Opengovernance Helm repository and update Helm:

```bash
helm repo add opengovernance https://opengovern.github.io/charts && helm repo update
```

### Installing the Opengovernance App

Run the following command to deploy the Opengovernance app inside your namespace:

```bash
helm install -n opengovernance opengovernance opengovernance/opengovernance --create-namespace --timeout=10m
```

It will take approximately 5-10 minutes to complete the installation on most major clouds. If you encounter installation failures, it's likely because some steps took longer than expected. Run the following command to fix any failed steps:

```bash
helm upgrade opengovernance opengovernance/open-governance -n opengovernance
```

## 3. Setup HTTPS and DNS

### Configuring `cert-manager`

Install and configure `cert-manager` for TLS certificates.

1. **Set the Email for ACME Registration**

   Export the `EMAIL` environment variable with your desired email address. This will be used for registering with Let's Encrypt.

   ```bash
   export EMAIL=your-email@example.com
   ```

   **🔺_Note:_** Replace `your-email@example.com` with your actual email address.

2. **Install `cert-manager` using Helm**

   ```bash
   helm repo add jetstack https://charts.jetstack.io && helm repo update
   helm install cert-manager jetstack/cert-manager \
     --namespace cert-manager \
     --create-namespace \
     --set installCRDs=true \
     --set prometheus.enabled=false
   ```

3. **Create and Apply the Issuer Manifest**

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

4. **Verify the Issuer is Ready**

   ```bash
   kubectl get issuer -n opengovernance
   ```

   The output should show the `READY` column as `True`.

### Installing NGINX Ingress Controller

Add the official NGINX Helm repository and update Helm:

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

It may take a few minutes for the load balancer IP to become available. You can monitor the status by running:

```bash
kubectl get service --namespace ingress-nginx ingress-nginx-controller --output wide --watch
```

Look for the IP address provided in the `EXTERNAL-IP` field.

### Update DNS Record

**🛑_Important:_** `demo.opengovernance.io` is a placeholder example. **Replace it with your own custom domain name** where indicated.

In this example, we will use `demo.opengovernance.io` to create the DNS record.

- **Type:** A
- **Name:** `demo.opengovernance.io`
- **Value:** `EXTERNAL-IP` of the NGINX Ingress Controller

> **Example:**
>
> If the `EXTERNAL-IP` is `192.0.2.123`, set the A record as follows:
>
> | Type | Name                  | Value        |
> |------|-----------------------|--------------|
> | A    | demo.opengovernance.io | 192.0.2.123  |

**🔺_Note:_** Ensure that you replace `demo.opengovernance.io` with your actual domain name and set the corresponding A record.

Ensure that the DNS changes have propagated before proceeding. You can use tools like [DNS Checker](https://dnschecker.org/) to verify propagation.

### Update the Application Configuration

**🛑_Important:_** Replace `demo.opengovernance.io` with your actual domain name.

Export the necessary environment variable for the domain name.

```bash
export DOMAIN="demo.opengovernance.io"
```

**🔺 _Note:_** Replace `demo.opengovernance.io` with your actual domain name.

Apply these changes to the cluster using the following command:

```bash
helm upgrade opengovernance opengovernance/open-governance -n opengovernance -f <(cat <<EOF
global:
  domain: ${DOMAIN}
dex:
  config:
    issuer: https://${DOMAIN}/dex
EOF
)
```

> **Note:** HTTPS is enforced through the configuration. Ensure that the domain name is correctly set to enable TLS.

### Deploying the Ingress

Create a Kubernetes manifest `ingress.yaml` to define an ingress. **Replace `demo.opengovernance.io` with your custom domain** if different.

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

**🔺_Note:_** Ensure that you replace `demo.opengovernance.io` with your actual domain name in the `DOMAIN` environment variable before running the above command.

## Verification

After deploying the ingress, verify that it has been successfully created and configured correctly.

```bash
kubectl get ingress -n opengovernance
```

The output should display the ingress resource with the correct configuration, including the assigned IP address and TLS status.

```plaintext
NAME           CLASS    HOSTS                   ADDRESS        PORTS   AGE
kaytu-ingress  <none>   demo.opengovernance.io   192.0.2.123   80      5m
```

Additionally, navigate to `https://demo.opengovernance.io` (replace with your custom domain) in your web browser to confirm that the application is accessible over HTTPS.