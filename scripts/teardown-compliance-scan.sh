#!/bin/bash
# Teardown Compliance Scan - Check for Orphaned AWS Resources
#
# Purpose: Identify resources that were not deleted during CloudFormation stack teardown
# Usage: ./scripts/teardown-compliance-scan.sh <environment> [region]
#
# Example: ./scripts/teardown-compliance-scan.sh dev us-east-1

set -e

ENVIRONMENT="${1:-dev}"
AWS_REGION="${AWS_REGION:-${2:-us-east-1}}"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
REPORT_FILE="teardown-compliance-report-${ENVIRONMENT}-${TIMESTAMP}.md"

echo "==========================================" | tee "$REPORT_FILE"
echo "Teardown Compliance Report" | tee -a "$REPORT_FILE"
echo "==========================================" | tee -a "$REPORT_FILE"
echo "Environment: $ENVIRONMENT" | tee -a "$REPORT_FILE"
echo "Region: $AWS_REGION" | tee -a "$REPORT_FILE"
echo "Scan Time: $(date)" | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"

TOTAL_ORPHANED=0
ISSUES_FOUND=0

# Function to check and report resources
check_resource() {
    local resource_type=$1
    local resource_name=$2
    local resource_id=$3
    local cleanup_action=$4

    echo "⚠️  ORPHANED: $resource_type - $resource_name" | tee -a "$REPORT_FILE"
    echo "   Resource ID: $resource_id" | tee -a "$REPORT_FILE"
    echo "   Cleanup Action: $cleanup_action" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    TOTAL_ORPHANED=$((TOTAL_ORPHANED + 1))
}

#############################################################################
# 1. Check CloudFormation Stacks
#############################################################################
echo "## 1. CloudFormation Stacks" | tee -a "$REPORT_FILE"
echo "Checking for remaining stacks..." | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"

STACKS=$(aws cloudformation list-stacks \
    --region $AWS_REGION \
    --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE \
    --query "StackSummaries[?starts_with(StackName, '${ENVIRONMENT}-')].StackName" \
    --output text 2>/dev/null || echo "")

if [ -n "$STACKS" ]; then
    for STACK in $STACKS; do
        check_resource "CloudFormation Stack" "$STACK" "$STACK" "aws cloudformation delete-stack --stack-name $STACK --region $AWS_REGION"
        ISSUES_FOUND=$((ISSUES_FOUND + 1))
    done
else
    echo "✓ No CloudFormation stacks found" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
fi

#############################################################################
# 2. Check ECR Repository and Images
#############################################################################
echo "## 2. ECR Repository and Images" | tee -a "$REPORT_FILE"
echo "Checking for ECR repositories and images..." | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"

ECR_REPOS=$(aws ecr describe-repositories \
    --region $AWS_REGION \
    --query "repositories[?contains(repositoryName, 'litellm')].repositoryName" \
    --output text 2>/dev/null || echo "")

if [ -n "$ECR_REPOS" ]; then
    for REPO in $ECR_REPOS; do
        # Count images in repository
        IMAGE_COUNT=$(aws ecr list-images \
            --repository-name $REPO \
            --region $AWS_REGION \
            --query 'length(imageIds)' \
            --output text 2>/dev/null || echo "0")

        if [ "$IMAGE_COUNT" -gt 0 ]; then
            check_resource "ECR Repository with Images" "$REPO" "$REPO ($IMAGE_COUNT images)" \
                "aws ecr delete-repository --repository-name $REPO --region $AWS_REGION --force"
            ISSUES_FOUND=$((ISSUES_FOUND + 1))
        else
            check_resource "ECR Repository (empty)" "$REPO" "$REPO" \
                "aws ecr delete-repository --repository-name $REPO --region $AWS_REGION"
            ISSUES_FOUND=$((ISSUES_FOUND + 1))
        fi
    done
else
    echo "✓ No ECR repositories found" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
fi

#############################################################################
# 3. Check CloudWatch Log Groups
#############################################################################
echo "## 3. CloudWatch Log Groups" | tee -a "$REPORT_FILE"
echo "Checking for CloudWatch log groups..." | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"

