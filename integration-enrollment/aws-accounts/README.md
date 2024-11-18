# SOP: Setting Up AWS Organization for OpenGovernance Integration

## Prerequisites
- **AWS CLI Installed and Configured:** Ensure the AWS CLI is installed and configured with administrative privileges.
- **Git Installed:** Make sure Git is installed on your machine.
- **SSH Access:** Confirm you have SSH access to `git@github.com:opengovern/automation-for-aws.git`.
- **Root Organization ID:** Retrieve your AWS Organization's Root ID by running:
  ```sh
  aws organizations list-roots --output=text --query='Roots[0].Id' --no-cli-pager
  ```

## Steps

1. **Clone the Automation Repository**
    ```sh
    git clone git@github.com:opengovern/automation-for-aws.git
    cd automation-for-aws
    ```

2. **Deploy the CloudFormation Stack**
    Replace `<ROOT_ORG_ID>` with your AWS Organization's Root ID obtained from the prerequisites.
    ```sh
    aws cloudformation create-stack \
      --stack-name OpenGovernance-Deploy \
      --template-body file://./AWSOrganizationDeployment.yml \
      --capabilities CAPABILITY_NAMED_IAM \
      --parameters ParameterKey=OrganizationUnitList,ParameterValue=<ROOT_ORG_ID>
    ```

3. **Monitor Stack Deployment**
    Wait until the stack status is `CREATE_COMPLETE`.
    ```sh
    aws cloudformation describe-stacks \
      --stack-name OpenGovernance-Deploy \
      --query "Stacks[0].StackStatus" \
      --output text
    ```

4. **Generate IAM Access Keys for OpenGovernanceIAMUser**
    Retrieve the IAM username from the CloudFormation stack outputs and create access keys.
    ```sh
    IAM_USER=$(aws cloudformation describe-stacks \
      --stack-name OpenGovernance-Deploy \
      --query "Stacks[0].Outputs[?OutputKey=='IAMUserNameInMasterAccount'].OutputValue" \
      --output text)
    
    aws iam create-access-key --user-name $IAM_USER
    ```
    *Store the `AccessKeyId` and `SecretAccessKey` from the output securely.*

5. **Configure OpenGovernance Integration**
    Retrieve the IAM Role name from the CloudFormation stack outputs:
    ```sh
    IAM_ROLE=$(aws cloudformation describe-stacks \
      --stack-name OpenGovernance-Deploy \
      --query "Stacks[0].Outputs[?OutputKey=='IAMRoleName'].OutputValue" \
      --output text)
    ```
    Navigate to the OpenGovernance dashboard:
    - Go to **Integrations** -> **AWS** -> **Add AWS Account**.
    - Enter the following details in the wizard:
      - **AccessKeyID:** *(Use the `AccessKeyId` from Step 4)*
      - **SecretAccessKey:** *(Use the `SecretAccessKey` from Step 4)*
      - **IAM Role Name:** `IAM_ROLE`

## Notes
- **Security:** Store IAM access keys securely and rotate them regularly.
- **Permissions:** The CloudFormation stack automatically creates the `OpenGovernanceIAMUser` and attaches the necessary policies, as well as creates roles in target accounts. Ensure these permissions align with OpenGovernance requirements.
- **Support:** Refer to the [AWS CloudFormation Documentation](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/Welcome.html) for assistance.

---

**Reminder:** Follow your organization's security policies when handling IAM credentials and managing AWS resources.