#!/bin/bash
set -euo pipefail
mkdir -p "$(dirname "$0")/../logs"
exec > >(tee -a "$(dirname "$0")/../logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Script 499: Cleanup Cognito/S3/Lambda Stack
# ============================================================================
# Removes ALL resources created by the Cognito/S3/Lambda deployment.
# This operation is IRREVERSIBLE and will delete all data.
#
# Flow:
# 1. Display current .env configuration
# 2. Scan and display current state of AWS resources
# 3. Prompt for confirmation with resource list
# 4. Delete resources step-by-step with logging
# 5. Verify deletion was successful
#
# Requirements:
# - .env variables: COGNITO_APP_NAME, COGNITO_STAGE, COGNITO_S3_BUCKET
#
# Total time: ~10-15 minutes (CloudFormation deletion is slow)
# ============================================================================

# Find repository root (works from symlink or direct execution)
if [ -L "${BASH_SOURCE[0]}" ]; then
    SCRIPT_REAL=$(readlink -f "${BASH_SOURCE[0]}")
else
    SCRIPT_REAL="${BASH_SOURCE[0]}"
fi
REPO_ROOT="$(cd "$(dirname "$SCRIPT_REAL")/.." && pwd)"

source "$REPO_ROOT/scripts/lib/common-functions.sh"
load_environment

export AWS_PAGER=""

echo "============================================"
echo "499: Cleanup Cognito/S3/Lambda Stack"
echo "============================================"
echo ""
log_info "Timestamp: $(date)"
echo ""

# ============================================================================
# Step 1: Display Current Configuration
# ============================================================================

log_info "Step 1: Current .env Configuration"
echo "==================================================================="
log_info "  SERVICE_NAME:          ${SERVICE_NAME:-<not set>}"
log_info "  COGNITO_APP_NAME:      ${COGNITO_APP_NAME:-<not set>}"
log_info "  COGNITO_STAGE:         ${COGNITO_STAGE:-<not set>}"
log_info "  COGNITO_S3_BUCKET:     ${COGNITO_S3_BUCKET:-<not set>}"
log_info "  COGNITO_DOMAIN:        ${COGNITO_DOMAIN:-<not set>}"
log_info "  COGNITO_USER_POOL_ID:  ${COGNITO_USER_POOL_ID:-<not set>}"
log_info "  COGNITO_CLOUDFRONT_URL: ${COGNITO_CLOUDFRONT_URL:-<not set>}"
echo "==================================================================="
echo ""

# Use SERVICE_NAME if set (matches serverless.yml), otherwise fall back to COGNITO_APP_NAME
STACK_SERVICE="${SERVICE_NAME:-${COGNITO_APP_NAME:-clouddrive-app}}"
STACK_NAME="${STACK_SERVICE}-${COGNITO_STAGE}"
log_info "  Stack Name to Delete:  $STACK_NAME"
echo ""

# ============================================================================
# Step 2: Scan Current State of Resources
# ============================================================================

log_info "Step 2: Scanning current state of AWS resources..."
echo ""

RESOURCES_FOUND=0

# Check CloudFormation stack
log_info "Checking CloudFormation stack: $STACK_NAME"
STACK_EXISTS=false
if aws cloudformation describe-stacks --stack-name "$STACK_NAME" &>/dev/null; then
    STACK_STATUS=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
        --query "Stacks[0].StackStatus" --output text 2>/dev/null)
    log_warn "  ⚠️  Stack EXISTS (status: $STACK_STATUS)"
    STACK_EXISTS=true
    RESOURCES_FOUND=$((RESOURCES_FOUND + 1))
else
    log_info "  ✅ Stack not found (already deleted or never created)"
fi

# Check S3 website bucket
log_info "Checking S3 website bucket: ${COGNITO_S3_BUCKET:-<not set>}"
WEBSITE_BUCKET_EXISTS=false
if [ -n "${COGNITO_S3_BUCKET:-}" ] && aws s3api head-bucket --bucket "$COGNITO_S3_BUCKET" 2>/dev/null; then
    OBJECT_COUNT=$(aws s3 ls "s3://$COGNITO_S3_BUCKET" --recursive 2>/dev/null | wc -l || echo "0")
    log_warn "  ⚠️  Bucket EXISTS ($OBJECT_COUNT objects)"
    WEBSITE_BUCKET_EXISTS=true
    RESOURCES_FOUND=$((RESOURCES_FOUND + 1))
else
    log_info "  ✅ Bucket not found"
