# AWS Resource Tagging Strategy

This document describes the tagging strategy used for all AWS resources deployed by this package. Consistent tagging enables easy identification, cost tracking, and automated management of resources.

## Standard Tags Applied to All Resources

All CloudFormation stacks and resources created by this deployment automatically include these tags:

### 1. Core Identification Tags

| Tag Key | Example Value | Description | Purpose |
|---------|---------------|-------------|---------|
| **Environment** | `dev`, `staging`, `prod` | Deployment environment | Cost allocation, resource filtering, access control |
| **Application** | `litellm` | Application name | Identify all resources for this application |
| **ManagedBy** | `CloudFormation` | How resource is managed | Prevent manual modification of IaC resources |
| **Project** | `litellm-proxy` | Project name | Group resources by project |
| **Owner** | `DevTeam`, `email@example.com` | Team or person responsible | Contact for issues or questions |

### 2. Financial Tags

| Tag Key | Example Value | Description | Purpose |
|---------|---------------|-------------|---------|
| **CostCenter** | `engineering`, `operations` | Cost center for billing | Chargeback and budgeting |
| **BillingGroup** | `infrastructure` | Billing category | Group costs by category |

### 3. Compliance and Security Tags

| Tag Key | Example Value | Description | Purpose |
|---------|---------------|-------------|---------|
| **Compliance** | `None`, `HIPAA`, `PCI`, `SOC2`, `GDPR` | Compliance requirements | Identify resources needing special handling |
| **DataClassification** | `Public`, `Internal`, `Confidential`, `Restricted` | Data sensitivity level | Apply appropriate security controls |

### 4. Operational Tags

| Tag Key | Example Value | Description | Purpose |
|---------|---------------|-------------|---------|
| **Stack** | `security`, `network`, `database`, etc. | CloudFormation stack type | Identify resource purpose |
| **Version** | `1.0.0` | Application version | Track deployments |
| **BackupPolicy** | `Daily`, `Weekly`, `None` | Backup frequency | Automated backup management |

---

## Tag Usage in CloudFormation Stacks

### Security Stack Tags
```yaml
Tags:
  - Key: Environment
    Value: !Ref Environment
  - Key: Application
    Value: litellm
  - Key: Stack
    Value: security
  - Key: ManagedBy
    Value: CloudFormation
  - Key: Owner
    Value: PlatformTeam
  - Key: CostCenter
    Value: security
```

### Network Stack Tags
```yaml
Tags:
  - Key: Environment
    Value: !Ref Environment
  - Key: Application
    Value: litellm
  - Key: Stack
    Value: network
  - Key: ManagedBy
    Value: CloudFormation
```

### Database Stack Tags
```yaml
Tags:
  - Key: Environment
    Value: !Ref Environment
  - Key: Application
    Value: litellm
  - Key: Stack
    Value: database
  - Key: ManagedBy
    Value: CloudFormation
  - Key: Compliance
    Value: !Ref Compliance
  - Key: BackupPolicy
    Value: Daily
```

### LiteLLM Stack Tags
```yaml
Tags:
  - Key: Environment
    Value: !Ref Environment
  - Key: Application
    Value: litellm
  - Key: Stack
    Value: application
  - Key: ManagedBy
    Value: CloudFormation
  - Key: Version
    Value: !Ref ImageTag
```

---

## Filtering Resources by Tags

### Using AWS CLI

#### List all resources for an environment
```bash
# List all resources for dev environment
aws resourcegroupstaggingapi get-resources \
  --tag-filters "Key=Environment,Values=dev" "Key=Application,Values=litellm" \
  --region us-east-1

# Get resource count
aws resourcegroupstaggingapi get-resources \
  --tag-filters "Key=Environment,Values=dev" "Key=Application,Values=litellm" \
  --region us-east-1 \
  --query 'ResourceTagMappingList | length'
```

#### List resources by stack type
```bash
# List all network resources
aws resourcegroupstaggingapi get-resources \
  --tag-filters "Key=Stack,Values=network" "Key=Environment,Values=dev" \
  --region us-east-1
```

