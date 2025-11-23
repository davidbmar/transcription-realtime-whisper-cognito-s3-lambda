#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Script 620: Deploy Upload Audio Feature - Frontend
# ============================================================================
# Deploys the frontend components for the uploaded audio file feature:
# - Updated index.html with "Upload Audio" card and upload section
# - JavaScript functions for file upload, drag & drop, progress tracking
# - CSS styling for upload area
#
# What this does:
# 1. Validates prerequisites (backend deployed, .env configured)
# 2. Processes ui-source/index.html (replaces TO_BE_REPLACED_* placeholders)
# 3. Uploads updated index.html to S3
# 4. Invalidates CloudFront cache for index.html
# 5. Verifies deployment by checking for "Upload Audio" text
#
# Requirements:
# - Script 610 completed successfully (backend deployed)
# - AWS CLI configured with proper credentials
# - ui-source/index.html contains upload feature implementation
#
# Total time: ~2-3 minutes (+ CloudFront cache propagation ~5 min)
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
echo "620: Deploy Upload Audio Frontend"
echo "============================================"
echo ""

log_info "This script will:"
log_info "  1. Validate prerequisites"
log_info "  2. Process ui-source/index.html template"
log_info "  3. Upload to S3"
log_info "  4. Invalidate CloudFront cache"
log_info "  5. Verify deployment"
echo ""

# ============================================================================
# Main Implementation
# ============================================================================

log_info "Step 1: Validating prerequisites"

# Validate required .env variables
if [ -z "${COGNITO_S3_BUCKET:-}" ] || [ -z "${COGNITO_API_ENDPOINT:-}" ] || [ -z "${COGNITO_CLOUDFRONT_URL:-}" ]; then
    log_error "❌ Missing required variables in .env"
    log_error "Please run ./scripts/420-deploy-cognito-stack.sh first"
    exit 1
fi

# Check ui-source/index.html exists
UI_SOURCE="$REPO_ROOT/ui-source/index.html"
if [ ! -f "$UI_SOURCE" ]; then
    log_error "❌ ui-source/index.html not found"
    exit 1
fi

# Verify index.html contains upload feature
if ! grep -q "Upload Audio" "$UI_SOURCE"; then
    log_error "❌ Upload Audio feature not found in ui-source/index.html"
    log_error "Please ensure the upload audio feature is implemented"
    exit 1
fi

if ! grep -q "showUploadAudio" "$UI_SOURCE"; then
    log_error "❌ showUploadAudio function not found in ui-source/index.html"
    log_error "Please ensure the upload audio JavaScript is implemented"
    exit 1
fi

# Check AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
    log_error "❌ AWS credentials not configured. Run 'aws configure' first"
    exit 1
fi

log_success "Prerequisites validated"
echo ""

log_info "Step 2: Processing ui-source/index.html template"

# Create temporary directory for processed files
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Copy index.html to temp directory
cp "$UI_SOURCE" "$TEMP_DIR/index.html"

# Note: index.html doesn't use TO_BE_REPLACED_* placeholders currently
# It uses config object from app.js which is already deployed
# We just need to upload the file as-is

log_success "Template processed"
log_info "  - Source: ui-source/index.html"
log_info "  - Target: s3://$COGNITO_S3_BUCKET/index.html"
echo ""

log_info "Step 3: Uploading index.html to S3"
aws s3 cp "$TEMP_DIR/index.html" "s3://$COGNITO_S3_BUCKET/index.html" \
    --content-type "text/html" \
    --cache-control "no-cache"

log_success "index.html uploaded to S3"
echo ""

log_info "Step 4: Invalidating CloudFront cache"
export AWS_PAGER=""

# Get CloudFront distribution ID
DISTRIBUTION_ID=$(aws cloudfront list-distributions \
    --query "DistributionList.Items[?DomainName=='$(echo $COGNITO_CLOUDFRONT_URL | sed 's|https://||')'].Id" \
    --output text)

if [ -n "$DISTRIBUTION_ID" ] && [ "$DISTRIBUTION_ID" != "None" ]; then
    log_info "Creating cache invalidation for /index.html..."
    INVALIDATION_ID=$(aws cloudfront create-invalidation \
        --distribution-id "$DISTRIBUTION_ID" \
        --paths "/index.html" \
        --query 'Invalidation.Id' \
        --output text)

    log_success "✅ CloudFront cache invalidation created: $INVALIDATION_ID"
    log_warn "⚠️  Cache propagation may take 3-5 minutes"
else
    log_warn "⚠️  Could not determine CloudFront distribution ID"
fi
echo ""

log_info "Step 5: Verifying deployment"
log_info "Waiting 5 seconds for S3 to sync..."
sleep 5

# Verify file exists in S3
if aws s3 ls "s3://$COGNITO_S3_BUCKET/index.html" &> /dev/null; then
    log_success "✅ index.html exists in S3"
else
    log_error "❌ index.html not found in S3"
    exit 1
fi

# Check if CloudFront serves the new version (may be cached)
log_info "Checking CloudFront URL for 'Upload Audio' text..."
UPLOAD_TEXT_COUNT=$(curl -s "$COGNITO_CLOUDFRONT_URL/index.html" | grep -c "Upload Audio" || echo "0")

if [ "$UPLOAD_TEXT_COUNT" -ge "1" ]; then
    log_success "✅ 'Upload Audio' found in CloudFront response ($UPLOAD_TEXT_COUNT occurrences)"
else
    log_warn "⚠️  'Upload Audio' not found yet (CloudFront cache may not be updated)"
    log_warn "    Wait 3-5 minutes for cache invalidation to complete"
    log_warn "    Or force refresh in browser with Ctrl+Shift+R"
fi
echo ""

# ============================================================================
# Success Reporting
# ============================================================================

echo ""
log_info "==================================================================="
log_success "✅ UPLOAD AUDIO FRONTEND DEPLOYED SUCCESSFULLY"
log_info "==================================================================="
echo ""
log_info "🔗 Dashboard URL:"
log_info "  - $COGNITO_CLOUDFRONT_URL/index.html"
echo ""
log_info "📋 What was deployed:"
log_info "  - Dashboard: 'Upload Audio' card (4th card)"
log_info "  - Upload section with drag & drop zone"
log_info "  - File upload JavaScript (~310 lines)"
log_info "  - Upload area CSS styling"
echo ""
log_info "⚠️  Important Notes:"
log_info "  - CloudFront cache invalidation in progress (3-5 minutes)"
log_info "  - Force refresh browser with Ctrl+Shift+R if needed"
log_info "  - Check browser console (F12) for JavaScript errors"
echo ""
log_info "Next Steps:"
log_info "  1. Open dashboard: $COGNITO_CLOUDFRONT_URL/index.html"
log_info "  2. Login with your test credentials"
log_info "  3. Click 'Upload Audio' card (4th card)"
log_info "  4. Test file upload functionality"
log_info "  5. Run automated tests: ./scripts/630-test-upload-audio-feature.sh"
echo ""
log_info "Troubleshooting:"
log_info "  - If card not visible: Wait for cache, then Ctrl+Shift+R"
log_info "  - Check logs: tail -f logs/620-*.log"
log_info "  - Verify S3: aws s3 ls s3://$COGNITO_S3_BUCKET/"
echo ""