fi

# Check deployment buckets
log_info "Checking serverless deployment buckets..."
DEPLOYMENT_BUCKETS=""
ALL_BUCKETS=$(aws s3 ls 2>/dev/null | awk '{print $3}' || echo "")
BUCKET_PATTERNS=(
    "${STACK_SERVICE}-${COGNITO_STAGE}-serverlessdeployment"
    "${STACK_SERVICE}-serverlessdeploymentbucket"
    "${COGNITO_APP_NAME:-notset}-${COGNITO_STAGE}-serverlessdeployment"
    "${COGNITO_APP_NAME:-notset}-serverlessdeploymentbucket"
)
for pattern in "${BUCKET_PATTERNS[@]}"; do
    MATCHING=$(echo "$ALL_BUCKETS" | grep "^${pattern}" 2>/dev/null || true)
    if [ -n "$MATCHING" ]; then
        DEPLOYMENT_BUCKETS="$DEPLOYMENT_BUCKETS $MATCHING"
    fi
done
DEPLOYMENT_BUCKETS=$(echo "$DEPLOYMENT_BUCKETS" | tr ' ' '\n' | sort -u | tr '\n' ' ' | xargs)

if [ -n "$DEPLOYMENT_BUCKETS" ]; then
    for bucket in $DEPLOYMENT_BUCKETS; do
        log_warn "  ⚠️  Deployment bucket: $bucket"
    done
    RESOURCES_FOUND=$((RESOURCES_FOUND + 1))
else
    log_info "  ✅ No deployment buckets found"
fi

# Check Cognito User Pool
log_info "Checking Cognito User Pool..."
if [ -n "${COGNITO_USER_POOL_ID:-}" ]; then
    if aws cognito-idp describe-user-pool --user-pool-id "$COGNITO_USER_POOL_ID" &>/dev/null; then
        USER_COUNT=$(aws cognito-idp list-users --user-pool-id "$COGNITO_USER_POOL_ID" \
            --query "length(Users)" --output text 2>/dev/null || echo "0")
        log_warn "  ⚠️  User Pool EXISTS ($USER_COUNT users)"
        RESOURCES_FOUND=$((RESOURCES_FOUND + 1))
    else
        log_info "  ✅ User Pool not found"
    fi
else
    log_info "  ✅ No User Pool ID in .env"
fi

# Check Lambda functions
log_info "Checking Lambda functions..."
LAMBDA_FUNCTIONS=$(aws lambda list-functions \
    --query "Functions[?contains(FunctionName, '${STACK_SERVICE}-${COGNITO_STAGE}')].FunctionName" \
    --output text 2>/dev/null || echo "")
if [ -n "$LAMBDA_FUNCTIONS" ] && [ "$LAMBDA_FUNCTIONS" != "None" ]; then
    LAMBDA_COUNT=$(echo "$LAMBDA_FUNCTIONS" | wc -w)
    log_warn "  ⚠️  $LAMBDA_COUNT Lambda functions exist"
    RESOURCES_FOUND=$((RESOURCES_FOUND + 1))
else
    log_info "  ✅ No Lambda functions found"
fi

# Check CloudFront
log_info "Checking CloudFront distribution..."
if [ -n "${COGNITO_CLOUDFRONT_URL:-}" ] && [ "$COGNITO_CLOUDFRONT_URL" != "https://placeholder.cloudfront.net" ]; then
    CF_DOMAIN=$(echo "$COGNITO_CLOUDFRONT_URL" | sed 's|https://||')
    CF_ID=$(aws cloudfront list-distributions \
        --query "DistributionList.Items[?DomainName=='${CF_DOMAIN}'].Id" \
        --output text 2>/dev/null || echo "")
    if [ -n "$CF_ID" ] && [ "$CF_ID" != "None" ]; then
        log_warn "  ⚠️  CloudFront distribution EXISTS: $CF_ID"
        RESOURCES_FOUND=$((RESOURCES_FOUND + 1))
    else
        log_info "  ✅ CloudFront distribution not found"
    fi
else
    log_info "  ✅ No CloudFront URL in .env"
fi

# Check CloudWatch log groups
log_info "Checking CloudWatch log groups..."
LOG_GROUPS=$(aws logs describe-log-groups \
    --log-group-name-prefix "/aws/lambda/${STACK_SERVICE}-${COGNITO_STAGE}" \
    --query "logGroups[].logGroupName" --output text 2>/dev/null || echo "")
