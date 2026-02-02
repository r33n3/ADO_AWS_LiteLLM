# Troubleshooting Guide

Common issues and solutions for the LiteLLM AWS deployment.

## Deployment Issues

### 1. CloudFormation Template Validation Error: "Invalid Characters"

**Error:**
```
An error occurred (ValidationError) when calling the ValidateTemplate operation: Template contains invalid characters
```

**Cause:** Invisible control characters (e.g., `0x02` STX) in YAML files, often introduced by copy-paste from certain editors.

**Solution:**
```bash
# Find invalid characters
python3 -c "
with open('infrastructure/your-stack.yaml', 'rb') as f:
    content = f.read()
    for i, byte in enumerate(content):
        if byte > 127 or (byte < 32 and byte not in [9, 10, 13]):
            print(f'Position {i}: byte 0x{byte:02x}')
"

# Remove invalid characters
sed -i 's/\x02//g' infrastructure/your-stack.yaml
```

---

### 2. ECS Deployment Circuit Breaker Triggered

**Error:**
```
Error occurred during operation 'ECS Deployment Circuit Breaker was triggered'
```

**Possible Causes:**

#### A. Health Check Failures (Container Not Ready)
LiteLLM takes time to start, especially on first deployment with database migrations.

**Solution:** Increase health check tolerance in `infrastructure/litellm-stack.yaml`:
```yaml
# Target Group settings
HealthCheckTimeoutSeconds: 15      # Increase from 10
UnhealthyThresholdCount: 5         # Increase from 3

# ECS Service settings
HealthCheckGracePeriodSeconds: 600  # 10 minutes grace period
```

#### B. Missing Secret Keys
ECS task fails if secrets reference non-existent keys.

**Error in stopped task:**
```
ResourceInitializationError: unable to pull secrets... did not contain json key UI_USERNAME
```

**Solution:** Verify all secret keys exist:
```bash
# Check secret contents
aws secretsmanager get-secret-value \
  --secret-id "dev/litellm/master-key" \
  --query 'SecretString' --output text | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).keys())"
```

#### C. VPC Connectivity Issues
ECS tasks in private subnets need VPC endpoints to access AWS services.

**Verify endpoints:**
```bash
aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=vpc-xxx" \
  --query 'VpcEndpoints[].{Service:ServiceName,State:State}'
```

Required endpoints: `ecr.api`, `ecr.dkr`, `secretsmanager`, `logs`, `s3`

---

### 3. Azure DevOps Pipeline: "checkout: none not allowed with multiple checkouts"

**Error:**
```
When using multiple checkouts in a job, the 'checkout: none' task is not allowed
```

**Cause:** A job has both `checkout: none` and `checkout: self`.

**Solution:** Remove `checkout: none` from jobs that later use `checkout: self`.

---

### 4. Azure DevOps Pipeline: Artifact Publishing Fails

**Error:**
```
Not found PathtoPublish: /path/to/file-*.md
```

**Cause:** `PublishBuildArtifacts` doesn't support wildcards in `PathtoPublish`.

**Solution:** Copy file to fixed name before publishing:
```yaml
- bash: |
    REPORT_FILE=$(ls -t report-*.md 2>/dev/null | head -1)
    if [ -n "$REPORT_FILE" ]; then
      cp "$REPORT_FILE" report.md
    fi

- task: PublishBuildArtifacts@1
  inputs:
    PathtoPublish: 'report.md'  # Fixed name, no wildcard
```

---

## Teardown Issues

### 1. Orphaned CloudWatch Log Groups

**Issue:** Lambda log groups not deleted during teardown.

**Cause:** Log group pattern only matched `{env}-litellm`, missing `/aws/lambda/{env}-litellm*`.

**Solution:** Extended pattern in teardown pipeline:
```bash
LOG_GROUPS=$(aws logs describe-log-groups \
  --query "logGroups[?contains(logGroupName, '${ENV}-litellm') || contains(logGroupName, '/aws/lambda/${ENV}-litellm')].logGroupName" \
  --output text)
```

### 2. KMS Keys in PendingDeletion State

**Status:** Normal - KMS keys have a mandatory 7-30 day waiting period before deletion.

**No action required** - keys will be automatically deleted after the waiting period.

---

## Debugging Commands

### Check ECS Task Stop Reason
```bash
# List stopped tasks
aws ecs list-tasks --cluster dev-litellm-cluster --desired-status STOPPED

# Get stop reason
aws ecs describe-tasks \
  --cluster dev-litellm-cluster \
  --tasks "arn:aws:ecs:region:account:task/cluster/task-id" \
  --query 'tasks[0].{StopCode:stopCode,Reason:stoppedReason}'
```

### Check CloudWatch Logs
```bash
# List log streams
aws logs describe-log-streams \
  --log-group-name "/ecs/dev-litellm" \
  --order-by LastEventTime --descending --limit 5

# Get recent logs
aws logs get-log-events \
  --log-group-name "/ecs/dev-litellm" \
  --log-stream-name "litellm/litellm-proxy/xxx"
```

### Validate CloudFormation Template
```bash
aws cloudformation validate-template \
  --template-body file://infrastructure/your-stack.yaml
```

### Check Stack Events for Errors
```bash
aws cloudformation describe-stack-events \
  --stack-name dev-litellm-stack \
  --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`].{Resource:LogicalResourceId,Reason:ResourceStatusReason}'
```

---

## Monitoring Scripts

Use the included monitoring scripts for deployment visibility:

```bash
# Monitor AWS resources during deployment
./scripts/monitor-aws-resources.sh dev us-east-1

# Check for orphaned resources after teardown
./scripts/teardown-compliance-scan.sh dev us-east-1

# Monitor Azure DevOps pipelines
./scripts/monitor-ado-pipelines.sh <organization> <project>
```
