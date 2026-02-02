# LiteLLM AWS Deployment via Azure DevOps

Deploy LiteLLM proxy infrastructure to AWS using Azure DevOps Pipelines. This package provides Infrastructure as Code (CloudFormation) and CI/CD pipelines to deploy a production-ready LiteLLM proxy with:

- **Auto-scaling ECS cluster** running LiteLLM containers
- **PostgreSQL RDS database** with encryption and automatic backups
- **Application Load Balancer** with optional HTTPS/custom domain
- **Secrets Management** with automatic rotation
- **CloudWatch monitoring** and logging
- **Security best practices** (KMS encryption, VPC isolation, IAM roles)

## Architecture

```
GitHub Repository (Source Code)
    ↓
Azure DevOps Pipelines (CI/CD)
    ↓
AWS CloudFormation (Infrastructure)
    ↓
ECS + RDS + ALB + VPC + Security (Deployed Resources)
```

---

## Prerequisites

Before deploying, you must have:

### 1. AWS Account
- Active AWS account with billing enabled
- IAM user with AdministratorAccess (or custom policy with required permissions)
- AWS Access Key ID and Secret Access Key

**How to create IAM user for deployment:**
```bash
# Create IAM user
aws iam create-user --user-name litellm-deployer

# Attach admin policy (use custom policy for production)
aws iam attach-user-policy \
  --user-name litellm-deployer \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess

# Create access key
aws iam create-access-key --user-name litellm-deployer

# Save the output - you'll need AccessKeyId and SecretAccessKey
```

