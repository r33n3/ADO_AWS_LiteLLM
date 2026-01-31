#!/bin/bash
# Azure DevOps Pipelines Monitoring Script
# Monitors pipeline runs, success rates, and deployment status
# Usage: ./monitor-ado-pipelines.sh <organization> <project>
#
# Prerequisites:
# - Azure CLI installed (az)
# - Azure DevOps extension installed (az extension add --name azure-devops)
# - Authenticated to Azure DevOps (az login)
# - PAT token set: export AZURE_DEVOPS_EXT_PAT=<your-pat-token>

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parameters
ORGANIZATION=${1:-}
PROJECT=${2:-}

if [ -z "$ORGANIZATION" ] || [ -z "$PROJECT" ]; then
    echo "Usage: $0 <organization> <project>"
    echo "Example: $0 myorg myproject"
    exit 1
fi

# Check if Azure DevOps PAT is set
if [ -z "${AZURE_DEVOPS_EXT_PAT:-}" ]; then
    echo "Error: AZURE_DEVOPS_EXT_PAT environment variable not set"
    echo "Please set your Azure DevOps Personal Access Token:"
    echo "  export AZURE_DEVOPS_EXT_PAT=<your-pat-token>"
    exit 1
fi

echo "=========================================="
echo "Azure DevOps Pipelines Monitoring"
echo "=========================================="
echo "Organization: $ORGANIZATION"
echo "Project: $PROJECT"
echo "Scan Time: $(date)"
echo ""

# Set default organization and project
az devops configure --defaults organization="https://dev.azure.com/$ORGANIZATION" project="$PROJECT"

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

## 1. List All LiteLLM Pipelines
echo "=========================================="
echo "1. Pipeline Status"
echo "=========================================="

PIPELINES=$(az pipelines list --output json 2>/dev/null || echo "[]")

if [ "$PIPELINES" != "[]" ]; then
    LITELLM_PIPELINES=$(echo "$PIPELINES" | jq -r '.[] | select(.name | test("litellm|LiteLLM|Security|Network|ALB|Database|Teardown")) | "\(.id)|\(.name)"')

    if [ -n "$LITELLM_PIPELINES" ]; then
        echo "$LITELLM_PIPELINES" | while IFS='|' read -r PIPELINE_ID PIPELINE_NAME; do
            # Get latest run
            LATEST_RUN=$(az pipelines runs list \
                --pipeline-ids "$PIPELINE_ID" \
                --top 1 \
                --output json 2>/dev/null || echo "[]")

            if [ "$LATEST_RUN" != "[]" ]; then
                RUN_STATUS=$(echo "$LATEST_RUN" | jq -r '.[0].result // "inProgress"')
                RUN_STATE=$(echo "$LATEST_RUN" | jq -r '.[0].state // "unknown"')
                RUN_TIME=$(echo "$LATEST_RUN" | jq -r '.[0].finishTime // .[0].startTime // "N/A"' | cut -d'T' -f1)

                case $RUN_STATUS in
                    "succeeded")
                        print_status "ok" "$PIPELINE_NAME: Last run succeeded ($RUN_TIME)"
                        ;;
                    "failed")
                        print_status "error" "$PIPELINE_NAME: Last run failed ($RUN_TIME)"
                        ;;
                    "canceled")
                        print_status "warning" "$PIPELINE_NAME: Last run canceled ($RUN_TIME)"
                        ;;
                    "inProgress")
                        print_status "info" "$PIPELINE_NAME: Run in progress..."
                        ;;
                    *)
                        print_status "warning" "$PIPELINE_NAME: Status $RUN_STATUS ($RUN_TIME)"
                        ;;
                esac
            else
                print_status "info" "$PIPELINE_NAME: No runs yet"
            fi
        done
    else
        print_status "warning" "No LiteLLM-related pipelines found"
    fi
else
    print_status "error" "Failed to list pipelines (check authentication)"
fi

echo ""

## 2. Recent Pipeline Runs (Last 24 hours)
echo "=========================================="
echo "2. Recent Pipeline Activity (Last 24 hours)"
echo "=========================================="