if [ -n "$LOG_GROUPS" ] && [ "$LOG_GROUPS" != "None" ]; then
    LOG_COUNT=$(echo "$LOG_GROUPS" | wc -w)
    log_warn "  ⚠️  $LOG_COUNT CloudWatch log groups exist"
    RESOURCES_FOUND=$((RESOURCES_FOUND + 1))
else
    log_info "  ✅ No log groups found"
fi

echo ""
echo "==================================================================="
if [ $RESOURCES_FOUND -eq 0 ]; then
    log_success "No resources found to delete. Cleanup not needed."
    exit 0
else
    log_warn "Found $RESOURCES_FOUND resource type(s) to delete"
fi
echo "==================================================================="
echo ""

# ============================================================================
# Step 3: Confirmation Prompts
# ============================================================================

log_warn "⚠️  WARNING: This script will delete ALL resources listed above!"
log_warn "⚠️  This includes:"
log_warn "  - S3 bucket and all website files"
log_warn "  - CloudFront distribution"
log_warn "  - Cognito User Pool and all users"
log_warn "  - Lambda functions"
log_warn "  - API Gateway"
echo ""
log_error "⚠️  THIS OPERATION CANNOT BE UNDONE!"
echo ""

read -p "Are you ABSOLUTELY sure you want to continue? (type 'yes' to confirm): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    log_info "Cleanup aborted by user."
    exit 0
fi

echo ""
# Use COGNITO_APP_NAME for confirmation, but show SERVICE_NAME if different
CONFIRM_NAME="${COGNITO_APP_NAME:-$STACK_SERVICE}"
read -p "⚠️  Last chance! Type the application name '$CONFIRM_NAME' to confirm: " APP_NAME_CONFIRM

if [ "$APP_NAME_CONFIRM" != "$CONFIRM_NAME" ]; then
    log_error "❌ App name doesn't match. Cleanup aborted."
    exit 1
fi

echo ""
log_info "🧹 Starting cleanup process..."
log_info "Timestamp: $(date)"
echo ""

# ============================================================================
# Step 4: Main Cleanup Implementation
# ============================================================================

log_info "Stack name: $STACK_NAME"

log_info "Step 4a: Deleting Lambda log groups"
# List and delete log groups with our app name prefix
LOG_GROUPS=$(aws logs describe-log-groups \
    --log-group-name-prefix "/aws/lambda/${COGNITO_APP_NAME}-${COGNITO_STAGE}" \
    --query "logGroups[*].logGroupName" \
    --output text 2>/dev/null || echo "")

if [ -n "$LOG_GROUPS" ]; then
    for log_group in $LOG_GROUPS; do
        log_info "Deleting log group: $log_group"
        aws logs delete-log-group --log-group-name "$log_group" 2>/dev/null || log_warn "⚠️  Failed to delete log group"
    done
    log_success "Lambda log groups deleted"
else
    log_info "No Lambda log groups found"
fi
echo ""

log_info "Step 4b: Finding serverless deployment buckets"
# Check if stack exists and find deployment buckets from CloudFormation
DEPLOYMENT_BUCKETS=""
if aws cloudformation describe-stacks --stack-name "$STACK_NAME" &>/dev/null; then
    DEPLOYMENT_BUCKETS=$(aws cloudformation describe-stack-resources \
        --stack-name "$STACK_NAME" \
        --query "StackResources[?ResourceType=='AWS::S3::Bucket' && contains(LogicalResourceId, 'ServerlessDeployment')].PhysicalResourceId" \
        --output text 2>/dev/null || echo "")
fi

# Also search for deployment buckets by name patterns (matches both SERVICE_NAME and COGNITO_APP_NAME patterns)
BUCKET_PATTERNS=(
    "${STACK_SERVICE}-${COGNITO_STAGE}-serverlessdeployment"
    "${STACK_SERVICE}-serverlessdeploymentbucket"
    "${COGNITO_APP_NAME:-notset}-${COGNITO_STAGE}-serverlessdeployment"
    "${COGNITO_APP_NAME:-notset}-serverlessdeploymentbucket"
)

# Search for buckets matching any pattern
ALL_BUCKETS=$(aws s3 ls 2>/dev/null | awk '{print $3}')
for pattern in "${BUCKET_PATTERNS[@]}"; do
    MATCHING=$(echo "$ALL_BUCKETS" | grep "^${pattern}" 2>/dev/null || true)
    if [ -n "$MATCHING" ]; then
        DEPLOYMENT_BUCKETS="$DEPLOYMENT_BUCKETS $MATCHING"
    fi