### 2. Azure DevOps Account
- Free or paid Azure DevOps account (https://dev.azure.com)
- Organization created
- Project created

### 3. API Keys (At Least One Required)
You need at least one LLM provider API key:

- **OpenAI:** Get from https://platform.openai.com/api-keys (starts with `sk-proj-...`)
- **Anthropic:** Get from https://console.anthropic.com/settings/keys (starts with `sk-ant-...`)
- **AWS Bedrock:** Configure in AWS Console (uses AWS credentials, no separate key)

### 4. Domain Name (Optional - for HTTPS)
- Custom domain registered (e.g., api.example.com)
- Route53 hosted zone created in AWS
- Hosted Zone ID ready

---

## Quick Start Guide

### Step 1: Upload to Azure DevOps Repos

1. Create a new Git repository in your Azure DevOps project
2. Clone this package to your local machine
3. Initialize git and push to Azure DevOps:

```bash
cd ADO_LiteLLM_AWS
git init
git add .
git commit -m "Initial commit - LiteLLM AWS deployment"
git remote add origin https://dev.azure.com/YOUR_ORG/YOUR_PROJECT/_git/litellm-aws
git push -u origin master
```

### Step 2: Create AWS Service Connection

1. In Azure DevOps, go to **Project Settings** → **Service Connections**
2. Click **New service connection** → **AWS**
3. Fill in the details:
   - **Connection name:** `aws-litellm-connection` (⚠️ EXACT NAME REQUIRED)
   - **Access Key ID:** Your AWS IAM access key
   - **Secret Access Key:** Your AWS IAM secret key
   - **Service connection name:** `aws-litellm-connection`
4. Click **Verify and save**

### Step 3: Create Variable Groups

Create two variable groups with these EXACT names:

#### Variable Group 1: `litellm-aws-config`

1. Go to **Pipelines** → **Library** → **+ Variable group**
2. Name: `litellm-aws-config`
3. Add variables:

| Variable Name | Example Value | Description |
|---------------|---------------|-------------|
| AWS_ACCOUNT_ID | 123456789012 | Your AWS account ID (find in AWS Console top-right) |
| AWS_REGION | us-east-1 | AWS region for deployment (e.g., us-east-1, us-west-2) |

4. Click **Save**

#### Variable Group 2: `litellm-aws-secrets`

1. Go to **Pipelines** → **Library** → **+ Variable group**
2. Name: `litellm-aws-secrets`
3. Add variables (add at least ONE API key):

| Variable Name | Example Value | Description | Lock (Secret) |
|---------------|---------------|-------------|---------------|
| OPENAI_API_KEY | sk-proj-abc123... | OpenAI API key | 🔒 YES |
| ANTHROPIC_API_KEY | sk-ant-abc123... | Anthropic API key | 🔒 YES |
| AWS_BEDROCK_REGION | us-east-1 | Bedrock region (optional) | No |

4. **IMPORTANT:** Click the 🔒 lock icon next to each secret value to mark it as secret
5. Click **Save**

### Step 4: Create Azure Pipelines

Create pipelines for each YAML file:

1. Go to **Pipelines** → **Create Pipeline**
2. Select **Azure Repos Git**
3. Select your repository
4. Choose **Existing Azure Pipelines YAML file**
5. Select the pipeline file (start with `azure-pipelines-security.yml`)
6. Click **Run** (or **Save** if you want to run later)

**Create these pipelines in order:**
1. `azure-pipelines-security.yml` → Name: "Deploy Security Stack"
2. `azure-pipelines-network.yml` → Name: "Deploy Network Stack"
3. `azure-pipelines-alb.yml` → Name: "Deploy ALB Stack"
4. `azure-pipelines-database.yml` → Name: "Deploy Database Stack"
5. `azure-pipelines-litellm.yml` → Name: "Deploy LiteLLM Stack"
6. `azure-pipelines-teardown.yml` → Name: "Teardown Infrastructure" (optional)

### Step 5: Deploy Infrastructure (In Order)

Run pipelines in this specific order:

#### 1. Deploy Security Stack
- Pipeline: `azure-pipelines-security.yml`
- What it creates: KMS keys, Secrets Manager secrets, IAM roles, Lambda functions
- Parameters: Use defaults (environment: dev, rotationDays: 30)
- Time: ~5 minutes

**Secrets created:**
| Secret | Purpose | Rotation |
|--------|---------|----------|
| `{env}/litellm/master-key` | API authentication (48-char key) | Auto (30 days) |
| `{env}/litellm/ui-password` | Admin UI login (separate from API) | Manual |
| `{env}/litellm/api-keys` | External LLM provider keys | Manual |
| `{env}/litellm/database` | PostgreSQL credentials | Auto (30 days) |

#### 2. Deploy Network Stack
- Pipeline: `azure-pipelines-network.yml`
- What it creates: VPC, subnets, NAT Gateway, security groups
- Parameters:
  - `enableNatGateway`: true (for private subnet internet access, ~$32/month)
  - `enableMultiAz`: false (dev), true (production)
- Time: ~3 minutes

#### 3. Deploy ALB Stack
- Pipeline: `azure-pipelines-alb.yml`
- What it creates: Application Load Balancer, target group, listeners
- Parameters for HTTP-only (dev):
  - `domainName`: Leave as single space ` `
  - `hostedZoneId`: Leave as single space ` `
  - `enableWaf`: false
- Parameters for HTTPS (production):
  - `domainName`: Your domain (e.g., api.example.com)
  - `hostedZoneId`: Your Route53 zone ID
  - `enableWaf`: true
- Time: ~5 minutes

#### 4. Deploy Database Stack
- Pipeline: `azure-pipelines-database.yml`
- What it creates: RDS PostgreSQL, DB subnet group, automatic backups
- Parameters: Use defaults (db.t3.micro, 20GB storage)
- **Database credentials:** Auto-generated and stored in AWS Secrets Manager
- Time: ~10-15 minutes (RDS takes time to create)

#### 5. Deploy LiteLLM Stack
- Pipeline: `azure-pipelines-litellm.yml`
- What it creates: ECR repository, ECS cluster, ECS service, Docker image
- Parameters: Use defaults (0.5 vCPU, 1GB RAM, 1 task)
- Time: ~10 minutes (includes Docker build and push)

**Total deployment time: ~35-45 minutes**

---

## Post-Deployment Steps

### 1. Get LiteLLM API Endpoint

After deploying the LiteLLM stack, get the ALB endpoint:

```bash
# Using AWS CLI
aws cloudformation describe-stacks \
  --stack-name dev-alb-stack \
  --query 'Stacks[0].Outputs[?OutputKey==`ALBEndpoint`].OutputValue' \
  --output text
```

Or check the pipeline output - it displays the endpoint URL.

### 2. Test LiteLLM API

Test the deployment:

```bash
# Health check
curl http://YOUR-ALB-ENDPOINT/health

# List models (requires master key from Secrets Manager)
curl http://YOUR-ALB-ENDPOINT/v1/models \
  -H "Authorization: Bearer YOUR_MASTER_KEY"

# Test chat completion
curl http://YOUR-ALB-ENDPOINT/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_MASTER_KEY" \
  -d '{
    "model": "gpt-3.5-turbo",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

### 3. Get API Master Key

The Master Key is required for API authentication:

```bash
# Get the Master Key (for API calls)
aws secretsmanager get-secret-value \
  --secret-id dev/litellm/master-key \
  --query SecretString \
  --output text | jq -r '.LITELLM_MASTER_KEY'
```

### 4. Access Admin UI

LiteLLM includes a web-based Admin UI for managing models, users, and usage.

**URL:** `http://YOUR-ALB-ENDPOINT/ui`

**Get Admin UI credentials:**
```bash
# Get UI username
aws secretsmanager get-secret-value \
  --secret-id dev/litellm/ui-password \
  --query SecretString \
  --output text | jq -r '.UI_USERNAME'

# Get UI password
aws secretsmanager get-secret-value \
  --secret-id dev/litellm/ui-password \
  --query SecretString \
  --output text | jq -r '.UI_PASSWORD'
```

> **Note:** UI credentials are separate from the API Master Key for security. The UI password can be rotated without affecting API clients.

### 5. Get Database Credentials (If Needed)

Database credentials are auto-generated and stored in AWS Secrets Manager:

```bash
# Get database password
aws secretsmanager get-secret-value \
  --secret-id dev/litellm/database \
  --query SecretString \
  --output text | jq -r '.password'

# Get full database connection info
aws secretsmanager get-secret-value \
  --secret-id dev/litellm/database \
  --query SecretString \
  --output text | jq .
```

### 6. Configure Custom Domain (Optional)

If you deployed with a custom domain:

1. ACM certificate is automatically created and validated (may take a few minutes)
2. Create CNAME record in Route53 pointing your domain to the ALB
3. Access LiteLLM via https://your-domain.com

---

## Cost Estimates

Estimated monthly costs for **dev environment** (us-east-1, default parameters):

| Resource | Configuration | Monthly Cost |
|----------|---------------|--------------|
| NAT Gateway | 1 AZ | ~$32 |
| RDS PostgreSQL | db.t3.micro, 20GB | ~$13 |
| ECS Fargate | 1 task, 0.5 vCPU, 1GB | ~$15 |
| ALB | Internet-facing | ~$16 |
| KMS Keys | 2 keys | ~$2 |
| Secrets Manager | 4 secrets | ~$2 |
| CloudWatch Logs | ~5GB/month | ~$3 |
| **Total (dev)** | | **~$82/month** |

**Cost optimization for dev:**
- Disable NAT Gateway (`enableNatGateway: false`) → Saves $32/month
- Use smaller RDS instance (already using smallest)
- Stop environment when not in use (requires manual start/stop)

**Production costs will be higher:**
- Multi-AZ deployments (2x for RDS, ALB across 3 AZs)
- Larger RDS instances (db.t3.medium or higher)
- Multiple ECS tasks with auto-scaling (2-10 tasks)
- WAF enabled (~$5-10/month + rules)
- Higher data transfer costs

---

## Teardown (Delete Infrastructure)

To delete all resources and stop costs:

### Option 1: Teardown Pipeline (Recommended)

1. Run the `azure-pipelines-teardown.yml` pipeline
2. Parameters:
   - `environment`: dev
   - `stack`: all
   - `confirmation`: Type "DELETE" (required)
3. Wait for completion (~10-15 minutes)
4. Pipeline automatically:
   - Scales ECS to 0
   - Deletes all CloudFormation stacks in reverse order
   - Deletes ECR repository
   - Cleans up CloudWatch log groups
   - Generates compliance report

### Option 2: Manual Teardown

If pipeline fails, delete stacks manually in reverse order:

```bash
# 1. Delete LiteLLM stack
aws cloudformation delete-stack --stack-name dev-litellm-stack
aws cloudformation wait stack-delete-complete --stack-name dev-litellm-stack

# 2. Delete Database stack
aws cloudformation delete-stack --stack-name dev-database-stack
aws cloudformation wait stack-delete-complete --stack-name dev-database-stack

# 3. Delete ALB stack
aws cloudformation delete-stack --stack-name dev-alb-stack
aws cloudformation wait stack-delete-complete --stack-name dev-alb-stack

# 4. Delete Network stack
aws cloudformation delete-stack --stack-name dev-network-stack
aws cloudformation wait stack-delete-complete --stack-name dev-network-stack

# 5. Delete Security stack
aws cloudformation delete-stack --stack-name dev-security-stack
aws cloudformation wait stack-delete-complete --stack-name dev-security-stack

# 6. Cleanup orphaned resources
aws ecr delete-repository --repository-name litellm-proxy --force
aws logs delete-log-group --log-group-name /aws/ecs/containerinsights/dev-litellm-cluster/performance
```

---

## File Structure

```
ADO_LiteLLM_AWS/
├── README.md                              # This file
├── QUICK_START.md                         # Fast-track deployment guide
├── TROUBLESHOOTING.md                     # Common issues and solutions
├── TAGGING_STRATEGY.md                    # AWS resource tagging guide
├── .gitignore                             # Git ignore patterns
├── Dockerfile                             # LiteLLM Docker image
├── config.yaml                            # LiteLLM configuration
├── scripts/                               # Operational scripts
│   ├── monitor-aws-resources.sh           # Monitor deployment status
│   ├── monitor-ado-pipelines.sh           # Monitor Azure DevOps pipelines
│   └── teardown-compliance-scan.sh        # Check for orphaned resources
├── azure-devops/                          # Azure DevOps pipelines
│   ├── azure-pipelines-security.yml       # Deploy security infrastructure
│   ├── azure-pipelines-network.yml        # Deploy VPC and networking
│   ├── azure-pipelines-alb.yml            # Deploy load balancer
│   ├── azure-pipelines-database.yml       # Deploy RDS database
│   ├── azure-pipelines-litellm.yml        # Build and deploy LiteLLM
│   ├── azure-pipelines-teardown.yml       # Delete all infrastructure
│   └── templates/                         # Reusable pipeline components
│       ├── aws-cfn-deploy.yml             # CloudFormation deployment template
│       ├── aws-ecr-build.yml              # Docker build and ECR push template
│       └── check-prerequisites.yml         # Stack dependency validation template
└── infrastructure/                        # CloudFormation templates
    ├── security-stack.yaml                # KMS, Secrets Manager, IAM, Lambda
    ├── network-stack.yaml                 # VPC, subnets, security groups
    ├── alb-stack.yaml                     # Application Load Balancer
    ├── database-stack.yaml                # RDS PostgreSQL
    ├── litellm-stack.yaml                 # ECS cluster and service
    └── lambda/                            # (Empty - Lambda code is inline in CloudFormation)
```

---

## Troubleshooting

> **For detailed troubleshooting with debugging commands, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md)**

