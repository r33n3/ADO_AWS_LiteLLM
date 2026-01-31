#!/bin/bash
# AWS Resources Monitoring Script
# Monitors CloudFormation stacks, ECS services, RDS, ALB health for LiteLLM deployment
# Usage: ./monitor-aws-resources.sh [environment] [region]

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parameters
ENVIRONMENT=${1:-dev}
AWS_REGION=${2:-us-east-1}

echo "=========================================="
echo "AWS Resources Monitoring"
echo "=========================================="
echo "Environment: $ENVIRONMENT"
echo "Region: $AWS_REGION"
echo "Scan Time: $(date)"
echo ""

# Function to print status
print_status() {
    local status=$1
    local message=$2

    case $status in
        "ok")
            echo -e "${GREEN}✓${NC} $message"
            ;;
        "warning")
            echo -e "${YELLOW}⚠${NC} $message"
            ;;
        "error")
            echo -e "${RED}✗${NC} $message"
            ;;
        "info")
            echo -e "${BLUE}ℹ${NC} $message"
            ;;
    esac
}

## 1. CloudFormation Stacks Status
echo "==========================================  "
echo "1. CloudFormation Stacks"
echo "=========================================="

STACKS=(
    "${ENVIRONMENT}-security-stack"
    "${ENVIRONMENT}-network-stack"
    "${ENVIRONMENT}-alb-stack"
    "${ENVIRONMENT}-database-stack"
    "${ENVIRONMENT}-litellm-stack"
)

ALL_STACKS_HEALTHY=true

for STACK in "${STACKS[@]}"; do
    if aws cloudformation describe-stacks --stack-name "$STACK" --region "$AWS_REGION" &>/dev/null; then
        STATUS=$(aws cloudformation describe-stacks \
            --stack-name "$STACK" \
            --region "$AWS_REGION" \
            --query 'Stacks[0].StackStatus' \
            --output text 2>/dev/null || echo "UNKNOWN")

        case $STATUS in
            "CREATE_COMPLETE"|"UPDATE_COMPLETE")
                print_status "ok" "$STACK: $STATUS"
                ;;
            "CREATE_IN_PROGRESS"|"UPDATE_IN_PROGRESS")
                print_status "warning" "$STACK: $STATUS (in progress)"
                ;;
            "ROLLBACK_COMPLETE"|"ROLLBACK_IN_PROGRESS"|"DELETE_IN_PROGRESS"|"CREATE_FAILED"|"UPDATE_ROLLBACK_COMPLETE")
                print_status "error" "$STACK: $STATUS"
                ALL_STACKS_HEALTHY=false
                ;;
            *)
                print_status "warning" "$STACK: $STATUS"
                ;;
        esac
    else
        print_status "warning" "$STACK: NOT FOUND"
    fi
done

echo ""

## 2. ECS Cluster and Service Health
echo "=========================================="
echo "2. ECS Service Status"
echo "=========================================="

CLUSTER_NAME="${ENVIRONMENT}-litellm-cluster"
SERVICE_NAME="${ENVIRONMENT}-litellm-service"

