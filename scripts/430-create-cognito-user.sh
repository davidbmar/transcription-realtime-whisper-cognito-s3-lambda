#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Script 430: Create Cognito User
# ============================================================================
# Creates a test user in the Cognito User Pool for authentication testing.
#
# What this does:
# 1. Validates Cognito User Pool ID exists in .env
# 2. Prompts for user email address
# 3. Validates email format
# 4. Creates user in Cognito with temporary password
# 5. Prompts for permanent password
# 6. Validates password complexity (8+ chars, upper, lower, number)
# 7. Sets permanent password for the user
# 8. Marks email as verified
#
# Requirements:
# - .env variables: COGNITO_USER_POOL_ID, COGNITO_CLOUDFRONT_URL
# - Script 420 completed successfully (stack deployed)
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
echo "430: Create Cognito User"
echo "============================================"
echo ""

log_info "This script will:"
log_info "  1. Validate Cognito User Pool exists"
log_info "  2. Prompt for user email"
log_info "  3. Create user in Cognito"
log_info "  4. Set permanent password"
echo ""

# ============================================================================
# Main Implementation
# ============================================================================

log_info "Step 1: Validating prerequisites"
if [ -z "${COGNITO_USER_POOL_ID:-}" ]; then
    log_error "❌ COGNITO_USER_POOL_ID not found in .env"
    log_error "Please run ./scripts/420-deploy-cognito-stack.sh first"
    exit 1
fi

log_success "User Pool ID validated: $COGNITO_USER_POOL_ID"
echo ""

log_info "Step 2: Getting user email"
echo ""
read -p "Enter email for the test user: " USER_EMAIL

if [ -z "$USER_EMAIL" ]; then
    log_error "❌ Email cannot be empty"
    exit 1
fi

# Validate email format (basic validation)
if [[ ! $USER_EMAIL =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    log_error "❌ Invalid email format"
    exit 1
fi

log_success "Email validated: $USER_EMAIL"
echo ""

log_info "Step 3: Creating user in Cognito User Pool"
# Generate a random temporary password that meets Cognito requirements
TEMP_PASSWORD="TempPass$(date +%s)!"

aws cognito-idp admin-create-user \
    --user-pool-id "$COGNITO_USER_POOL_ID" \
    --username "$USER_EMAIL" \
    --temporary-password "$TEMP_PASSWORD" \
    --user-attributes Name=email,Value="$USER_EMAIL" Name=email_verified,Value=true \
    &> /dev/null

log_success "User created successfully"
echo ""

log_info "Step 4: Setting permanent password"
echo ""
log_info "⚠️  Password requirements:"
log_info "  - Minimum 8 characters"
log_info "  - Must contain uppercase letter (A-Z)"
log_info "  - Must contain lowercase letter (a-z)"
log_info "  - Must contain number (0-9)"
echo ""
read -s -p "Enter a permanent password for the user: " USER_PASSWORD
echo ""

if [ -z "$USER_PASSWORD" ]; then
    log_error "❌ Password cannot be empty"
    exit 1
fi

# Validate password complexity
if [ ${#USER_PASSWORD} -lt 8 ]; then
    log_error "❌ Password must be at least 8 characters"
    exit 1
fi

if [[ ! $USER_PASSWORD =~ [A-Z] ]]; then
    log_error "❌ Password must contain at least one uppercase letter"
    exit 1
fi

if [[ ! $USER_PASSWORD =~ [a-z] ]]; then
    log_error "❌ Password must contain at least one lowercase letter"
    exit 1
fi

if [[ ! $USER_PASSWORD =~ [0-9] ]]; then
    log_error "❌ Password must contain at least one number"
    exit 1
fi

aws cognito-idp admin-set-user-password \
    --user-pool-id "$COGNITO_USER_POOL_ID" \
    --username "$USER_EMAIL" \
    --password "$USER_PASSWORD" \
    --permanent \
    &> /dev/null

log_success "Permanent password set"
echo ""

# ============================================================================
# Success Reporting
# ============================================================================

echo ""
log_info "==================================================================="
log_success "✅ COGNITO USER CREATED SUCCESSFULLY"
log_info "==================================================================="
echo ""
log_info "👤 Test User Details:"
log_info "  - Email: $USER_EMAIL"
log_info "  - Password: (the password you entered)"
echo ""
log_info "🔗 Login URL:"
log_info "  - ${COGNITO_CLOUDFRONT_URL:-CloudFront URL not set}"
echo ""
log_info "Next Steps:"
log_info "  1. Visit the CloudFront URL in your browser"
log_info "  2. Click 'Sign In' button"
log_info "  3. Enter the email and password you just created"
log_info "  4. Test the Lambda API by clicking 'Test Lambda API' button"
echo ""
log_info "Additional users can be created by running this script again."
echo ""
