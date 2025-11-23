#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Script 610: Deploy Upload Audio Feature - Backend
# ============================================================================
# Deploys the backend components for the uploaded audio file feature:
# - Lambda functions: uploadAudioFile, triggerTranscription
# - API endpoints: POST /api/audio/upload-file, POST /api/audio/transcribe/{sessionId}
#
# What this does:
# 1. Validates prerequisites (cognito-stack deployed, AWS credentials)
# 2. Deploys updated Lambda functions to AWS
# 3. Verifies API endpoints are accessible
# 4. Tests CORS configuration
#
# Requirements:
# - Script 420 completed successfully (cognito-stack deployed)
# - AWS CLI configured with proper credentials
# - Node.js and npm installed
#
# Total time: ~3-5 minutes
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
echo "610: Deploy Upload Audio Backend"
echo "============================================"
echo ""

log_info "This script will:"
log_info "  1. Validate prerequisites"
log_info "  2. Deploy Lambda functions to AWS"
log_info "  3. Verify API endpoints"
log_info "  4. Test CORS configuration"
echo ""

# ============================================================================
# Main Implementation
# ============================================================================

log_info "Step 1: Validating prerequisites"

# Validate required .env variables
if [ -z "${COGNITO_APP_NAME:-}" ] || [ -z "${COGNITO_STAGE:-}" ] || [ -z "${COGNITO_API_ENDPOINT:-}" ]; then
    log_error "❌ Missing required Cognito variables in .env"
    log_error "Please run ./scripts/420-deploy-cognito-stack.sh first"
    exit 1
fi

# Check cognito-stack directory exists
COGNITO_DIR="$REPO_ROOT/cognito-stack"
if [ ! -d "$COGNITO_DIR" ]; then
    log_error "❌ cognito-stack directory not found"
    exit 1
fi

# Check AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
    log_error "❌ AWS credentials not configured. Run 'aws configure' first"
    exit 1
fi

# Verify api/audio.js contains the new functions
if ! grep -q "uploadAudioFile" "$COGNITO_DIR/api/audio.js"; then
    log_error "❌ uploadAudioFile function not found in api/audio.js"
    log_error "Please ensure the upload audio feature is implemented"
    exit 1
fi

if ! grep -q "triggerTranscription" "$COGNITO_DIR/api/audio.js"; then
    log_error "❌ triggerTranscription function not found in api/audio.js"
    log_error "Please ensure the upload audio feature is implemented"
    exit 1
fi

log_success "Prerequisites validated"
echo ""

# Change to cognito-stack directory
cd "$COGNITO_DIR"

log_info "Step 2: Installing/updating Node.js dependencies"
if [ ! -d "node_modules" ]; then
    log_info "Installing serverless framework and dependencies..."
    npm install --legacy-peer-deps
    log_success "Dependencies installed"
else
    log_info "Dependencies already installed"
fi
echo ""

log_info "Step 3: Deploying Lambda functions to AWS"
log_warn "⚠️  This may take 3-5 minutes as CloudFormation updates resources"
echo ""
npx serverless deploy --stage "$COGNITO_STAGE"
echo ""
log_success "Lambda functions deployed successfully"
echo ""

log_info "Step 4: Verifying API endpoints"
export AWS_PAGER=""

# Get API endpoint from stack outputs
STACK_NAME="${COGNITO_APP_NAME}-${COGNITO_STAGE}"
API_ENDPOINT=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='ApiEndpoint'].OutputValue" \
    --output text)

log_info "API Endpoint: $API_ENDPOINT"
echo ""

log_info "Step 5: Testing CORS configuration"
# Test OPTIONS request (CORS preflight)
log_info "Testing POST /api/audio/upload-file endpoint..."
UPLOAD_CORS=$(curl -s -X OPTIONS \
    "${API_ENDPOINT}/api/audio/upload-file" \
    -H "Access-Control-Request-Method: POST" \
    -H "Origin: https://example.com" \
    -w "%{http_code}" -o /dev/null 2>/dev/null || echo "000")

if [ "$UPLOAD_CORS" = "200" ] || [ "$UPLOAD_CORS" = "204" ]; then
    log_success "✅ Upload endpoint CORS configured correctly (HTTP $UPLOAD_CORS)"
else
    log_warn "⚠️  Upload endpoint returned HTTP $UPLOAD_CORS (may be normal for some configurations)"
fi

log_info "Testing POST /api/audio/transcribe/{sessionId} endpoint..."
TRANSCRIBE_CORS=$(curl -s -X OPTIONS \
    "${API_ENDPOINT}/api/audio/transcribe/test-session-id" \
    -H "Access-Control-Request-Method: POST" \
    -H "Origin: https://example.com" \
    -w "%{http_code}" -o /dev/null 2>/dev/null || echo "000")

if [ "$TRANSCRIBE_CORS" = "200" ] || [ "$TRANSCRIBE_CORS" = "204" ]; then
    log_success "✅ Transcribe endpoint CORS configured correctly (HTTP $TRANSCRIBE_CORS)"
else
    log_warn "⚠️  Transcribe endpoint returned HTTP $TRANSCRIBE_CORS (may be normal for some configurations)"
fi
echo ""

log_info "Step 6: Verifying Lambda function deployment"
# Check if functions exist in AWS
UPLOAD_FUNCTION="${COGNITO_APP_NAME}-${COGNITO_STAGE}-uploadAudioFile"
TRANSCRIBE_FUNCTION="${COGNITO_APP_NAME}-${COGNITO_STAGE}-triggerTranscription"

if aws lambda get-function --function-name "$UPLOAD_FUNCTION" &> /dev/null; then
    log_success "✅ Lambda function deployed: $UPLOAD_FUNCTION"
else
    log_error "❌ Lambda function not found: $UPLOAD_FUNCTION"
    exit 1
fi

if aws lambda get-function --function-name "$TRANSCRIBE_FUNCTION" &> /dev/null; then
    log_success "✅ Lambda function deployed: $TRANSCRIBE_FUNCTION"
else
    log_error "❌ Lambda function not found: $TRANSCRIBE_FUNCTION"
    exit 1
fi
echo ""

# ============================================================================
# Success Reporting
# ============================================================================

echo ""
log_info "==================================================================="
log_success "✅ UPLOAD AUDIO BACKEND DEPLOYED SUCCESSFULLY"
log_info "==================================================================="
echo ""
log_info "📋 Deployed Functions:"
log_info "  - uploadAudioFile: $UPLOAD_FUNCTION"
log_info "  - triggerTranscription: $TRANSCRIBE_FUNCTION"
echo ""
log_info "🔗 API Endpoints:"
log_info "  - POST $API_ENDPOINT/api/audio/upload-file"
log_info "  - POST $API_ENDPOINT/api/audio/transcribe/{sessionId}"
echo ""
log_info "Next Steps:"
log_info "  1. Deploy frontend: ./scripts/620-deploy-upload-audio-frontend.sh"
log_info "  2. Test the feature: ./scripts/630-test-upload-audio-feature.sh"
echo ""
log_info "View logs:"
log_info "  serverless logs -f uploadAudioFile --tail"
log_info "  serverless logs -f triggerTranscription --tail"
echo ""