LOG_GROUPS=$(aws logs describe-log-groups \
    --region $AWS_REGION \
    --query "logGroups[?contains(logGroupName, '${ENVIRONMENT}') && contains(logGroupName, 'litellm')].logGroupName" \
    --output text 2>/dev/null || echo "")

if [ -n "$LOG_GROUPS" ]; then
    for LOG_GROUP in $LOG_GROUPS; do
        check_resource "CloudWatch Log Group" "$LOG_GROUP" "$LOG_GROUP" \
            "aws logs delete-log-group --log-group-name $LOG_GROUP --region $AWS_REGION"
        ISSUES_FOUND=$((ISSUES_FOUND + 1))
    done
else
    echo "✓ No CloudWatch log groups found" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
fi

#############################################################################
# 4. Check Secrets Manager Secrets
#############################################################################
echo "## 4. Secrets Manager Secrets" | tee -a "$REPORT_FILE"
echo "Checking for Secrets Manager secrets..." | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"

SECRETS=$(aws secretsmanager list-secrets \
    --region $AWS_REGION \
    --query "SecretList[?contains(Name, '${ENVIRONMENT}') && contains(Name, 'litellm')].Name" \
    --output text 2>/dev/null || echo "")

if [ -n "$SECRETS" ]; then
    for SECRET in $SECRETS; do
        # Check if secret is scheduled for deletion
        DELETION_DATE=$(aws secretsmanager describe-secret \
            --secret-id $SECRET \
            --region $AWS_REGION \
            --query 'DeletedDate' \
            --output text 2>/dev/null || echo "None")

        if [ "$DELETION_DATE" = "None" ]; then
            check_resource "Secrets Manager Secret (Active)" "$SECRET" "$SECRET" \
                "aws secretsmanager delete-secret --secret-id $SECRET --region $AWS_REGION --force-delete-without-recovery"
            ISSUES_FOUND=$((ISSUES_FOUND + 1))
        else
            echo "⏳ Secret scheduled for deletion: $SECRET (Deletion date: $DELETION_DATE)" | tee -a "$REPORT_FILE"
            echo "" | tee -a "$REPORT_FILE"
        fi
    done
else
    echo "✓ No active Secrets Manager secrets found" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
fi

#############################################################################
# 5. Check KMS Keys
#############################################################################
echo "## 5. KMS Keys" | tee -a "$REPORT_FILE"
echo "Checking for KMS keys..." | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"

KMS_KEYS=$(aws kms list-keys \
    --region $AWS_REGION \
    --query 'Keys[].KeyId' \
    --output text 2>/dev/null || echo "")

LITELLM_KEYS=""
if [ -n "$KMS_KEYS" ]; then
    for KEY_ID in $KMS_KEYS; do
        # Get key tags
        KEY_TAGS=$(aws kms list-resource-tags \
            --key-id $KEY_ID \
            --region $AWS_REGION \
            --query "Tags[?TagKey=='Environment' && TagValue=='${ENVIRONMENT}'].TagValue" \
            --output text 2>/dev/null || echo "")

        if [ -n "$KEY_TAGS" ]; then
            # Get key state
            KEY_STATE=$(aws kms describe-key \
                --key-id $KEY_ID \
                --region $AWS_REGION \
                --query 'KeyMetadata.KeyState' \
                --output text 2>/dev/null || echo "Unknown")

            KEY_ALIAS=$(aws kms list-aliases \
                --key-id $KEY_ID \
                --region $AWS_REGION \
                --query 'Aliases[0].AliasName' \
                --output text 2>/dev/null || echo "No alias")

            if [ "$KEY_STATE" = "PendingDeletion" ]; then
                echo "⏳ KMS Key scheduled for deletion: $KEY_ALIAS ($KEY_ID) - State: $KEY_STATE" | tee -a "$REPORT_FILE"
                echo "" | tee -a "$REPORT_FILE"
            elif [ "$KEY_STATE" = "Enabled" ]; then
                check_resource "KMS Key (Enabled)" "$KEY_ALIAS" "$KEY_ID (State: $KEY_STATE)" \
                    "aws kms schedule-key-deletion --key-id $KEY_ID --region $AWS_REGION --pending-window-in-days 7"
                ISSUES_FOUND=$((ISSUES_FOUND + 1))
            fi
        fi
    done