### "Service connection 'aws-litellm-connection' not found"
**Solution:** Create the AWS service connection with the exact name `aws-litellm-connection`

### "Variable group 'litellm-aws-config' not found"
**Solution:** Create the variable groups as described in Step 3

### "Could not find required stack: dev-security-stack"
**Solution:** Deploy stacks in order. Each stack depends on previous stacks.

### "The security token included in the request is invalid"
**Solution:** AWS credentials expired or invalid. Update the service connection.

### "Access Denied" when deploying CloudFormation
**Solution:** IAM user needs more permissions. Attach AdministratorAccess policy or create custom policy.

### Pipeline fails with "No value was provided for variable 'OPENAI_API_KEY'"
**Solution:** Create the `litellm-aws-secrets` variable group and add at least one API key.

### RDS deployment takes longer than 15 minutes
**Solution:** This is normal. RDS can take 10-20 minutes to create, especially with Multi-AZ enabled.

### ECS tasks fail to start
**Solution:** Check ECS task logs in CloudWatch. Common issues:
- Invalid API keys in variable group
- Docker image build failed
- Insufficient ECS task permissions

### ALB health checks failing
**Solution:** Check:
- Security group allows traffic from ALB to ECS tasks
- ECS tasks are running
- LiteLLM container started successfully (check logs)