done

# Remove duplicates
DEPLOYMENT_BUCKETS=$(echo "$DEPLOYMENT_BUCKETS" | tr ' ' '\n' | sort -u | tr '\n' ' ' | xargs)

if [ -n "$DEPLOYMENT_BUCKETS" ]; then
    echo ""
    log_warn "Found deployment buckets to delete:"
    for bucket in $DEPLOYMENT_BUCKETS; do
        echo "  - $bucket"
    done
    echo ""
    read -p "Empty and delete these buckets? [Y/n]: " CONFIRM_BUCKETS
    CONFIRM_BUCKETS="${CONFIRM_BUCKETS:-Y}"

    if [[ "$CONFIRM_BUCKETS" =~ ^[Yy] ]]; then
        for bucket in $DEPLOYMENT_BUCKETS; do
            log_info "Emptying bucket: $bucket"
            aws s3 rm "s3://$bucket" --recursive 2>/dev/null || log_warn "⚠️  Failed to empty bucket"
            log_info "Deleting bucket: $bucket"
            aws s3 rb "s3://$bucket" --force 2>/dev/null || log_warn "⚠️  Failed to delete bucket"
        done
        log_success "Deployment buckets cleaned up"
    else
        log_warn "Skipping bucket deletion - stack deletion may fail"
    fi
else
    log_info "No deployment buckets found"
fi
echo ""

log_info "Step 4c: Emptying S3 website bucket"
if [ -n "$COGNITO_S3_BUCKET" ]; then
    if aws s3api head-bucket --bucket "$COGNITO_S3_BUCKET" 2>/dev/null; then
        log_info "Emptying S3 bucket: $COGNITO_S3_BUCKET"
        aws s3 rm "s3://$COGNITO_S3_BUCKET" --recursive 2>/dev/null || log_warn "⚠️  Failed to empty bucket"
        log_success "S3 bucket emptied"
    else
        log_info "S3 bucket $COGNITO_S3_BUCKET does not exist or is not accessible"
    fi
else
    log_info "No S3 bucket name in .env"
fi
echo ""

log_info "Step 4d: Deleting Cognito User Pool domain"
if [ -n "${COGNITO_USER_POOL_ID:-}" ] && [ -n "$COGNITO_DOMAIN" ]; then
    log_info "Deleting Cognito domain: $COGNITO_DOMAIN"
    aws cognito-idp delete-user-pool-domain \
        --user-pool-id "$COGNITO_USER_POOL_ID" \
        --domain "$COGNITO_DOMAIN" 2>/dev/null || log_warn "⚠️  Failed to delete Cognito domain"
    log_success "Cognito domain deleted"
else
    log_info "No Cognito domain to delete"
fi
echo ""

log_info "Step 4e: Checking for CloudFront invalidations"
if [ -n "${COGNITO_CLOUDFRONT_URL:-}" ]; then
    DISTRIBUTION_ID=$(aws cloudfront list-distributions \
        --query "DistributionList.Items[?contains(DomainName, '$(echo $COGNITO_CLOUDFRONT_URL | sed 's|https://||')')]|[0].Id" \
        --output text 2>/dev/null || echo "")

    if [ -n "$DISTRIBUTION_ID" ] && [ "$DISTRIBUTION_ID" != "None" ]; then
        log_info "Found CloudFront distribution: $DISTRIBUTION_ID"

        INVALIDATIONS=$(aws cloudfront list-invalidations \
            --distribution-id "$DISTRIBUTION_ID" \
            --query "InvalidationList.Items[?Status=='InProgress'].Id" \
            --output text 2>/dev/null || echo "")

        if [ -n "$INVALIDATIONS" ]; then
            log_warn "⏳ Waiting for CloudFront invalidations to complete..."
            for invalidation_id in $INVALIDATIONS; do
                log_info "Waiting for invalidation $invalidation_id..."
                aws cloudfront wait invalidation-completed \
                    --distribution-id "$DISTRIBUTION_ID" \
                    --id "$invalidation_id" 2>/dev/null || log_warn "⚠️  Wait failed"
            done
            log_success "CloudFront invalidations completed"
        else
            log_info "No active CloudFront invalidations"
        fi
    else
        log_info "CloudFront distribution not found"
    fi
else
    log_info "No CloudFront URL in .env"
fi
echo ""