fi

if [ -z "$LITELLM_KEYS" ]; then
    echo "✓ No active KMS keys found for this environment" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
fi

#############################################################################
# 6. Check VPC Resources
#############################################################################
echo "## 6. VPC Resources" | tee -a "$REPORT_FILE"
echo "Checking for VPC resources..." | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"

VPCS=$(aws ec2 describe-vpcs \
    --region $AWS_REGION \
    --filters "Name=tag:Environment,Values=${ENVIRONMENT}" "Name=tag:Application,Values=litellm" \
    --query 'Vpcs[].VpcId' \
    --output text 2>/dev/null || echo "")

if [ -n "$VPCS" ]; then
    for VPC in $VPCS; do
        VPC_NAME=$(aws ec2 describe-vpcs \
            --vpc-ids $VPC \
            --region $AWS_REGION \
            --query 'Vpcs[0].Tags[?Key==`Name`].Value' \
            --output text 2>/dev/null || echo "Unknown")

        check_resource "VPC" "$VPC_NAME" "$VPC" \
            "Manual cleanup required - VPC may have dependent resources (subnets, ENIs, route tables)"
        ISSUES_FOUND=$((ISSUES_FOUND + 1))
    done
else
    echo "✓ No VPCs found" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
fi

#############################################################################
# 7. Check Elastic Network Interfaces (ENIs)
#############################################################################
echo "## 7. Elastic Network Interfaces (ENIs)" | tee -a "$REPORT_FILE"
echo "Checking for orphaned ENIs..." | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"

ENIS=$(aws ec2 describe-network-interfaces \
    --region $AWS_REGION \
    --filters "Name=tag:Environment,Values=${ENVIRONMENT}" "Name=tag:Application,Values=litellm" \
    --query 'NetworkInterfaces[].NetworkInterfaceId' \
    --output text 2>/dev/null || echo "")

if [ -n "$ENIS" ]; then
    for ENI in $ENIS; do
        ENI_DESC=$(aws ec2 describe-network-interfaces \
            --network-interface-ids $ENI \
            --region $AWS_REGION \
            --query 'NetworkInterfaces[0].Description' \
            --output text 2>/dev/null || echo "Unknown")

        check_resource "Elastic Network Interface" "$ENI_DESC" "$ENI" \
            "aws ec2 delete-network-interface --network-interface-id $ENI --region $AWS_REGION"
        ISSUES_FOUND=$((ISSUES_FOUND + 1))
    done
else
    echo "✓ No orphaned ENIs found" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
fi

#############################################################################
# 8. Check Security Groups
#############################################################################
echo "## 8. Security Groups" | tee -a "$REPORT_FILE"
echo "Checking for security groups..." | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"

SGS=$(aws ec2 describe-security-groups \
    --region $AWS_REGION \
    --filters "Name=tag:Environment,Values=${ENVIRONMENT}" "Name=tag:Application,Values=litellm" \
    --query 'SecurityGroups[].GroupId' \
    --output text 2>/dev/null || echo "")

if [ -n "$SGS" ]; then
    for SG in $SGS; do
        SG_NAME=$(aws ec2 describe-security-groups \
            --group-ids $SG \
            --region $AWS_REGION \
            --query 'SecurityGroups[0].GroupName' \
            --output text 2>/dev/null || echo "Unknown")

        check_resource "Security Group" "$SG_NAME" "$SG" \
            "aws ec2 delete-security-group --group-id $SG --region $AWS_REGION"
        ISSUES_FOUND=$((ISSUES_FOUND + 1))
    done
else
    echo "✓ No security groups found" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
fi

#############################################################################
# 9. Check ECS Clusters
#############################################################################
echo "## 9. ECS Clusters" | tee -a "$REPORT_FILE"
echo "Checking for ECS clusters..." | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"

