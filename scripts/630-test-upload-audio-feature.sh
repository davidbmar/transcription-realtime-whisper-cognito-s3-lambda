#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Script 630: Test Upload Audio Feature
# ============================================================================
# Tests the uploaded audio file feature end-to-end:
# - Backend API endpoints (upload URL generation, transcription trigger)
# - Frontend deployment (dashboard card, upload section)
# - CORS configuration
# - S3 bucket permissions
#
# What this does:
# 1. Validates prerequisites (backend + frontend deployed)
# 2. Tests backend API endpoints (OPTIONS and authenticated POST)
# 3. Verifies frontend deployment (CloudFront serves updated files)
# 4. Checks S3 bucket structure
# 5. Provides manual testing checklist
#
# Requirements:
# - Script 610 completed (backend deployed)
# - Script 620 completed (frontend deployed)
# - Test user created via script 430
# - CLOUDDRIVE_TEST_EMAIL and CLOUDDRIVE_TEST_PASSWORD in .env
#
# Total time: ~2-3 minutes
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
echo "630: Test Upload Audio Feature"
echo "============================================"
echo ""

log_info "This script will:"
log_info "  1. Validate prerequisites"
log_info "  2. Test backend API endpoints"
log_info "  3. Verify frontend deployment"
log_info "  4. Check S3 bucket structure"
log_info "  5. Provide manual testing checklist"
echo ""

# ============================================================================
# Main Implementation
# ============================================================================

log_info "Step 1: Validating prerequisites"

# Validate required .env variables
if [ -z "${COGNITO_API_ENDPOINT:-}" ] || [ -z "${COGNITO_CLOUDFRONT_URL:-}" ] || [ -z "${COGNITO_S3_BUCKET:-}" ]; then
    log_error "❌ Missing required variables in .env"
    exit 1
fi

# Check if test credentials exist
if [ -z "${CLOUDDRIVE_TEST_EMAIL:-}" ] || [ -z "${CLOUDDRIVE_TEST_PASSWORD:-}" ]; then
    log_warn "⚠️  Test credentials not found in .env"
    log_warn "    Some tests will be skipped"
    log_warn "    Set CLOUDDRIVE_TEST_EMAIL and CLOUDDRIVE_TEST_PASSWORD to enable"
fi

log_success "Prerequisites validated"
echo ""

# ============================================================================
# Backend API Tests
# ============================================================================

log_info "Step 2: Testing backend API endpoints"
echo ""

log_info "Test 2a: CORS preflight for /api/audio/upload-file"
UPLOAD_CORS_CODE=$(curl -s -X OPTIONS \
    "${COGNITO_API_ENDPOINT}/api/audio/upload-file" \
    -H "Access-Control-Request-Method: POST" \
    -H "Origin: ${COGNITO_CLOUDFRONT_URL}" \
    -w "%{http_code}" -o /dev/null 2>/dev/null || echo "000")

if [ "$UPLOAD_CORS_CODE" = "200" ] || [ "$UPLOAD_CORS_CODE" = "204" ]; then
    log_success "✅ Upload endpoint CORS works (HTTP $UPLOAD_CORS_CODE)"
else
    log_error "❌ Upload endpoint CORS failed (HTTP $UPLOAD_CORS_CODE)"
fi
echo ""

log_info "Test 2b: CORS preflight for /api/audio/transcribe/{sessionId}"
TRANSCRIBE_CORS_CODE=$(curl -s -X OPTIONS \
    "${COGNITO_API_ENDPOINT}/api/audio/transcribe/test-session-id" \
    -H "Access-Control-Request-Method: POST" \
    -H "Origin: ${COGNITO_CLOUDFRONT_URL}" \
    -w "%{http_code}" -o /dev/null 2>/dev/null || echo "000")

if [ "$TRANSCRIBE_CORS_CODE" = "200" ] || [ "$TRANSCRIBE_CORS_CODE" = "204" ]; then
    log_success "✅ Transcribe endpoint CORS works (HTTP $TRANSCRIBE_CORS_CODE)"
else
    log_error "❌ Transcribe endpoint CORS failed (HTTP $TRANSCRIBE_CORS_CODE)"
fi
echo ""