#### List RDS databases with compliance requirements
```bash
aws rds describe-db-instances \
  --query 'DBInstances[?contains(TagList[?Key==`Compliance`].Value, `HIPAA`)]' \
  --region us-east-1
```

### Using AWS Console

1. Go to **Resource Groups & Tag Editor**
2. Create a resource group with these criteria:
   - Tag: `Environment` = `dev`
   - Tag: `Application` = `litellm`
3. Save the group for quick access

---

## Cost Allocation Using Tags

### Enable Cost Allocation Tags

1. Go to **AWS Billing Console** → **Cost Allocation Tags**
2. Activate these tags for cost reports:
   - `Environment`
   - `Application`
   - `CostCenter`
   - `Owner`
   - `Stack`

### Create Cost Reports

#### Cost by Environment
```bash
aws ce get-cost-and-usage \
  --time-period Start=2026-01-01,End=2026-01-31 \
  --granularity MONTHLY \
  --metrics UnblendedCost \
  --group-by Type=TAG,Key=Environment
```

#### Cost by Stack Type
```bash
aws ce get-cost-and-usage \
  --time-period Start=2026-01-01,End=2026-01-31 \
  --granularity MONTHLY \
  --metrics UnblendedCost \
  --group-by Type=TAG,Key=Stack
```

#### Cost for specific environment
```bash
aws ce get-cost-and-usage \
  --time-period Start=2026-01-01,End=2026-01-31 \
  --granularity MONTHLY \
  --metrics UnblendedCost \
  --filter file://<(cat <<EOF
{
    "Tags": {
        "Key": "Environment",
        "Values": ["dev"]
    }
}
EOF
)
```

---

## Automated Resource Management Using Tags

### Cleanup Script (Delete all dev resources)

```bash
#!/bin/bash
# Delete all resources tagged with Environment=dev and Application=litellm

ENVIRONMENT="dev"
REGION="us-east-1"

echo "Finding all resources for Environment=$ENVIRONMENT..."

RESOURCES=$(aws resourcegroupstaggingapi get-resources \
  --tag-filters "Key=Environment,Values=$ENVIRONMENT" "Key=Application,Values=litellm" \
  --region "$REGION" \
  --output json)

# Extract CloudFormation stacks
STACKS=$(echo "$RESOURCES" | jq -r '.ResourceTagMappingList[] | select(.ResourceARN | contains("cloudformation:stack")) | .ResourceARN' | awk -F'/' '{print $2}')

echo "Found CloudFormation stacks:"
echo "$STACKS"

echo ""
echo "Delete these stacks? (yes/no)"
read -r CONFIRM

if [ "$CONFIRM" = "yes" ]; then
    for STACK in $STACKS; do
        echo "Deleting stack: $STACK"
        aws cloudformation delete-stack --stack-name "$STACK" --region "$REGION"
    done
    echo "Deletion initiated for all stacks"
else
    echo "Aborted"
fi
```

### Auto-Stop Script (Stop dev resources after hours)

```bash
#!/bin/bash
# Stop ECS tasks for dev environment (run via cron at 6 PM)

ENVIRONMENT="dev"
REGION="us-east-1"

# Find ECS clusters
CLUSTERS=$(aws ecs list-clusters --region "$REGION" --query 'clusterArns[]' --output text | grep "$ENVIRONMENT")

for CLUSTER in $CLUSTERS; do
    # Get services in cluster
    SERVICES=$(aws ecs list-services --cluster "$CLUSTER" --region "$REGION" --query 'serviceArns[]' --output text)

    for SERVICE in $SERVICES; do
        echo "Scaling $SERVICE to 0 tasks..."
        aws ecs update-service \
            --cluster "$CLUSTER" \
            --service "$SERVICE" \
            --desired-count 0 \
            --region "$REGION"
    done
done

echo "Dev environment stopped"
```

### Find Untagged Resources