ECS_CLUSTERS=$(aws ecs list-clusters \
    --region $AWS_REGION \
    --query 'clusterArns[?contains(@, `'${ENVIRONMENT}'`) && contains(@, `litellm`)]' \
    --output text 2>/dev/null || echo "")

if [ -n "$ECS_CLUSTERS" ]; then
    for CLUSTER_ARN in $ECS_CLUSTERS; do
        CLUSTER_NAME=$(basename $CLUSTER_ARN)
        check_resource "ECS Cluster" "$CLUSTER_NAME" "$CLUSTER_ARN" \
            "aws ecs delete-cluster --cluster $CLUSTER_ARN --region $AWS_REGION"
        ISSUES_FOUND=$((ISSUES_FOUND + 1))
    done
else
    echo "✓ No ECS clusters found" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
fi

#############################################################################
# 10. Check RDS Instances and Snapshots
#############################################################################
echo "## 10. RDS Instances and Snapshots" | tee -a "$REPORT_FILE"
echo "Checking for RDS resources..." | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"

RDS_INSTANCES=$(aws rds describe-db-instances \
    --region $AWS_REGION \
    --query "DBInstances[?contains(DBInstanceIdentifier, '${ENVIRONMENT}')].DBInstanceIdentifier" \
    --output text 2>/dev/null || echo "")

if [ -n "$RDS_INSTANCES" ]; then
    for DB in $RDS_INSTANCES; do
        check_resource "RDS Instance" "$DB" "$DB" \
            "aws rds delete-db-instance --db-instance-identifier $DB --region $AWS_REGION --skip-final-snapshot"
        ISSUES_FOUND=$((ISSUES_FOUND + 1))
    done
fi

# Check for snapshots
RDS_SNAPSHOTS=$(aws rds describe-db-snapshots \
    --region $AWS_REGION \
    --query "DBSnapshots[?contains(DBSnapshotIdentifier, '${ENVIRONMENT}')].DBSnapshotIdentifier" \
    --output text 2>/dev/null || echo "")

if [ -n "$RDS_SNAPSHOTS" ]; then
    for SNAPSHOT in $RDS_SNAPSHOTS; do
        check_resource "RDS Snapshot" "$SNAPSHOT" "$SNAPSHOT" \
            "aws rds delete-db-snapshot --db-snapshot-identifier $SNAPSHOT --region $AWS_REGION"
        ISSUES_FOUND=$((ISSUES_FOUND + 1))
    done
fi

if [ -z "$RDS_INSTANCES" ] && [ -z "$RDS_SNAPSHOTS" ]; then
    echo "✓ No RDS instances or snapshots found" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
fi

#############################################################################
# 11. Check S3 Buckets (ALB Logs)
#############################################################################
echo "## 11. S3 Buckets" | tee -a "$REPORT_FILE"
echo "Checking for S3 buckets..." | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"

S3_BUCKETS=$(aws s3api list-buckets \
    --query "Buckets[?contains(Name, '${ENVIRONMENT}') && contains(Name, 'litellm')].Name" \
    --output text 2>/dev/null || echo "")

