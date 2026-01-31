# Quick Start Guide - 15 Minutes to Deployment

This guide will get you from zero to a running LiteLLM proxy in AWS in about 15-45 minutes (depending on stack creation times).

## Prerequisites Checklist

Before you begin, gather these items:

- [ ] AWS Account ID: `____________`
- [ ] AWS Access Key ID: `____________________`
- [ ] AWS Secret Access Key: `____________________`
- [ ] AWS Region (default: us-east-1): `____________`
- [ ] OpenAI API Key (starts with sk-proj-): `____________________` OR
- [ ] Anthropic API Key (starts with sk-ant-): `____________________`
- [ ] Azure DevOps Organization name: `____________`
- [ ] Azure DevOps Project name: `____________`

---

## Step 1: Setup Azure DevOps (5 minutes)

### 1.1 Upload Code to Azure DevOps

```bash
# Navigate to the package directory
cd ADO_LiteLLM_AWS

# Initialize git
git init
git add .
git commit -m "Initial commit - LiteLLM AWS deployment"

# Add Azure DevOps remote (replace YOUR_ORG and YOUR_PROJECT)
git remote add origin https://dev.azure.com/YOUR_ORG/YOUR_PROJECT/_git/litellm-aws

# Push to Azure DevOps
git push -u origin master
```

### 1.2 Create AWS Service Connection

1. In Azure DevOps, go to **Project Settings** (bottom left)
2. Click **Service connections** (under Pipelines)
3. Click **New service connection**
4. Select **AWS** → **Next**
5. Fill in:
   - **Connection name:** `aws-litellm-connection` (EXACT NAME)
   - **Access Key ID:** Your AWS access key
   - **Secret Access Key:** Your AWS secret key
6. Click **Verify and save**

### 1.3 Create Variable Group: litellm-aws-config

1. Go to **Pipelines** → **Library**
2. Click **+ Variable group**
3. Name: `litellm-aws-config`
4. Add variables:
   - **AWS_ACCOUNT_ID** = Your 12-digit AWS account ID
   - **AWS_REGION** = `us-east-1` (or your region)
5. Click **Save**

### 1.4 Create Variable Group: litellm-aws-secrets

1. Go to **Pipelines** → **Library**
2. Click **+ Variable group**
3. Name: `litellm-aws-secrets`
4. Add at least ONE API key:
   - **OPENAI_API_KEY** = Your OpenAI key → Click 🔒 to make secret
   - **ANTHROPIC_API_KEY** = Your Anthropic key → Click 🔒 to make secret
   - **AWS_BEDROCK_REGION** = `us-east-1` (optional, if using Bedrock)
5. Click **Save**

---

## Step 2: Create Pipelines (5 minutes)

Create pipelines for all YAML files:

1. Go to **Pipelines** → **Pipelines**
2. Click **New pipeline**
3. Select **Azure Repos Git**
4. Select your repository (litellm-aws)
5. Choose **Existing Azure Pipelines YAML file**
6. Select `azure-pipelines-security.yml`
7. Click **Save** (don't run yet)
8. Rename pipeline to "Deploy Security Stack"

Repeat for all pipeline files:
- `azure-pipelines-security.yml` → "Deploy Security Stack"
- `azure-pipelines-network.yml` → "Deploy Network Stack"
- `azure-pipelines-alb.yml` → "Deploy ALB Stack"
- `azure-pipelines-database.yml` → "Deploy Database Stack"
- `azure-pipelines-litellm.yml` → "Deploy LiteLLM Stack"
- `azure-pipelines-teardown.yml` → "Teardown Infrastructure"

---

## Step 3: Deploy Infrastructure (30-40 minutes total)

Run pipelines in this exact order:

### 3.1 Deploy Security Stack (~5 min)

1. Go to **Pipelines** → **Deploy Security Stack**
2. Click **Run pipeline**
3. Parameters (use defaults):
   - environment: `dev`
   - rotationDays: `30`
   - awsRegion: `us-east-1`
4. Click **Run**
5. Wait for completion ✅

**What it creates:** KMS keys, Secrets Manager, IAM roles

### 3.2 Deploy Network Stack (~3 min)

1. Go to **Pipelines** → **Deploy Network Stack**
2. Click **Run pipeline**
3. Parameters:
   - environment: `dev`
   - enableNatGateway: `true` (needed for ECS tasks to pull Docker images)
   - enableMultiAz: `false` (dev), `true` (prod)
4. Click **Run**
5. Wait for completion ✅

**What it creates:** VPC, subnets, NAT Gateway, security groups

### 3.3 Deploy ALB Stack (~5 min)

1. Go to **Pipelines** → **Deploy ALB Stack**
2. Click **Run pipeline**
3. Parameters for HTTP-only (dev):
   - environment: `dev`
   - domainName: ` ` (single space - keep default)
   - hostedZoneId: ` ` (single space - keep default)
   - enableWaf: `false`
4. Click **Run**
5. Wait for completion ✅

**What it creates:** Application Load Balancer, target group

### 3.4 Deploy Database Stack (~10-15 min)

1. Go to **Pipelines** → **Deploy Database Stack**
2. Click **Run pipeline**
3. Parameters (use defaults):
   - environment: `dev`
   - dbInstanceClass: `db.t3.micro`
   - allocatedStorage: `20`
   - enableMultiAz: `false`
4. Click **Run**
5. Wait for completion ✅ (this one takes longest)

**What it creates:** RDS PostgreSQL database (password auto-generated)

### 3.5 Deploy LiteLLM Stack (~10 min)

1. Go to **Pipelines** → **Deploy LiteLLM Stack**
2. Click **Run pipeline**
3. Parameters (use defaults):
   - environment: `dev`
   - containerCpu: `512`
   - containerMemory: `1024`
   - desiredCount: `1`
4. Click **Run**
5. Wait for completion ✅

**What it creates:** ECR repository, Docker image, ECS cluster, ECS service

---

## Step 4: Test Your Deployment (2 minutes)

### 4.1 Get ALB Endpoint

The LiteLLM pipeline output shows the ALB endpoint URL. Or get it with:

```bash
aws cloudformation describe-stacks \
  --stack-name dev-alb-stack \
  --query 'Stacks[0].Outputs[?OutputKey==`ALBEndpoint`].OutputValue' \
  --output text
```

### 4.2 Test Health Endpoint

```bash
# Health check (should return OK)
curl http://YOUR-ALB-ENDPOINT/health
```

### 4.3 Test LiteLLM API

```bash
# Test chat completion
curl http://YOUR-ALB-ENDPOINT/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer sk-1234" \
  -d '{
    "model": "gpt-3.5-turbo",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

**Success!** You should get a response from OpenAI via your LiteLLM proxy.

---

## Step 5: Monitor Your Deployment

### Check AWS Resources

```bash
# Run monitoring script
./scripts/monitor-aws-resources.sh dev us-east-1
```

### Check Azure DevOps Pipelines

```bash
# Set your Azure DevOps PAT
export AZURE_DEVOPS_EXT_PAT=your-pat-token

# Run monitoring script
./scripts/monitor-ado-pipelines.sh YOUR_ORG YOUR_PROJECT
```

### View CloudWatch Logs

```bash
# Tail ECS task logs
aws logs tail /aws/ecs/dev-litellm-service --follow
```

---

## Troubleshooting

### Pipeline Fails: "Service connection 'aws-litellm-connection' not found"

**Solution:** Create the AWS service connection with **exact name** `aws-litellm-connection`

### Pipeline Fails: "Variable group not found"

**Solution:** Create variable groups `litellm-aws-config` and `litellm-aws-secrets` with correct names

### Pipeline Fails: "Required stack not found"

**Solution:** Deploy stacks in order (security → network → ALB → database → litellm)

### ECS Tasks Keep Restarting

**Solution:** Check logs for errors:
```bash
aws logs tail /aws/ecs/dev-litellm-service --follow
```

Common issues:
- Invalid API keys (check variable group secrets)
- Database connection failed (check security groups)
- Out of memory (increase containerMemory parameter)

### ALB Health Checks Failing

**Solution:** Check:
- Security group allows ALB → ECS traffic
- ECS tasks are running
- Container started successfully (check logs)

---

## Cleanup (When Done Testing)

To delete everything and stop charges:

1. Go to **Pipelines** → **Teardown Infrastructure**
2. Click **Run pipeline**
3. Parameters:
   - environment: `dev`
   - stack: `all`
   - confirmation: Type `DELETE` (required)
4. Click **Run**
5. Wait ~10-15 minutes for complete teardown

This deletes ALL resources and stops all charges.

---

## Next Steps

### For Production Deployment

1. Change environment to `prod`
2. Enable Multi-AZ for RDS and network
3. Enable WAF for ALB
4. Use custom domain with HTTPS
5. Increase ECS task count (2-4 minimum)
6. Enable auto-scaling
7. Set up CloudWatch alarms
8. Enable deletion protection for RDS

### Cost Optimization

- Disable NAT Gateway for dev (set `enableNatGateway: false`)
- Stop environment when not in use (scale ECS to 0)
- Use smaller RDS instance for dev
- Delete old CloudWatch logs

### Monitoring

- Set up CloudWatch alarms for:
  - ECS task failures
  - ALB 5XX errors
  - RDS CPU/storage
  - High costs
- Enable AWS GuardDuty for security monitoring
- Review CloudTrail logs regularly

---

## Support

- **CloudFormation Issues:** Check stack events in AWS Console
- **Pipeline Issues:** Check pipeline logs in Azure DevOps
- **LiteLLM Issues:** Check ECS task logs in CloudWatch
- **AWS Costs:** Review in AWS Cost Explorer with Environment=dev filter

---

## Summary

You now have:

✅ Fully deployed LiteLLM proxy in AWS
✅ Auto-scaling ECS cluster
✅ PostgreSQL RDS database
✅ Application Load Balancer
✅ Secure secrets management
✅ Comprehensive monitoring

**Total deployment time:** ~45 minutes
**Monthly cost (dev):** ~$80/month

Enjoy your LiteLLM proxy!