MIN_TIME=$(date -u -d '24 hours ago' +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-24H +"%Y-%m-%dT%H:%M:%SZ")

RECENT_RUNS=$(az pipelines runs list \
    --query "[?finishTime >= '$MIN_TIME' || state == 'inProgress']" \
    --output json 2>/dev/null || echo "[]")

if [ "$RECENT_RUNS" != "[]" ]; then
    TOTAL_RUNS=$(echo "$RECENT_RUNS" | jq 'length')
    SUCCEEDED=$(echo "$RECENT_RUNS" | jq '[.[] | select(.result == "succeeded")] | length')
    FAILED=$(echo "$RECENT_RUNS" | jq '[.[] | select(.result == "failed")] | length')
    IN_PROGRESS=$(echo "$RECENT_RUNS" | jq '[.[] | select(.state == "inProgress")] | length')

    print_status "info" "Total runs: $TOTAL_RUNS"
    print_status "ok" "Succeeded: $SUCCEEDED"

    if [ "$FAILED" -gt 0 ]; then
        print_status "error" "Failed: $FAILED"
    else
        print_status "ok" "Failed: 0"
    fi

    if [ "$IN_PROGRESS" -gt 0 ]; then
        print_status "info" "In Progress: $IN_PROGRESS"
    fi

    # Success rate
    if [ "$TOTAL_RUNS" -gt 0 ]; then
        COMPLETED=$((SUCCEEDED + FAILED))
        if [ "$COMPLETED" -gt 0 ]; then
            SUCCESS_RATE=$((SUCCEEDED * 100 / COMPLETED))
            if [ "$SUCCESS_RATE" -ge 90 ]; then
                print_status "ok" "Success rate: ${SUCCESS_RATE}%"
            elif [ "$SUCCESS_RATE" -ge 70 ]; then
                print_status "warning" "Success rate: ${SUCCESS_RATE}%"
            else
                print_status "error" "Success rate: ${SUCCESS_RATE}% (below 70%)"
            fi
        fi
    fi
else
    print_status "info" "No pipeline runs in last 24 hours"
fi

echo ""

## 3. Service Connections Status
echo "=========================================="
echo "3. Service Connections"
echo "=========================================="

# Check AWS service connection
SERVICE_CONNECTIONS=$(az devops service-endpoint list --output json 2>/dev/null || echo "[]")

if [ "$SERVICE_CONNECTIONS" != "[]" ]; then
    AWS_CONNECTION=$(echo "$SERVICE_CONNECTIONS" | jq -r '.[] | select(.name == "aws-litellm-connection") | .name')

    if [ -n "$AWS_CONNECTION" ]; then
        IS_READY=$(echo "$SERVICE_CONNECTIONS" | jq -r '.[] | select(.name == "aws-litellm-connection") | .isReady')

        if [ "$IS_READY" = "true" ]; then
            print_status "ok" "AWS service connection 'aws-litellm-connection': Ready"
        else
            print_status "error" "AWS service connection 'aws-litellm-connection': Not ready"
        fi
    else
        print_status "error" "AWS service connection 'aws-litellm-connection': NOT FOUND"
    fi
else
    print_status "error" "Failed to list service connections"
fi

echo ""

## 4. Variable Groups Status
echo "=========================================="
echo "4. Variable Groups"
echo "=========================================="

# Check required variable groups
VARIABLE_GROUPS=$(az pipelines variable-group list --output json 2>/dev/null || echo "[]")

