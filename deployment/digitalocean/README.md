# Standard Operating Procedure (SOP): Installing OpenGovernance on DigitalOcean Kubernetes

## Overview

This document provides step-by-step instructions to integrate your Azure subscriptions with OpenGovernance by creating a Kubernetes cluster on DigitalOcean, installing the OpenGovernance application, and setting up HTTPS with a custom hostname. Automation scripts are provided to streamline the installation and configuration processes. For advanced users, manual steps are available in the appendix.

## Contents

1. [Prerequisites](#prerequisites)
2. [Clone Deployment Repository](#2-clone-deployment-repository)
3. [Create Kubernetes Cluster](#3-create-kubernetes-cluster)
   - [Using DigitalOcean Web UI](#using-digitalocean-web-ui)
   - [Using DigitalOcean CLI (`doctl`)](#using-digitalocean-cli-doctl)
4. [Install OpenGovernance Application](#4-install-opengovernance-application)
5. [Set Up Hostname and HTTPS](#5-set-up-hostname-and-https)
   - [Execute Automated Scripts](#execute-automated-scripts)
6. [Verification (Optional)](#6-verification-optional)
7. [Conclusion](#7-conclusion)
8. [Appendix](#8-appendix)

---

## Prerequisites

Before you begin, ensure that you have the following:

- **DigitalOcean Account**: Access to create Kubernetes clusters and manage DNS settings.
- **Azure CLI**: Installed and authenticated on your machine.
  - **Installation Guide**: [Azure CLI Installation](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli)
- **DigitalOcean CLI (`doctl`)**: Installed on your local machine.
  - **Installation Guide**: [Install doctl](https://docs.digitalocean.com/reference/doctl/how-to/install/)
- **Helm**: Installed for managing Kubernetes applications.
  - **Installation Guide**: [Helm Installation](https://helm.sh/docs/intro/install/)
- **kubectl**: Installed and configured.
  - **Installation Guide**: [kubectl Installation](https://kubernetes.io/docs/tasks/tools/install-kubectl/)
- **Domain Name**: Access to modify DNS records for your domain.
- **Git**: Installed for cloning repositories.
  - **Installation Guide**: [Git Installation](https://git-scm.com/book/en/v2/Getting-Started-Installing-Git)

---

## 2. Clone Deployment Repository

Clone the repository containing the automation scripts for setting up OpenGovernance.

```bash
# Clone the repository
git clone https://github.com/opengovern/deploy-opengovernance.git

# Navigate to the DigitalOcean scripts directory
cd deploy-opengovernance/digitalocean
```

---

## 3. Create Kubernetes Cluster

You can create a Kubernetes cluster on DigitalOcean using either the **Web Interface** or the **DigitalOcean CLI (`doctl`)**. Follow the instructions for your preferred method.

### Using DigitalOcean Web UI

1. **Navigate to Kubernetes**:
   - Log in to your DigitalOcean account.
   - Go to the **Kubernetes** section from the main dashboard.

2. **Create Cluster**:
   - Click on **Create Cluster**.

3. **Configure a Single Node Pool**:
   - **Type**: Dedicated CPUs (General Purpose - Premium Intel, 10 Gbps)
   - **Nodes**: `3`
   - **Specs per Node**:
     - **vCPU**: `4`
     - **Memory**: `16GB RAM`
     - **Storage**: `60GB SSD`
     - **Instance Type**: `g-4vcpu-16gb-intel`

4. **Create the Cluster**:
   - Review your settings.
   - Click **Create Cluster**.
   - The cluster creation process will begin and may take several minutes.
   - Once completed, navigate to the cluster details to access the Kubernetes dashboard and connection details.

### Using DigitalOcean CLI (`doctl`)

1. **Install `doctl`**:
   - Follow the [DigitalOcean CLI Installation Guide](https://docs.digitalocean.com/reference/doctl/how-to/install/) if you haven't installed it yet.

2. **Authenticate `doctl`**:
   ```bash
   doctl auth init
   ```
   - Follow the prompts to authenticate with your DigitalOcean account.

3. **Create the Kubernetes Cluster**:
   ```bash
   doctl kubernetes cluster create opengovernance \
     --region nyc3 \
     --node-pool "name=main-pool;size=g-4vcpu-16gb-intel;count=3" \
     --wait
   ```
   - **Parameters**:
     - **Cluster Name**: `opengovernance`
     - **Region**: `nyc3` (New York City 3)
     - **Node Pool Configuration**:
       - **Name**: `main-pool`
       - **Size**: `g-4vcpu-16gb-intel`
       - **Count**: `3`

4. **Configure `kubectl` to Use the Cluster**:
   ```bash
   doctl kubernetes cluster kubeconfig save opengovernance
   ```
   - This command configures your local `kubectl` to communicate with the newly created cluster.

5. **Verify the Cluster Connection**:
   ```bash
   kubectl get nodes
   ```
   - **Expected Output**:
     ```
     NAME                                         STATUS   ROLES    AGE   VERSION
     opengovernance-main-pool-xxxxxxxx-xxxx       Ready    <none>   5m    v1.30.1-do.0
     opengovernance-main-pool-xxxxxxxx-xxxx       Ready    <none>   5m    v1.30.1-do.0
     opengovernance-main-pool-xxxxxxxx-xxxx       Ready    <none>   5m    v1.30.1-do.0
     ```

---

## 4. Install OpenGovernance Application

1. **Add the OpenGovernance Helm Repository and Update Helm**:
   ```bash
   helm repo add opengovernance https://opengovern.github.io/charts
   helm repo update
   ```

2. **Deploy the OpenGovernance App**:
   ```bash
   helm install -n opengovernance opengovernance opengovernance/opengovernance \
     --create-namespace \
     --timeout=10m
   ```
   - **Parameters**:
     - **Namespace**: `opengovernance` (created if it doesn't exist)
     - **Release Name**: `opengovernance`
     - **Chart**: `opengovernance/opengovernance`

---

## 5. Set Up Hostname and HTTPS

To streamline the configuration and ensure consistency, we'll utilize automation scripts to handle the setup of cert-manager and the Ingress Controller, as well as updating the application configuration and deploying Ingress resources.

### Execute Automated Scripts

1. **Navigate to the Scripts Directory**:
   ```bash
   cd deploy-opengovernance/digitalocean
   ```

2. **Make Scripts Executable**:
   ```bash
   chmod +x setup-ingress.sh
   chmod +x deploy-ingress.sh
   ```

3. **Set Environment Variables**:
   
   Before running the scripts, set the required environment variables for your email and domain.

   ```bash
   export EMAIL="your-email@example.com"
   export DOMAIN="demo.opengovernance.io"
   ```
   
   > **🔺 Note**:
   >
   > - Replace `your-email@example.com` with your actual email address. This email is used for registering with Let's Encrypt.
   > - Replace `demo.opengovernance.io` with your actual domain name.

4. **Run the Setup Ingress Script**:
   
   This script installs and configures cert-manager and the NGINX Ingress Controller.

   ```bash
   ./setup-ingress.sh
   ```
   
   - **Actions Performed**:
     - Installs cert-manager using Helm.
     - Creates an Issuer for Let's Encrypt.
     - Installs the NGINX Ingress Controller using Helm.
     - Waits for the Ingress Controller to obtain an external IP address.

5. **Run the Deploy Ingress Script**:
   
   This script updates the OpenGovernance application configuration, deploys the Ingress resource, and restarts relevant services. It also checks for the existence and correctness of the DNS A record.

   ```bash
   ./deploy-ingress.sh
   ```
   
   - **Actions Performed**:
     - Retrieves the External IP of the NGINX Ingress Controller.
     - Attempts to verify that the DNS A record for your domain exists and points to the correct External IP.
     - Updates the OpenGovernance Helm release with the specified domain configurations.
     - Deploys the Ingress resource with TLS configurations.
     - Restarts relevant pods (`nginx-proxy` and `dex`) to apply the changes.

---

## 6. Verification (Optional)

After completing the installation and configuration, it's good practice to verify that everything is working as expected.

### Check Resource Visibility

1. **Access OpenGovernance Portal**:
   - Open your web browser and navigate to `https://${DOMAIN}`.
   - Log in with your administrator credentials.

2. **Verify Resources**:
   - Navigate to the **Resources** or **Dashboard** section.
   - Ensure that your Azure resources are listed and accessible.

### Confirm HTTPS and Custom Domain

1. **Check HTTPS**:
   - Ensure that the website is accessible over HTTPS without any certificate warnings.

2. **Verify DNS Propagation**:
   - Use [DNS Checker](https://dnschecker.org/) to confirm that your domain (`${DOMAIN}`) correctly points to the NGINX Ingress Controller's external IP.

### Test Read-Only Access

1. **Attempt Write Operations**:
   - Try performing a write operation to ensure that only read operations are permitted.
   - Confirm that OpenGovernance has the intended read-only access to your Azure subscriptions.

---

## 7. Conclusion

You have successfully set up OpenGovernance on a DigitalOcean Kubernetes cluster with HTTPS and a custom hostname using automation scripts. This deployment ensures secure, read-only access to your Azure subscriptions, enabling robust visibility and governance capabilities.

---

## Appendix

### Manual Steps (Optional)

For users who prefer to perform configurations manually or need to adjust specific settings, the following steps are available. These steps have been automated in the provided scripts but can be executed individually if required.

#### 1. Manually Configure cert-manager

1. **Set the Email for ACME Registration**:
   ```bash
   export EMAIL="your-email@example.com"
   ```
   > **🔺 Note**: Replace `your-email@example.com` with your actual email address.

2. **Install cert-manager Using Helm**:
   ```bash
   helm repo add jetstack https://charts.jetstack.io
   helm repo update

   helm install cert-manager jetstack/cert-manager \
     --namespace cert-manager \
     --create-namespace \
     --set crds.enabled=true \
     --set prometheus.enabled=false
   ```

3. **Create and Apply the Issuer Manifest**:
   ```bash
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
   ```

4. **Verify the Issuer is Ready**:
   ```bash
   kubectl get issuer -n opengovernance
   ```
   - **Expected Output**:
     ```
     NAME               READY   AGE
     letsencrypt-nginx  True    2m
     ```
   > **Note**: It may take a few minutes for the Issuer to transition to the **Ready** state. If it’s not ready initially, re-run the command after a few moments.

#### 2. Manually Install Ingress Controller

1. **Add the NGINX Ingress Controller Helm Repository and Update**:
   ```bash
   helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
   helm repo update
   ```

2. **Install the NGINX Ingress Controller**:
   ```bash
   helm install ingress-nginx ingress-nginx/ingress-nginx \
     --namespace opengovernance \
     --create-namespace \
     --set controller.replicaCount=2 \
     --set controller.resources.requests.cpu=100m \
     --set controller.resources.requests.memory=90Mi
   ```

3. **Monitor the Load Balancer IP**:
   ```bash
   kubectl get service --namespace opengovernance ingress-nginx-controller --output wide --watch
   ```
   - Wait until the `EXTERNAL-IP` field is populated with an IP address.

#### 3. Manually Create DNS Records

1. **Create an A Record for Your Domain**:
   - **Example**: If your domain is `demo.opengovernance.io`, create an A record pointing to the Ingress Controller's external IP.
   - **Details**:
     - **Type**: `A`
     - **Name**: `demo.opengovernance.io`
     - **Value**: `<EXTERNAL-IP>` of the NGINX Ingress Controller

   > **🔺 Note**: Replace `demo.opengovernance.io` with your actual domain name. Use tools like [DNS Checker](https://dnschecker.org/) to verify DNS propagation.

#### 4. Manually Update App Configuration

1. **Set Your Domain Name as an Environment Variable**:
   ```bash
   export DOMAIN="demo.opengovernance.io"
   ```
   > **🔺 Note**: Replace `demo.opengovernance.io` with your actual domain name.

2. **Apply Configuration Changes to the Cluster**:
   ```bash
   helm upgrade opengovernance opengovernance/opengovernance -n opengovernance -f <(cat <<EOF
   global:
     domain: ${DOMAIN}
   dex:
     config:
       issuer: https://${DOMAIN}/dex
   EOF
   )
   ```
   - **Explanation**:
     - **Global Domain**: Sets the global domain for OpenGovernance.
     - **DEX Issuer**: Configures the OAuth issuer URL.

   > **Note**: HTTPS is enforced through this configuration. Ensure that the domain name is correctly set to enable TLS.

#### 5. Manually Deploy Ingress

1. **Create and Apply the Ingress Manifest**:
   ```bash
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
   ```

#### 6. Manually Restart Services

1. **Verify the Ingress Resource**:
   ```bash
   kubectl get ingress -n opengovernance
   ```
   - **Expected Output**:
     ```
     NAME                      CLASS    HOSTS                   ADDRESS        PORTS   AGE
     opengovernance-ingress    <none>   demo.opengovernance.io   192.0.2.123    80      5m
     ```

2. **Restart Relevant Pods to Apply Changes**:
   ```bash
   kubectl delete pods -l app=nginx-proxy -n opengovernance
   kubectl delete pods -l app.kubernetes.io/name=dex -n opengovernance
   ```
   - Kubernetes will automatically recreate the deleted pods with the updated configurations.

---

### Troubleshooting

- **Ingress Not Accessible**:
  - Verify that the DNS A record points correctly to the Ingress Controller's external IP.
  - Ensure that the Ingress resource is correctly configured with the appropriate host and paths.

- **Certificate Issues**:
  - Check the status of cert-manager Issuer:
    ```bash
    kubectl describe issuer letsencrypt-nginx -n opengovernance
    ```
  - Ensure that the `EMAIL` environment variable is correctly set and that Let's Encrypt can reach your Ingress.

- **Pod Failures**:
  - Inspect pod logs for any errors:
    ```bash
    kubectl logs <pod-name> -n opengovernance
    ```
  - Ensure that all required services are running and properly configured.

- **Helm Deployment Issues**:
  - Verify Helm release status:
    ```bash
    helm list -n opengovernance
    helm status opengovernance -n opengovernance
    ```
  - Reinstall or upgrade Helm charts as necessary.

---

### Useful Commands

- **List All Namespaces**:
  ```bash
  kubectl get namespaces
  ```
  
- **List All Services in a Namespace**:
  ```bash
  kubectl get services -n opengovernance
  ```
  
- **Watch Pod Status**:
  ```bash
  kubectl get pods -n opengovernance --watch
  ```

---

### References

- **DigitalOcean Kubernetes Documentation**: [DigitalOcean Kubernetes](https://docs.digitalocean.com/products/kubernetes/)
- **Helm Documentation**: [Helm](https://helm.sh/docs/)
- **cert-manager Documentation**: [cert-manager](https://cert-manager.io/docs/)
- **OpenGovernance Documentation**: Refer to the official [OpenGovernance Documentation](https://opengovern.github.io/) for more details on configurations and integrations.
- **GitHub Repository for Deployment Scripts**: [deploy-opengovernance](https://github.com/opengovern/deploy-opengovernance.git)

---

**Note**: Always adhere to your organization's security policies when handling credentials and configuring access. Ensure that all sensitive information is stored securely and that only authorized personnel have access to critical configurations.