if [ -n "$S3_BUCKETS" ]; then
    for BUCKET in $S3_BUCKETS; do
        OBJECT_COUNT=$(aws s3 ls s3://$BUCKET --recursive --summarize 2>/dev/null | grep "Total Objects:" | awk '{print $3}' || echo "0")
        check_resource "S3 Bucket" "$BUCKET" "$BUCKET ($OBJECT_COUNT objects)" \
            "aws s3 rb s3://$BUCKET --region $AWS_REGION --force"
        ISSUES_FOUND=$((ISSUES_FOUND + 1))
    done
else
    echo "✓ No S3 buckets found" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
fi

#############################################################################
# 12. Check IAM Roles and Policies
#############################################################################
echo "## 12. IAM Roles and Policies" | tee -a "$REPORT_FILE"
echo "Checking for IAM roles..." | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"

IAM_ROLES=$(aws iam list-roles \
    --query "Roles[?contains(RoleName, '${ENVIRONMENT}') && contains(RoleName, 'litellm')].RoleName" \
    --output text 2>/dev/null || echo "")

if [ -n "$IAM_ROLES" ]; then
    for ROLE in $IAM_ROLES; do
        check_resource "IAM Role" "$ROLE" "$ROLE" \
            "aws iam delete-role --role-name $ROLE (after detaching policies)"
        ISSUES_FOUND=$((ISSUES_FOUND + 1))
    done
else
    echo "✓ No IAM roles found" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
fi

#############################################################################
# Summary
#############################################################################
echo "==========================================" | tee -a "$REPORT_FILE"
echo "Teardown Compliance Summary" | tee -a "$REPORT_FILE"
echo "==========================================" | tee -a "$REPORT_FILE"
echo "Total orphaned resources found: $TOTAL_ORPHANED" | tee -a "$REPORT_FILE"
echo "Critical issues requiring action: $ISSUES_FOUND" | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"

if [ $ISSUES_FOUND -eq 0 ]; then
    echo "✅ COMPLIANCE PASSED: No orphaned resources found" | tee -a "$REPORT_FILE"
    echo "   All infrastructure was successfully deleted" | tee -a "$REPORT_FILE"
else
    echo "⚠️  COMPLIANCE FAILED: $ISSUES_FOUND issues require cleanup" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    echo "### Recommended Teardown Pipeline Improvements:" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    echo "Add these steps to azure-pipelines-teardown.yml:" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"

    if echo "$LOG_GROUPS" | grep -q .; then
        echo "1. Delete CloudWatch Log Groups before stack deletion:" | tee -a "$REPORT_FILE"
        echo "   \`\`\`bash" | tee -a "$REPORT_FILE"
        echo "   for LOG_GROUP in \$(aws logs describe-log-groups --query 'logGroups[?contains(logGroupName, \"'\${ENVIRONMENT}'-litellm\")].logGroupName' --output text); do" | tee -a "$REPORT_FILE"
        echo "     aws logs delete-log-group --log-group-name \$LOG_GROUP" | tee -a "$REPORT_FILE"
        echo "   done" | tee -a "$REPORT_FILE"
        echo "   \`\`\`" | tee -a "$REPORT_FILE"
        echo "" | tee -a "$REPORT_FILE"
    fi

    if echo "$ECR_REPOS" | grep -q .; then
        echo "2. Force delete ECR repository after stack deletion:" | tee -a "$REPORT_FILE"
        echo "   \`\`\`bash" | tee -a "$REPORT_FILE"
        echo "   aws ecr delete-repository --repository-name litellm-proxy --region \${AWS_REGION} --force" | tee -a "$REPORT_FILE"
        echo "   \`\`\`" | tee -a "$REPORT_FILE"
        echo "" | tee -a "$REPORT_FILE"
    fi

    if echo "$SECRETS" | grep -q .; then
        echo "3. Force delete Secrets Manager secrets:" | tee -a "$REPORT_FILE"
        echo "   \`\`\`bash" | tee -a "$REPORT_FILE"
        echo "   for SECRET in \$(aws secretsmanager list-secrets --query 'SecretList[?contains(Name, \"'\${ENVIRONMENT}'-litellm\")].Name' --output text); do" | tee -a "$REPORT_FILE"
        echo "     aws secretsmanager delete-secret --secret-id \$SECRET --force-delete-without-recovery" | tee -a "$REPORT_FILE"
        echo "   done" | tee -a "$REPORT_FILE"
        echo "   \`\`\`" | tee -a "$REPORT_FILE"
        echo "" | tee -a "$REPORT_FILE"
    fi
fi

echo "" | tee -a "$REPORT_FILE"
echo "Report saved to: $REPORT_FILE" | tee -a "$REPORT_FILE"
echo "==========================================" | tee -a "$REPORT_FILE"

# Exit with error code if issues found
if [ $ISSUES_FOUND -gt 0 ]; then
    exit 1
else
    exit 0
fi