if [ "$VARIABLE_GROUPS" != "[]" ]; then
    # Check litellm-aws-config
    CONFIG_GROUP=$(echo "$VARIABLE_GROUPS" | jq -r '.[] | select(.name == "litellm-aws-config") | .name')
    if [ -n "$CONFIG_GROUP" ]; then
        VAR_COUNT=$(echo "$VARIABLE_GROUPS" | jq -r '.[] | select(.name == "litellm-aws-config") | .variables | length')
        print_status "ok" "Variable group 'litellm-aws-config': Found ($VAR_COUNT variables)"
    else
        print_status "error" "Variable group 'litellm-aws-config': NOT FOUND"
    fi

    # Check litellm-aws-secrets
    SECRETS_GROUP=$(echo "$VARIABLE_GROUPS" | jq -r '.[] | select(.name == "litellm-aws-secrets") | .name')
    if [ -n "$SECRETS_GROUP" ]; then
        SECRET_COUNT=$(echo "$VARIABLE_GROUPS" | jq -r '.[] | select(.name == "litellm-aws-secrets") | .variables | length')
        print_status "ok" "Variable group 'litellm-aws-secrets': Found ($SECRET_COUNT variables)"
    else
        print_status "error" "Variable group 'litellm-aws-secrets': NOT FOUND"
    fi
else
    print_status "error" "Failed to list variable groups"
fi

echo ""

## 5. Failed Pipeline Runs Details (Last 7 days)
echo "=========================================="
echo "5. Recent Failed Runs (Last 7 days)"
echo "=========================================="

MIN_TIME_7D=$(date -u -d '7 days ago' +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-7d +"%Y-%m-%dT%H:%M:%SZ")

FAILED_RUNS=$(az pipelines runs list \
    --query "[?finishTime >= '$MIN_TIME_7D' && result == 'failed']" \
    --output json 2>/dev/null || echo "[]")

if [ "$FAILED_RUNS" != "[]" ]; then
    FAILED_COUNT=$(echo "$FAILED_RUNS" | jq 'length')

    if [ "$FAILED_COUNT" -gt 0 ]; then
        print_status "warning" "Found $FAILED_COUNT failed runs in last 7 days:"
        echo ""
        echo "$FAILED_RUNS" | jq -r '.[] | "  - \(.pipeline.name): \(.finishTime | split("T")[0]) - \(.sourceVersion[0:7])"' | head -10

        if [ "$FAILED_COUNT" -gt 10 ]; then
            echo "  ... and $((FAILED_COUNT - 10)) more"
        fi
    else
        print_status "ok" "No failed runs in last 7 days"
    fi
else
    print_status "ok" "No failed runs in last 7 days"
fi

echo ""

## 6. Pipeline Queue Status
echo "=========================================="
echo "6. Pipeline Queue"
echo "=========================================="

QUEUED_RUNS=$(az pipelines runs list \
    --query "[?state == 'inProgress' || state == 'notStarted']" \
    --output json 2>/dev/null || echo "[]")

if [ "$QUEUED_RUNS" != "[]" ]; then
    QUEUE_COUNT=$(echo "$QUEUED_RUNS" | jq 'length')

    if [ "$QUEUE_COUNT" -gt 0 ]; then
        print_status "info" "$QUEUE_COUNT pipeline(s) running or queued:"
        echo "$QUEUED_RUNS" | jq -r '.[] | "  - \(.pipeline.name): \(.state)"'
    else
        print_status "ok" "No pipelines in queue"
    fi
else
    print_status "ok" "No pipelines in queue"
fi

echo ""

## Summary
echo "=========================================="
echo "Monitoring Summary"
echo "=========================================="

# Overall health check
HEALTH_OK=true

# Check service connection
if [ -z "$AWS_CONNECTION" ]; then
    HEALTH_OK=false
    print_status "error" "AWS service connection missing"
fi

# Check variable groups
if [ -z "$CONFIG_GROUP" ] || [ -z "$SECRETS_GROUP" ]; then
    HEALTH_OK=false
    print_status "error" "Required variable groups missing"
fi

# Check recent failures
if [ "${FAILED:-0}" -gt 2 ]; then
    HEALTH_OK=false
    print_status "warning" "Multiple recent failures detected"
fi

if [ "$HEALTH_OK" = true ]; then
    print_status "ok" "Azure DevOps pipelines are healthy"
else
    print_status "warning" "Some issues detected - review output above"
fi

echo ""
echo "Monitoring completed at $(date)"
echo "=========================================="