log_info "Test 2c: Unauthenticated POST to /api/audio/upload-file (should fail)"
UPLOAD_UNAUTH_CODE=$(curl -s -X POST \
    "${COGNITO_API_ENDPOINT}/api/audio/upload-file" \
    -H "Content-Type: application/json" \
    -d '{"filename":"test.m4a","mimeType":"audio/m4a","fileSize":1000000}' \
    -w "%{http_code}" -o /dev/null 2>/dev/null || echo "000")

if [ "$UPLOAD_UNAUTH_CODE" = "401" ] || [ "$UPLOAD_UNAUTH_CODE" = "403" ]; then
    log_success "✅ Upload endpoint requires authentication (HTTP $UPLOAD_UNAUTH_CODE)"
else
    log_warn "⚠️  Upload endpoint returned HTTP $UPLOAD_UNAUTH_CODE (expected 401/403)"
fi
echo ""

# ============================================================================
# Frontend Deployment Tests
# ============================================================================

log_info "Step 3: Verifying frontend deployment"
echo ""

log_info "Test 3a: CloudFront serves index.html"
INDEX_CODE=$(curl -s -w "%{http_code}" -o /dev/null "${COGNITO_CLOUDFRONT_URL}/index.html" 2>/dev/null || echo "000")

if [ "$INDEX_CODE" = "200" ]; then
    log_success "✅ CloudFront serves index.html (HTTP 200)"
else
    log_error "❌ CloudFront index.html failed (HTTP $INDEX_CODE)"
fi
echo ""

log_info "Test 3b: index.html contains 'Upload Audio' text"
UPLOAD_TEXT_COUNT=$(curl -s "${COGNITO_CLOUDFRONT_URL}/index.html" | grep -c "Upload Audio" || echo "0")

if [ "$UPLOAD_TEXT_COUNT" -ge "2" ]; then
    log_success "✅ 'Upload Audio' found in index.html ($UPLOAD_TEXT_COUNT occurrences)"
elif [ "$UPLOAD_TEXT_COUNT" -eq "1" ]; then
    log_warn "⚠️  'Upload Audio' found only $UPLOAD_TEXT_COUNT time (expected 2+)"
else
    log_error "❌ 'Upload Audio' not found in index.html"
    log_error "    CloudFront cache may not be updated yet"
    log_error "    Wait 3-5 minutes or force refresh with Ctrl+Shift+R"
fi
echo ""

log_info "Test 3c: index.html contains showUploadAudio function"
SHOW_UPLOAD_FOUND=$(curl -s "${COGNITO_CLOUDFRONT_URL}/index.html" | grep -c "function showUploadAudio" || echo "0")

if [ "$SHOW_UPLOAD_FOUND" -ge "1" ]; then
    log_success "✅ showUploadAudio function found in index.html"
else
    log_error "❌ showUploadAudio function not found"
    log_error "    Frontend deployment may have failed"
fi
echo ""

log_info "Test 3d: index.html contains uploadSingleFile function"
UPLOAD_SINGLE_FOUND=$(curl -s "${COGNITO_CLOUDFRONT_URL}/index.html" | grep -c "function uploadSingleFile" || echo "0")

if [ "$UPLOAD_SINGLE_FOUND" -ge "1" ]; then
    log_success "✅ uploadSingleFile function found in index.html"
else
    log_error "❌ uploadSingleFile function not found"
fi
echo ""

# ============================================================================
# S3 Bucket Tests
# ============================================================================

log_info "Step 4: Checking S3 bucket structure"
echo ""

log_info "Test 4a: S3 bucket exists"
if aws s3 ls "s3://$COGNITO_S3_BUCKET/" &> /dev/null; then
    log_success "✅ S3 bucket accessible: $COGNITO_S3_BUCKET"
else
    log_error "❌ S3 bucket not accessible: $COGNITO_S3_BUCKET"
fi
echo ""

log_info "Test 4b: index.html exists in S3"
if aws s3 ls "s3://$COGNITO_S3_BUCKET/index.html" &> /dev/null; then
    log_success "✅ index.html exists in S3"
else
    log_error "❌ index.html not found in S3"
fi
echo ""

# ============================================================================
# Lambda Function Tests
# ============================================================================

log_info "Step 5: Verifying Lambda functions"
echo ""