if aws ecs describe-clusters --clusters "$CLUSTER_NAME" --region "$AWS_REGION" &>/dev/null; then
    CLUSTER_STATUS=$(aws ecs describe-clusters \
        --clusters "$CLUSTER_NAME" \
        --region "$AWS_REGION" \
        --query 'clusters[0].status' \
        --output text 2>/dev/null || echo "UNKNOWN")

    if [ "$CLUSTER_STATUS" = "ACTIVE" ]; then
        print_status "ok" "Cluster $CLUSTER_NAME: ACTIVE"

        # Check service
        if aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" --region "$AWS_REGION" &>/dev/null; then
            DESIRED=$(aws ecs describe-services \
                --cluster "$CLUSTER_NAME" \
                --services "$SERVICE_NAME" \
                --region "$AWS_REGION" \
                --query 'services[0].desiredCount' \
                --output text 2>/dev/null || echo "0")

            RUNNING=$(aws ecs describe-services \
                --cluster "$CLUSTER_NAME" \
                --services "$SERVICE_NAME" \
                --region "$AWS_REGION" \
                --query 'services[0].runningCount' \
                --output text 2>/dev/null || echo "0")

            PENDING=$(aws ecs describe-services \
                --cluster "$CLUSTER_NAME" \
                --services "$SERVICE_NAME" \
                --region "$AWS_REGION" \
                --query 'services[0].pendingCount' \
                --output text 2>/dev/null || echo "0")

            if [ "$RUNNING" -eq "$DESIRED" ] && [ "$DESIRED" -gt 0 ]; then
                print_status "ok" "Service $SERVICE_NAME: $RUNNING/$DESIRED running"
            elif [ "$PENDING" -gt 0 ]; then
                print_status "warning" "Service $SERVICE_NAME: $RUNNING running, $PENDING pending (out of $DESIRED desired)"
            elif [ "$DESIRED" -eq 0 ]; then
                print_status "warning" "Service $SERVICE_NAME: Scaled to 0 (no tasks running)"
            else
                print_status "error" "Service $SERVICE_NAME: Only $RUNNING/$DESIRED running"
            fi
        else
            print_status "warning" "Service $SERVICE_NAME: NOT FOUND"
        fi
    else
        print_status "error" "Cluster $CLUSTER_NAME: $CLUSTER_STATUS"
    fi
else
    print_status "warning" "Cluster $CLUSTER_NAME: NOT FOUND"
fi

echo ""

## 3. RDS Database Health
echo "=========================================="
echo "3. RDS Database Status"
echo "=========================================="

DB_INSTANCE="${ENVIRONMENT}-litellm-database"

if aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE" --region "$AWS_REGION" &>/dev/null; then
    DB_STATUS=$(aws rds describe-db-instances \
        --db-instance-identifier "$DB_INSTANCE" \
        --region "$AWS_REGION" \
        --query 'DBInstances[0].DBInstanceStatus' \
        --output text 2>/dev/null || echo "UNKNOWN")

    if [ "$DB_STATUS" = "available" ]; then
        print_status "ok" "Database $DB_INSTANCE: available"

        # Get storage info
        ALLOCATED_STORAGE=$(aws rds describe-db-instances \
            --db-instance-identifier "$DB_INSTANCE" \
            --region "$AWS_REGION" \
            --query 'DBInstances[0].AllocatedStorage' \
            --output text 2>/dev/null || echo "0")

        print_status "info" "  Storage: ${ALLOCATED_STORAGE}GB allocated"
    elif [ "$DB_STATUS" = "backing-up" ] || [ "$DB_STATUS" = "modifying" ]; then
        print_status "warning" "Database $DB_INSTANCE: $DB_STATUS (maintenance in progress)"
    else
        print_status "error" "Database $DB_INSTANCE: $DB_STATUS"
    fi
else
    print_status "warning" "Database $DB_INSTANCE: NOT FOUND"
fi

echo ""

## 4. ALB Health and Target Health
echo "=========================================="
echo "4. Application Load Balancer"
echo "=========================================="

# Find ALB by tag
ALB_ARN=$(aws elbv2 describe-load-balancers \
    --region "$AWS_REGION" \
    --query "LoadBalancers[?contains(LoadBalancerName, '${ENVIRONMENT}-litellm')].LoadBalancerArn" \
    --output text 2>/dev/null || echo "")

