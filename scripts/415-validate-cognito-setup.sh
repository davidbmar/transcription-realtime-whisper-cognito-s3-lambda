#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Script 415: Validate Cognito/S3/Lambda Setup
# ============================================================================
# Validates that script 410 completed successfully and all required files
# and configuration are in place before deployment.
#
# What this does:
# 1. Verifies .env contains required Cognito variables
# 2. Checks that cognito-stack directory exists with all required files
# 3. Validates serverless.yml structure
# 4. Checks AWS credentials and permissions
# 5. Verifies S3 bucket name availability (doesn't exist yet)
# 6. Validates Cognito domain availability
#
# Requirements:
# - .env variables: COGNITO_APP_NAME, COGNITO_S3_BUCKET, COGNITO_DOMAIN
# - cognito-stack directory with serverless.yml, package.json, handlers
#
# Total time: ~30 seconds
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

echo "============================================"
echo "415: Validate Cognito/S3/Lambda Setup"
echo "============================================"
echo ""

log_info "This script will:"
log_info "  1. Verify .env configuration"
log_info "  2. Check cognito-stack directory structure"
log_info "  3. Validate serverless.yml"
log_info "  4. Check AWS credentials"
log_info "  5. Validate resource naming"
echo ""

# ============================================================================
# Main Implementation
# ============================================================================

VALIDATION_PASSED=true

log_info "Step 1: Validating .env configuration"
# Check required variables
REQUIRED_VARS=("COGNITO_APP_NAME" "COGNITO_STAGE" "COGNITO_S3_BUCKET" "COGNITO_DOMAIN" "AWS_REGION" "AWS_ACCOUNT_ID")
MISSING_VARS=()

for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ]; then
        MISSING_VARS+=("$var")
    fi
done

if [ ${#MISSING_VARS[@]} -gt 0 ]; then
    log_error "❌ Missing required variables in .env: ${MISSING_VARS[*]}"
    log_error "Please run ./scripts/410-questions-setup-cognito-s3-lambda.sh first"
    VALIDATION_PASSED=false
else
    log_success "All required .env variables present"
    log_info "  - APP_NAME: $COGNITO_APP_NAME"
    log_info "  - STAGE: $COGNITO_STAGE"
    log_info "  - BUCKET: $COGNITO_S3_BUCKET"
    log_info "  - DOMAIN: $COGNITO_DOMAIN"
fi
echo ""

if [ "$VALIDATION_PASSED" = false ]; then
    exit 1
fi

log_info "Step 2: Validating cognito-stack directory structure"
COGNITO_DIR="$REPO_ROOT/cognito-stack"

if [ ! -d "$COGNITO_DIR" ]; then
    log_error "❌ Directory '$COGNITO_DIR' not found"
    log_error "Please run ./scripts/410-questions-setup-cognito-s3-lambda.sh first"
    exit 1
fi

# Check required files
REQUIRED_FILES=(
    "serverless.yml"
    "package.json"
    "api/handler.js"
    "functions/setIdentityPoolRoles.js"
    "web/index.html"
    "web/callback.html"
    "web/styles.css"
)

for file in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$COGNITO_DIR/$file" ]; then
        log_error "❌ File not found: $file"
        VALIDATION_PASSED=false
    fi
done

if [ "$VALIDATION_PASSED" = false ]; then
    log_error "Missing required files. Please run ./scripts/410-questions-setup-cognito-s3-lambda.sh again"
    exit 1
fi

log_success "All required files present"
echo ""

log_info "Step 3: Validating serverless.yml structure"
cd "$COGNITO_DIR"

# Check if serverless.yml contains expected resources
REQUIRED_RESOURCES=(
    "WebsiteBucket"
    "UserPool"
    "UserPoolClient"
    "IdentityPool"
    "AuthenticatedRole"
    "CloudFrontDistribution"
)

for resource in "${REQUIRED_RESOURCES[@]}"; do
    if ! grep -q "$resource:" serverless.yml; then
        log_error "❌ Resource '$resource' not found in serverless.yml"
        VALIDATION_PASSED=false
    fi
done

if [ "$VALIDATION_PASSED" = false ]; then
    log_error "serverless.yml is incomplete. Please run ./scripts/410-questions-setup-cognito-s3-lambda.sh again"
    exit 1
fi

log_success "serverless.yml structure validated"
echo ""

log_info "Step 4: Validating AWS credentials and permissions"
# Check AWS CLI is available
if ! command -v aws &> /dev/null; then
    log_error "❌ AWS CLI not found"
    exit 1
fi

# Check credentials work
if ! aws sts get-caller-identity &> /dev/null; then
    log_error "❌ AWS credentials not configured. Run 'aws configure' first"
    exit 1
fi

CALLER_IDENTITY=$(aws sts get-caller-identity --query Account --output text)
log_success "AWS credentials validated (Account: $CALLER_IDENTITY)"
echo ""

log_info "Step 5: Validating S3 bucket availability"
# Check if bucket already exists
if aws s3api head-bucket --bucket "$COGNITO_S3_BUCKET" 2>/dev/null; then
    log_error "❌ S3 bucket '$COGNITO_S3_BUCKET' already exists"
    log_error "Please choose a different bucket name and run ./scripts/410-questions-setup-cognito-s3-lambda.sh again"
    VALIDATION_PASSED=false
else
    log_success "S3 bucket name '$COGNITO_S3_BUCKET' is available"
fi
echo ""

log_info "Step 6: Validating Cognito domain"
# Check if domain contains reserved words
if [[ $COGNITO_DOMAIN == *cognito* || $COGNITO_DOMAIN == *aws* ]]; then
    log_error "❌ Cognito domain cannot contain reserved words 'cognito' or 'aws'"
    VALIDATION_PASSED=false
fi

# Check domain length
if [ ${#COGNITO_DOMAIN} -gt 63 ]; then
    log_error "❌ Cognito domain is too long (max 63 characters)"
    VALIDATION_PASSED=false
fi

# Check domain format
if [[ ! $COGNITO_DOMAIN =~ ^[a-z0-9-]+$ ]]; then
    log_error "❌ Cognito domain must only contain lowercase letters, numbers, and hyphens"
    VALIDATION_PASSED=false
fi

if [ "$VALIDATION_PASSED" = true ]; then
    log_success "Cognito domain '$COGNITO_DOMAIN' is valid"
fi
echo ""

# ============================================================================
# Success Reporting
# ============================================================================

echo ""
if [ "$VALIDATION_PASSED" = true ]; then
    log_info "==================================================================="
    log_success "✅ VALIDATION PASSED"
    log_info "==================================================================="
    echo ""
    log_info "Summary:"
    log_info "  - All required .env variables present"
    log_info "  - All required files in place"
    log_info "  - serverless.yml structure validated"
    log_info "  - AWS credentials working"
    log_info "  - S3 bucket name available"
    log_info "  - Cognito domain valid"
    echo ""
    log_info "Next Steps:"
    log_info "  1. Install Node.js dependencies: cd $COGNITO_DIR && npm install"
    log_info "  2. Deploy the stack: ./scripts/420-deploy-cognito-stack.sh"
    echo ""
    exit 0
else
    log_info "==================================================================="
    log_error "❌ VALIDATION FAILED"
    log_info "==================================================================="
    echo ""
    log_info "Please fix the errors above and run this script again."
    echo ""
    exit 1
fi