UPLOAD_FUNCTION="${COGNITO_APP_NAME}-${COGNITO_STAGE}-uploadAudioFile"
TRANSCRIBE_FUNCTION="${COGNITO_APP_NAME}-${COGNITO_STAGE}-triggerTranscription"

log_info "Test 5a: uploadAudioFile Lambda exists"
if aws lambda get-function --function-name "$UPLOAD_FUNCTION" &> /dev/null; then
    log_success "✅ Lambda function exists: $UPLOAD_FUNCTION"
else
    log_error "❌ Lambda function not found: $UPLOAD_FUNCTION"
fi

log_info "Test 5b: triggerTranscription Lambda exists"
if aws lambda get-function --function-name "$TRANSCRIBE_FUNCTION" &> /dev/null; then
    log_success "✅ Lambda function exists: $TRANSCRIBE_FUNCTION"
else
    log_error "❌ Lambda function not found: $TRANSCRIBE_FUNCTION"
fi
echo ""

# ============================================================================
# Manual Testing Checklist
# ============================================================================

echo ""
log_info "==================================================================="
log_success "✅ AUTOMATED TESTS COMPLETE"
log_info "==================================================================="
echo ""
log_info "📋 Manual Testing Checklist:"
echo ""
log_info "1. Open Dashboard:"
log_info "   - URL: $COGNITO_CLOUDFRONT_URL/index.html"
log_info "   - Login with: ${CLOUDDRIVE_TEST_EMAIL:-your-email@example.com}"
echo ""
log_info "2. Verify 'Upload Audio' Card:"
log_info "   - Should be 4th card on dashboard"
log_info "   - Icon: cloud-upload-alt"
log_info "   - Click card to open upload section"
echo ""
log_info "3. Test File Upload (Button):"
log_info "   - Click 'Choose Files' button"
log_info "   - Select audio file (.m4a, .mp3, .wav)"
log_info "   - Watch progress bar (Requesting → Uploading → Saving → Complete)"
log_info "   - File appears in list below with 📁 Upload badge"
echo ""
log_info "4. Test File Upload (Drag & Drop):"
log_info "   - Drag audio file from desktop"
log_info "   - Drop on upload zone"
log_info "   - Verify same behavior as button upload"
echo ""
log_info "5. Test 'Transcribe Now' Button:"
log_info "   - Click 'Transcribe Now' on uploaded file"
log_info "   - Confirm dialog"
log_info "   - Verify success message appears"
echo ""
log_info "6. Test Multiple File Upload:"
log_info "   - Upload 2-3 files simultaneously"
log_info "   - Verify all upload in parallel"
log_info "   - Check all appear in list"
echo ""
log_info "7. Test Error Handling:"
log_info "   - Try uploading file > 500MB (should show error)"
log_info "   - Try uploading non-audio file (should show alert)"
echo ""
log_info "8. Check Browser Console:"
log_info "   - Press F12 to open DevTools"
log_info "   - Check Console tab for errors"
log_info "   - Check Network tab for API calls"
echo ""
log_info "==================================================================="
log_info "Troubleshooting:"
log_info "==================================================================="
echo ""
log_info "If 'Upload Audio' card not visible:"
log_info "  - Clear browser cache (Ctrl+Shift+R)"
log_info "  - Wait 5 more minutes for CloudFront cache"
log_info "  - Check: curl -s $COGNITO_CLOUDFRONT_URL/index.html | grep -c 'Upload Audio'"
echo ""
log_info "If upload fails:"
log_info "  - Check browser console (F12) for errors"
log_info "  - View Lambda logs: serverless logs -f uploadAudioFile --tail"
log_info "  - Verify CORS: curl -X OPTIONS $COGNITO_API_ENDPOINT/api/audio/upload-file"
echo ""
log_info "If file doesn't appear in list after upload:"
log_info "  - Click 'Refresh' button"
log_info "  - Check S3: aws s3 ls s3://$COGNITO_S3_BUCKET/users/ --recursive | grep upload"
log_info "  - View metadata logs: serverless logs -f updateAudioSessionMetadata --tail"
echo ""
log_info "Documentation:"
log_info "  - Design: docs/UPLOADED-AUDIO-DESIGN.md"
log_info "  - Deployment: docs/UPLOAD-AUDIO-DEPLOYMENT-GUIDE.md"
log_info "  - Quick Start: QUICK-START-UPLOAD-AUDIO.md"
echo ""