---

## Security Best Practices

### 1. Credentials Management
- ✅ **Never commit AWS credentials to Git** (.gitignore is configured)
- ✅ **Use AWS service connections** in Azure DevOps (secrets encrypted)
- ✅ **Mark API keys as secret** in variable groups (click lock icon)
- ✅ **Auto-generated database passwords** stored in Secrets Manager
- ✅ **Enable secret rotation** for production (`enableSecretRotation: true`)

### 2. IAM Best Practices
- Use least privilege IAM policies (instead of AdministratorAccess for production)
- Enable MFA on AWS root account
- Rotate IAM access keys quarterly
- Create separate IAM users for different environments

### 3. Network Security
- ECS tasks run in private subnets (no direct internet access)
- RDS database in private subnets (not publicly accessible)
- Security groups follow least privilege (only required ports open)
- Consider VPC Flow Logs for production

### 4. Data Protection
- All data encrypted at rest (KMS)
- All data encrypted in transit (TLS)
- Automated RDS backups (7-day retention by default)
- Consider enabling RDS deletion protection for production

### 5. Monitoring and Auditing
- Enable AWS CloudTrail for audit logs
- Enable AWS GuardDuty for threat detection
- Set up CloudWatch alarms for critical metrics
- Review CloudWatch logs regularly