```bash
#!/bin/bash
# Find resources missing required tags

REGION="us-east-1"

echo "Finding untagged resources..."

# Get all resources
ALL_RESOURCES=$(aws resourcegroupstaggingapi get-resources --region "$REGION" --output json)

# Find resources without Environment tag
UNTAGGED=$(echo "$ALL_RESOURCES" | jq -r '.ResourceTagMappingList[] | select(.Tags | map(select(.Key == "Environment")) | length == 0) | .ResourceARN')

if [ -n "$UNTAGGED" ]; then
    echo "Resources missing Environment tag:"
    echo "$UNTAGGED"
else
    echo "All resources are properly tagged"
fi
```

---

## Compliance and Reporting

### Generate Compliance Report

```bash
#!/bin/bash
# Generate compliance report for tagged resources

ENVIRONMENT="dev"
REGION="us-east-1"

echo "Compliance Report for Environment: $ENVIRONMENT"
echo "Generated: $(date)"
echo "========================================"

# Find resources with compliance tags
COMPLIANT_RESOURCES=$(aws resourcegroupstaggingapi get-resources \
  --tag-filters "Key=Environment,Values=$ENVIRONMENT" "Key=Compliance" \
  --region "$REGION" \
  --output json)

echo "$COMPLIANT_RESOURCES" | jq -r '.ResourceTagMappingList[] |
  "\(.ResourceARN | split(":") | .[5]): \(.Tags[] | select(.Key == "Compliance") | .Value)"'
```

---

## Best Practices

### 1. Always Apply Tags via CloudFormation

✅ **DO:** Let CloudFormation apply tags automatically from parameters
```yaml
Tags:
  - Key: Environment
    Value: !Ref Environment  # From parameter
```

❌ **DON'T:** Manually tag resources in AWS Console (tags will be lost on stack update)

### 2. Use Consistent Tag Values

✅ **DO:** Use lowercase, standardized values
- Environment: `dev`, `staging`, `prod` (not `Dev`, `Development`, `PROD`)
- Application: `litellm` (not `LiteLLM`, `lite-llm`)

❌ **DON'T:** Use mixed case or variations

### 3. Tag Non-CloudFormation Resources

Some resources created outside CloudFormation need manual tagging:
- ECR repositories (if created separately)
- CloudWatch log groups (auto-created)
- ENIs (auto-created by ECS/RDS)

Use AWS CLI to tag these:
```bash
aws logs tag-log-group \
  --log-group-name "/aws/ecs/dev-litellm-service" \
  --tags Environment=dev,Application=litellm
```

### 4. Review Tags Regularly

```bash
# Run weekly to find untagged resources
./scripts/find-untagged-resources.sh

# Audit compliance tags monthly
./scripts/compliance-tag-audit.sh
```

---

## Tag Modification

### Update Tags on Existing Resources

```bash
# Update tag on all resources in an environment
RESOURCES=$(aws resourcegroupstaggingapi get-resources \
  --tag-filters "Key=Environment,Values=dev" \
  --region us-east-1 \
  --output json)

# Add new tag to all resources
echo "$RESOURCES" | jq -r '.ResourceTagMappingList[].ResourceARN' | while read ARN; do
    aws resourcegroupstaggingapi tag-resources \
        --resource-arn-list "$ARN" \
        --tags NewTag=NewValue \
        --region us-east-1
done
```

### Remove Tags

```bash
# Remove tag from all resources
aws resourcegroupstaggingapi untag-resources \
    --resource-arn-list arn:aws:... \
    --tag-keys TagToRemove \
    --region us-east-1
```

---

## Summary

This tagging strategy enables:

✅ **Cost Tracking:** Allocate costs by environment, team, and project
✅ **Resource Management:** Bulk operations on tagged resources
✅ **Access Control:** IAM policies based on tags
✅ **Compliance:** Track resources with special requirements
✅ **Automation:** Scheduled operations (stop/start, backups, cleanup)
✅ **Reporting:** Generate reports for specific environments or teams

All CloudFormation templates in this package implement this tagging strategy consistently. No manual intervention required.
