#!/usr/bin/env bash
#
# 426-deploy-viewer.sh
#
# Deploy Live Transcript Viewer to S3/CloudFront
#
# This script:
# 1. Copies viewer.html and viewer-styles.css from ui-source/
# 2. Updates configuration with Cognito values
# 3. Uploads files to S3
# 4. Invalidates CloudFront cache
#
# Usage: ./scripts/426-deploy-viewer.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load common functions
source "$SCRIPT_DIR/lib/common-functions.sh"

# Initialize logging
SCRIPT_NAME="$(basename "$0" .sh)"
LOG_FILE="${REPO_ROOT}/logs/${SCRIPT_NAME}-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "${REPO_ROOT}/logs"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "============================================"
echo "426: Deploy Live Transcript Viewer"
echo "============================================"
echo ""

# Load environment
load_environment

# Check required variables
if [ -z "$AWS_REGION" ] || [ -z "$COGNITO_S3_BUCKET" ] || \
   [ -z "$COGNITO_USER_POOL_ID" ] || [ -z "$COGNITO_USER_POOL_CLIENT_ID" ] || \
   [ -z "$COGNITO_IDENTITY_POOL_ID" ] || [ -z "$COGNITO_CLOUDFRONT_URL" ] || \
   [ -z "$COGNITO_API_ENDPOINT" ]; then
    log_error "Required environment variables not set. Please run ./scripts/005-setup-configuration.sh"
    exit 1
fi

# Get CloudFront distribution ID
log_info "Looking up CloudFront distribution ID for bucket: $COGNITO_S3_BUCKET"
DISTRIBUTION_ID=$(aws cloudfront list-distributions \
    --region us-east-1 \
    --query "DistributionList.Items[?Origins.Items[0].DomainName=='${COGNITO_S3_BUCKET}.s3.${AWS_REGION}.amazonaws.com'].Id | [0]" \
    --output text)

if [ -z "$DISTRIBUTION_ID" ] || [ "$DISTRIBUTION_ID" == "None" ]; then
    log_error "Could not find CloudFront distribution for bucket: $COGNITO_S3_BUCKET"
    log_info "Expected origin: ${COGNITO_S3_BUCKET}.s3.${AWS_REGION}.amazonaws.com"
    exit 1
fi

log_success "Found CloudFront distribution: $DISTRIBUTION_ID"

# Step 1: Validate prerequisites
log_info "Step 1: Validating prerequisites"

SOURCE_UI_DIR="$REPO_ROOT/ui-source"
DEPLOY_DIR="$REPO_ROOT/cognito-stack/web"

if [ ! -f "$SOURCE_UI_DIR/viewer.html" ]; then
    log_error "viewer.html not found in $SOURCE_UI_DIR"
    exit 1
fi

if [ ! -f "$SOURCE_UI_DIR/viewer-styles.css" ]; then
    log_error "viewer-styles.css not found in $SOURCE_UI_DIR"
    exit 1
fi

log_success "Prerequisites validated"
echo ""

# Step 2: Prepare deployment directory
log_info "Step 2: Preparing deployment directory"

mkdir -p "$DEPLOY_DIR"
cd "$DEPLOY_DIR"

log_success "Directory prepared: $DEPLOY_DIR"
echo ""

# Step 3: Copy viewer files
log_info "Step 3: Copying viewer files from ui-source"

cp "$SOURCE_UI_DIR/viewer.html" ./viewer.html
cp "$SOURCE_UI_DIR/viewer-styles.css" ./viewer-styles.css

# Copy styles.css if not already present
if [ ! -f "./styles.css" ] && [ -f "$SOURCE_UI_DIR/styles.css" ]; then
    cp "$SOURCE_UI_DIR/styles.css" ./styles.css
fi

log_success "Viewer files copied"
echo ""

# Step 4: Update viewer.html configuration
log_info "Step 4: Updating viewer.html configuration"

# Replace configuration placeholders
sed -i "s|YOUR_USER_POOL_ID|$COGNITO_USER_POOL_ID|g" viewer.html
sed -i "s|YOUR_USER_POOL_CLIENT_ID|$COGNITO_USER_POOL_CLIENT_ID|g" viewer.html
sed -i "s|YOUR_IDENTITY_POOL_ID|$COGNITO_IDENTITY_POOL_ID|g" viewer.html
sed -i "s|YOUR_REGION|$AWS_REGION|g" viewer.html
sed -i "s|YOUR_CLOUDFRONT_API_ENDPOINT|$COGNITO_API_ENDPOINT|g" viewer.html
sed -i "s|YOUR_CLOUDFRONT_URL|$COGNITO_CLOUDFRONT_URL|g" viewer.html

log_success "Configuration updated in viewer.html"
echo ""

# Step 5: Upload files to S3
log_info "Step 5: Uploading viewer files to S3"

aws s3 cp viewer.html "s3://$COGNITO_S3_BUCKET/viewer.html" \
    --content-type "text/html" \
    --region "$AWS_REGION"

aws s3 cp viewer-styles.css "s3://$COGNITO_S3_BUCKET/viewer-styles.css" \
    --content-type "text/css" \
    --region "$AWS_REGION"

log_success "Files uploaded to S3"
echo ""

# Step 6: Invalidate CloudFront cache
log_info "Step 6: Invalidating CloudFront cache"

aws cloudfront create-invalidation \
    --distribution-id "$DISTRIBUTION_ID" \
    --paths "/viewer.html" "/viewer-styles.css" \
    --region us-east-1 > /dev/null

log_success "CloudFront cache invalidated"
echo ""

# Summary
echo "==================================================================="
log_success "✅ VIEWER DEPLOYED SUCCESSFULLY"
echo "==================================================================="
echo ""
echo "📋 Deployment Details:"
echo "  - Viewer URL: ${COGNITO_CLOUDFRONT_URL}/viewer.html"
echo "  - S3 Bucket: ${COGNITO_S3_BUCKET}"
echo "  - CloudFront Distribution: ${DISTRIBUTION_ID}"
echo ""
echo "🔗 Share Link Format:"
echo "  - Short: ${COGNITO_CLOUDFRONT_URL}/viewer.html?s=SESSION_HASH&u=USER_ID"
echo "  - Full: ${COGNITO_CLOUDFRONT_URL}/viewer.html?sessionId=FULL_SESSION_ID&userId=FULL_USER_ID"
echo ""
echo "⚠️  Note:"
echo "  - CloudFront cache may take 1-2 minutes to propagate"
echo "  - Share links are generated automatically when recording"
echo ""
echo "🎯 Next Steps:"
echo "  1. Start recording in audio.html"
echo "  2. Click 'Share Live Transcript' button"
echo "  3. Copy the generated link"
echo "  4. Share with viewers (no login required for viewers)"
echo ""

