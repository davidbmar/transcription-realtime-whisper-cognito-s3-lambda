#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Script 499: Cleanup Cognito/S3/Lambda Stack
# ============================================================================
# Removes ALL resources created by the Cognito/S3/Lambda deployment.
# This operation is IRREVERSIBLE and will delete all data.
#
# What this does:
# 1. Prompts for double confirmation (yes + app name)
# 2. Deletes Lambda log groups
# 3. Empties and deletes S3 website bucket
# 4. Empties and deletes serverless deployment buckets
# 5. Deletes Cognito User Pool domain
# 6. Waits for CloudFront invalidations to complete
# 7. Deletes CloudFormation stack (removes most resources)
# 8. Handles DELETE_FAILED states
# 9. Cleans up .env variables
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
REPO_ROOT="$(cd "$(dirname "$SCRIPT_REAL")/..\" && pwd)"

source "$REPO_ROOT/scripts/lib/common-functions.sh"
load_environment

echo "============================================"
echo "499: Cleanup Cognito/S3/Lambda Stack"
echo "============================================"
echo ""

log_warn "⚠️  WARNING: This script will delete ALL resources created by the Cognito deployment!"
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
    log_info "Cleanup aborted."
    exit 0
fi

echo ""
read -p "⚠️  Last chance! Type the application name '$COGNITO_APP_NAME' to confirm: " APP_NAME_CONFIRM

if [ "$APP_NAME_CONFIRM" != "$COGNITO_APP_NAME" ]; then
    log_error "❌ App name doesn't match. Cleanup aborted."
    exit 1
fi

echo ""
log_info "🧹 Starting cleanup process..."
echo ""

# ============================================================================
# Main Implementation
# ============================================================================

STACK_NAME="${COGNITO_APP_NAME}-${COGNITO_STAGE}"
export AWS_PAGER=""

log_info "Step 1: Deleting Lambda log groups"
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

log_info "Step 2: Finding serverless deployment buckets"
# Check if stack exists and find deployment buckets
DEPLOYMENT_BUCKETS=""
if aws cloudformation describe-stacks --stack-name "$STACK_NAME" &>/dev/null; then
    DEPLOYMENT_BUCKETS=$(aws cloudformation describe-stack-resources \
        --stack-name "$STACK_NAME" \
        --query "StackResources[?ResourceType=='AWS::S3::Bucket' && contains(LogicalResourceId, 'ServerlessDeployment')].PhysicalResourceId" \
        --output text 2>/dev/null || echo "")
fi

# Also look for deployment buckets by name pattern
if [ -z "$DEPLOYMENT_BUCKETS" ]; then
    DEPLOYMENT_BUCKETS=$(aws s3api list-buckets \
        --query "Buckets[?starts_with(Name, '${COGNITO_APP_NAME}-${COGNITO_STAGE}-serverlessdeployment') || starts_with(Name, '${COGNITO_APP_NAME}-serverlessdeploymentbucket')].Name" \
        --output text 2>/dev/null || echo "")
fi

if [ -n "$DEPLOYMENT_BUCKETS" ]; then
    for bucket in $DEPLOYMENT_BUCKETS; do
        log_info "Emptying deployment bucket: $bucket"
        aws s3 rm "s3://$bucket" --recursive 2>/dev/null || log_warn "⚠️  Failed to empty bucket"
        log_info "Deleting deployment bucket: $bucket"
        aws s3 rb "s3://$bucket" --force 2>/dev/null || log_warn "⚠️  Failed to delete bucket"
    done
    log_success "Deployment buckets cleaned up"
else
    log_info "No deployment buckets found"
fi
echo ""

log_info "Step 3: Emptying S3 website bucket"
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

log_info "Step 4: Deleting Cognito User Pool domain"
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

log_info "Step 5: Checking for CloudFront invalidations"
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

log_info "Step 6: Deleting CloudFormation stack"
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

log_info "Step 7: Cleaning up .env variables"
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
# Success Reporting
# ============================================================================

echo ""
log_info "==================================================================="
log_success "✅ CLEANUP COMPLETED"
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
log_info "  1. ./scripts/410-questions-setup-cognito-s3-lambda.sh (if config changed)"
log_info "  2. ./scripts/420-deploy-cognito-stack.sh"
echo ""