---

## Support and Resources

### LiteLLM Documentation
- Website: https://litellm.ai
- GitHub: https://github.com/BerriAI/litellm
- Documentation: https://docs.litellm.ai

### AWS Documentation
- CloudFormation: https://docs.aws.amazon.com/cloudformation/
- ECS: https://docs.aws.amazon.com/ecs/
- RDS: https://docs.aws.amazon.com/rds/

### Azure DevOps Documentation
- Pipelines: https://docs.microsoft.com/en-us/azure/devops/pipelines/
- Service Connections: https://docs.microsoft.com/en-us/azure/devops/pipelines/library/service-endpoints

### Getting Help
- For deployment issues: Check pipeline logs in Azure DevOps
- For AWS issues: Check CloudFormation events in AWS Console
- For LiteLLM issues: Check ECS task logs in CloudWatch

---

## License

This deployment package is provided as-is for deploying LiteLLM infrastructure to AWS.

LiteLLM itself is licensed under the MIT License - see https://github.com/BerriAI/litellm for details.

---

## What You Need to Provide (Checklist)

Before deployment, ensure you have:

- [ ] AWS Account with billing enabled
- [ ] AWS IAM user with AdministratorAccess
- [ ] AWS Access Key ID and Secret Access Key
- [ ] Azure DevOps organization and project created
- [ ] At least ONE LLM provider API key:
  - [ ] OpenAI API key (sk-proj-...), OR
  - [ ] Anthropic API key (sk-ant-...), OR
  - [ ] AWS Bedrock access configured
- [ ] (Optional) Custom domain and Route53 hosted zone for HTTPS

Once you have these, follow the Quick Start Guide above to deploy your LiteLLM infrastructure!