if [ -n "$ALB_ARN" ]; then
    ALB_STATE=$(aws elbv2 describe-load-balancers \
        --load-balancer-arns "$ALB_ARN" \
        --region "$AWS_REGION" \
        --query 'LoadBalancers[0].State.Code' \
        --output text 2>/dev/null || echo "UNKNOWN")

    ALB_DNS=$(aws elbv2 describe-load-balancers \
        --load-balancer-arns "$ALB_ARN" \
        --region "$AWS_REGION" \
        --query 'LoadBalancers[0].DNSName' \
        --output text 2>/dev/null || echo "")

    if [ "$ALB_STATE" = "active" ]; then
        print_status "ok" "ALB Status: active"
        print_status "info" "  DNS: $ALB_DNS"

        # Check target group health
        TG_ARN=$(aws elbv2 describe-target-groups \
            --load-balancer-arn "$ALB_ARN" \
            --region "$AWS_REGION" \
            --query 'TargetGroups[0].TargetGroupArn' \
            --output text 2>/dev/null || echo "")

        if [ -n "$TG_ARN" ]; then
            HEALTHY_COUNT=$(aws elbv2 describe-target-health \
                --target-group-arn "$TG_ARN" \
                --region "$AWS_REGION" \
                --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" \
                --output text 2>/dev/null || echo "0")

            UNHEALTHY_COUNT=$(aws elbv2 describe-target-health \
                --target-group-arn "$TG_ARN" \
                --region "$AWS_REGION" \
                --query "length(TargetHealthDescriptions[?TargetHealth.State=='unhealthy'])" \
                --output text 2>/dev/null || echo "0")

            TOTAL=$((HEALTHY_COUNT + UNHEALTHY_COUNT))

            if [ "$HEALTHY_COUNT" -gt 0 ] && [ "$UNHEALTHY_COUNT" -eq 0 ]; then
                print_status "ok" "  Targets: $HEALTHY_COUNT healthy"
            elif [ "$HEALTHY_COUNT" -gt 0 ]; then
                print_status "warning" "  Targets: $HEALTHY_COUNT healthy, $UNHEALTHY_COUNT unhealthy"
            else
                print_status "error" "  Targets: No healthy targets"
            fi
        fi
    else
        print_status "error" "ALB Status: $ALB_STATE"
    fi
else
    print_status "warning" "ALB: NOT FOUND"
fi

echo ""

## 5. CloudWatch Recent Errors
echo "=========================================="
echo "5. Recent CloudWatch Errors (Last 1 hour)"
echo "=========================================="

LOG_GROUP="/aws/ecs/${ENVIRONMENT}-litellm-service"

if aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" --region "$AWS_REGION" &>/dev/null; then
    # Get recent error count
    START_TIME=$(($(date +%s) - 3600))000  # 1 hour ago in milliseconds
    END_TIME=$(($(date +%s)))000  # Now in milliseconds

    ERROR_COUNT=$(aws logs filter-log-events \
        --log-group-name "$LOG_GROUP" \
        --region "$AWS_REGION" \
        --start-time "$START_TIME" \
        --end-time "$END_TIME" \
        --filter-pattern "ERROR" \
        --query 'length(events)' \
        --output text 2>/dev/null || echo "0")

    if [ "$ERROR_COUNT" -eq 0 ]; then
        print_status "ok" "No errors in last hour"
    elif [ "$ERROR_COUNT" -lt 10 ]; then
        print_status "warning" "$ERROR_COUNT errors in last hour"
    else
        print_status "error" "$ERROR_COUNT errors in last hour (high error rate)"
    fi
else
    print_status "info" "Log group not found (no logs yet or service not deployed)"
fi

echo ""

## 6. Cost Estimate (Current Month)
echo "=========================================="
echo "6. Estimated Costs (Current Month)"
echo "=========================================="

CURRENT_MONTH=$(date +%Y-%m-01)
TODAY=$(date +%Y-%m-%d)

COSTS=$(aws ce get-cost-and-usage \
    --time-period Start="$CURRENT_MONTH",End="$TODAY" \
    --granularity MONTHLY \
    --metrics UnblendedCost \
    --filter file://<(cat <<EOF
{
    "Tags": {
        "Key": "Environment",
        "Values": ["$ENVIRONMENT"]
    }
}
EOF
) \
    --region us-east-1 \
    --query 'ResultsByTime[0].Total.UnblendedCost.Amount' \
    --output text 2>/dev/null || echo "0")

if [ "$COSTS" != "0" ]; then
    print_status "info" "Current month costs: \$$(printf "%.2f" "$COSTS")"
else
    print_status "info" "Cost data not available (may take 24h to appear)"
fi

echo ""

## Summary
echo "=========================================="
echo "Monitoring Summary"
echo "=========================================="

if [ "$ALL_STACKS_HEALTHY" = true ]; then
    print_status "ok" "All CloudFormation stacks are healthy"
else
    print_status "error" "Some CloudFormation stacks have issues"
fi

echo ""
echo "Monitoring completed at $(date)"
echo "=========================================="