log_info "Step 4f: Deleting CloudFormation stack"
log_warn "⏳ This may take 10-15 minutes..."
echo ""

if aws cloudformation describe-stacks --stack-name "$STACK_NAME" &>/dev/null; then
    log_info "Deleting CloudFormation stack: $STACK_NAME"
    aws cloudformation delete-stack --stack-name "$STACK_NAME"

    log_info "Waiting for stack deletion to complete..."
    if aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" 2>/dev/null; then
        log_success "CloudFormation stack deleted successfully"
    else
        log_warn "⚠️  Stack deletion wait failed, checking status..."

        # Check if stack is in DELETE_FAILED state
        STACK_STATUS=$(aws cloudformation describe-stacks \
            --stack-name "$STACK_NAME" \
            --query "Stacks[0].StackStatus" \
            --output text 2>/dev/null || echo "DELETED")

        if [ "$STACK_STATUS" = "DELETE_FAILED" ]; then
            log_error "⚠️  Stack is in DELETE_FAILED state"
            log_info "Finding resources that failed to delete..."

            FAILED_RESOURCES=$(aws cloudformation describe-stack-resources \
                --stack-name "$STACK_NAME" \
                --query "StackResources[?ResourceStatus=='DELETE_FAILED'].[LogicalResourceId,ResourceType,PhysicalResourceId]" \
                --output text 2>/dev/null || echo "")

            if [ -n "$FAILED_RESOURCES" ]; then
                echo "$FAILED_RESOURCES" | while read logical_id resource_type physical_id; do
                    log_warn "Failed to delete: $logical_id ($resource_type) - $physical_id"
                done
            fi

            log_info "⚠️  You may need to manually delete failed resources in AWS Console"
        else
            log_success "Stack deletion completed (status: $STACK_STATUS)"
        fi
    fi
else
    log_info "CloudFormation stack $STACK_NAME does not exist"
fi
echo ""

log_info "Step 4g: Cleaning up .env variables"
# Comment out Cognito variables in .env
if grep -q "^COGNITO_USER_POOL_ID=" .env 2>/dev/null; then
    sed -i.bak "s|^COGNITO_USER_POOL_ID=|# COGNITO_USER_POOL_ID=|" .env
    sed -i.bak "s|^COGNITO_USER_POOL_CLIENT_ID=|# COGNITO_USER_POOL_CLIENT_ID=|" .env
    sed -i.bak "s|^COGNITO_IDENTITY_POOL_ID=|# COGNITO_IDENTITY_POOL_ID=|" .env
    sed -i.bak "s|^COGNITO_API_ENDPOINT=|# COGNITO_API_ENDPOINT=|" .env
    sed -i.bak "s|^COGNITO_CLOUDFRONT_URL=|# COGNITO_CLOUDFRONT_URL=|" .env
    log_success "Commented out deployed resource IDs in .env"
else
    log_info "No Cognito resource IDs found in .env"
fi
echo ""

# ============================================================================
# Verification - Check that resources are actually deleted
# ============================================================================

echo ""
log_info "Step 5: Verifying resources are deleted"
echo ""

RESOURCES_REMAINING=0

# Check CloudFormation stack
log_info "Checking CloudFormation stack..."
if aws cloudformation describe-stacks --stack-name "$STACK_NAME" &>/dev/null; then
    STACK_STATUS=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
        --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "UNKNOWN")
    log_warn "  ⚠️  Stack still exists (status: $STACK_STATUS)"
    RESOURCES_REMAINING=$((RESOURCES_REMAINING + 1))
else
    log_success "  ✅ CloudFormation stack deleted"
fi

# Check S3 buckets
log_info "Checking S3 buckets..."
REMAINING_BUCKETS=$(aws s3 ls 2>/dev/null | awk '{print $3}' | grep -E "^(${STACK_SERVICE}|${COGNITO_APP_NAME:-notset})" || true)
if [ -n "$REMAINING_BUCKETS" ]; then
    log_warn "  ⚠️  S3 buckets still exist:"
    echo "$REMAINING_BUCKETS" | while read bucket; do
        echo "      - $bucket"
    done
    RESOURCES_REMAINING=$((RESOURCES_REMAINING + 1))
else
    log_success "  ✅ S3 buckets deleted"
fi

# Check Cognito User Pools
log_info "Checking Cognito User Pools..."
REMAINING_POOLS=$(aws cognito-idp list-user-pools --max-results 20 \
    --query "UserPools[?contains(Name, '${COGNITO_APP_NAME:-notset}') || contains(Name, '${STACK_SERVICE}')].Name" \
    --output text 2>/dev/null || echo "")
