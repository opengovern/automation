# Standard Operating Procedure (SOP): Setting Up Azure Subscription Integration for OpenGovernance

## Overview

This document outlines the steps required to integrate your Azure subscriptions with OpenGovernance by creating a Service Principal with read-only access. This integration enables OpenGovernance to provide visibility and governance capabilities over your Azure resources.

## Prerequisites

Before you begin, ensure the following prerequisites are met:

- **Azure CLI**: Installed and authenticated on your machine.
  - Install Azure CLI: [Azure CLI Installation Guide](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli)
  - Authenticate: Run `az login` and follow the prompts.
- **OpenGovernance**: Installed and running.
  - Refer to the OpenGovernance installation documentation if needed.

## Steps

### 1. Clone the Integration Scripts Repository

The integration scripts automate the creation of the Service Principal and role assignment.

```bash
# Clone the repository
git clone https://github.com/opengovern/integration-automation-scripts.git

# Navigate to the Azure directory
cd integration-automation-scripts/azure-subscriptions
```

### 2. Run the Reader Role Assignment Script

Execute the script to create a Service Principal (SPN) and assign it the 'Reader' role across all your Azure subscriptions.

```bash
# Make the script executable (if not already)
chmod +x assign_reader_role.sh

# Run the script
./assign_reader_role.sh
```

#### **Script Details**

- **Purpose**: Automates the creation of a Service Principal and assigns the 'Reader' role to it for all subscriptions.
- **Actions Performed**:
  - Creates a Service Principal named `OpenGovernanceSPN-Subscriptions`.
  - Assigns the 'Reader' role across all subscriptions in your Azure account.

### 3. Review and Record the Output

After running the script, it will output essential details required for configuring OpenGovernance:

- **Tenant ID**
- **Application (Client) ID**
- **Object ID**
- **Client Secret**

**Example Output**:

```plaintext
Tenant ID:             87654321-4321-4321-4321-0987654321ba
Application (Client) ID: 12345678-1234-1234-1234-1234567890ab
Object ID:             abcdef12-3456-7890-abcd-ef1234567890
Client Secret:         your-client-secret
```

> **Important**: Securely record the **Client Secret** immediately. This value cannot be retrieved later. Store all credentials in a secure location.

### 4. Configure OpenGovernance

Use the credentials obtained to configure Azure integration within OpenGovernance.

#### **Steps**:

1. **Access the OpenGovernance Portal**:

   - Open your web browser and navigate to the OpenGovernance portal.
   - Log in with your administrator credentials.

2. **Navigate to Integrations**:

   - From the dashboard, select **Integrations** from the main menu.
   - Choose **Azure Integration** from the list of available integrations.

3. **Enter the Required Details**:

   - **Tenant ID**: Enter the `Tenant ID` from the script output.
   - **Application (Client) ID**: Enter the `Application (Client) ID`.
   - **Object ID**: Enter the `Object ID`.
   - **Client Secret**: Enter the `Client Secret`.

4. **Complete the Integration Setup**:

   - Review the entered details for accuracy.
   - Click **Validate** to test the connection.
   - Upon successful validation, click **Save** to complete the integration.

### 5. Verify Integration (Optional)

Confirm that OpenGovernance has successfully integrated with your Azure subscriptions.

- **Check Resource Visibility**:

  - Go to the **Resources** or **Dashboard** section in OpenGovernance.
  - Verify that your Azure resources are listed and accessible.

- **Confirm Read-Only Access**:

  - Attempt to perform read operations (e.g., viewing resource details).
  - Ensure that write operations are not permitted, maintaining read-only access.

## Conclusion

You have successfully integrated your Azure subscriptions with OpenGovernance. The Service Principal created has read-only access, enabling OpenGovernance to provide insights and governance capabilities over your Azure environment.