if [ -n "$REMAINING_POOLS" ] && [ "$REMAINING_POOLS" != "None" ]; then
    log_warn "  ⚠️  Cognito User Pools still exist: $REMAINING_POOLS"
    RESOURCES_REMAINING=$((RESOURCES_REMAINING + 1))
else
    log_success "  ✅ Cognito User Pools deleted"
fi

# Check Lambda functions
log_info "Checking Lambda functions..."
REMAINING_LAMBDAS=$(aws lambda list-functions \
    --query "Functions[?contains(FunctionName, '${STACK_SERVICE}-${COGNITO_STAGE}')].FunctionName" \
    --output text 2>/dev/null || echo "")
if [ -n "$REMAINING_LAMBDAS" ] && [ "$REMAINING_LAMBDAS" != "None" ]; then
    LAMBDA_COUNT=$(echo "$REMAINING_LAMBDAS" | wc -w)
    log_warn "  ⚠️  Lambda functions still exist: $LAMBDA_COUNT functions"
    RESOURCES_REMAINING=$((RESOURCES_REMAINING + 1))
else
    log_success "  ✅ Lambda functions deleted"
fi

# Check API Gateway
log_info "Checking API Gateway..."
REMAINING_APIS=$(aws apigateway get-rest-apis \
    --query "items[?contains(name, '${STACK_SERVICE}') || contains(name, '${COGNITO_APP_NAME:-notset}')].name" \
    --output text 2>/dev/null || echo "")
if [ -n "$REMAINING_APIS" ] && [ "$REMAINING_APIS" != "None" ]; then
    log_warn "  ⚠️  API Gateway still exists: $REMAINING_APIS"
    RESOURCES_REMAINING=$((RESOURCES_REMAINING + 1))
else
    log_success "  ✅ API Gateway deleted"
fi

# Check CloudFront distributions
log_info "Checking CloudFront distributions..."
REMAINING_CF=$(aws cloudfront list-distributions \
    --query "DistributionList.Items[?contains(Comment, '${STACK_SERVICE}') || contains(Comment, '${COGNITO_APP_NAME:-notset}')].Id" \
    --output text 2>/dev/null || echo "")
if [ -n "$REMAINING_CF" ] && [ "$REMAINING_CF" != "None" ]; then
    log_warn "  ⚠️  CloudFront distributions still exist: $REMAINING_CF"
    RESOURCES_REMAINING=$((RESOURCES_REMAINING + 1))
else
    log_success "  ✅ CloudFront distributions deleted"
fi

# Check CloudWatch log groups
log_info "Checking CloudWatch log groups..."
REMAINING_LOGS=$(aws logs describe-log-groups \
    --log-group-name-prefix "/aws/lambda/${STACK_SERVICE}-${COGNITO_STAGE}" \
    --query "logGroups[].logGroupName" --output text 2>/dev/null || echo "")
if [ -n "$REMAINING_LOGS" ] && [ "$REMAINING_LOGS" != "None" ]; then
    LOG_COUNT=$(echo "$REMAINING_LOGS" | wc -w)
    log_warn "  ⚠️  CloudWatch log groups still exist: $LOG_COUNT groups"
    RESOURCES_REMAINING=$((RESOURCES_REMAINING + 1))
else
    log_success "  ✅ CloudWatch log groups deleted"
fi

echo ""

# ============================================================================
# Success Reporting
# ============================================================================

echo ""
log_info "==================================================================="
if [ $RESOURCES_REMAINING -eq 0 ]; then
    log_success "✅ CLEANUP COMPLETED - ALL RESOURCES DELETED"
else
    log_warn "⚠️  CLEANUP COMPLETED - $RESOURCES_REMAINING RESOURCE TYPE(S) REMAINING"
    log_info "Some resources may still be deleting or require manual cleanup."
    log_info "Run this script again in a few minutes to re-check."
fi
log_info "==================================================================="
echo ""
log_info "Summary:"
log_info "  - Lambda log groups deleted"
log_info "  - S3 buckets emptied and deleted"
log_info "  - Cognito domain deleted"
log_info "  - CloudFormation stack deleted"
log_info "  - .env variables commented out"
echo ""
log_info "To redeploy, run:"
log_info "  1. ./scripts/410-configure-cognito-variables.sh"
log_info "  2. ./scripts/420-deploy-cognito-stack.sh"
echo ""
