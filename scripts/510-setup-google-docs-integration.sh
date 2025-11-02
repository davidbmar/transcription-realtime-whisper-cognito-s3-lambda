#!/bin/bash
#
# Script 510: Setup Google Docs Integration
#
# Purpose: Configure Google Docs API for live transcription
#
# What it does:
# 1. Prompts for Google Doc ID and credentials path
# 2. Base64-encodes credentials.json for Lambda environment
# 3. Updates .env with configuration
# 4. Deploys updated Lambda functions with Google Docs support
# 5. Provides instructions for sharing the doc with service account
#
# Prerequisites:
# - Google Cloud project with Docs API enabled
# - Service account credentials.json downloaded
# - Google Doc created and ready to share
# - Cognito stack already deployed (script 420)
#
# Usage: ./scripts/510-setup-google-docs-integration.sh
#

set -e  # Exit on error

# Get the absolute path of the repository root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# Source common functions
source "$REPO_ROOT/scripts/lib/common-functions.sh"

# Setup logging
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="$REPO_ROOT/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/510-setup-google-docs-${TIMESTAMP}.log"

# Log to both file and stdout
exec > >(tee -a "$LOG_FILE")
exec 2>&1

log_execution_start "510-setup-google-docs-integration.sh" \
    "Configure Google Docs API for live transcription"

# =============================================================================
# STEP 1: Load and validate environment
# =============================================================================

start_step "Load environment and validate prerequisites"

if [[ ! -f .env ]]; then
    log_error ".env file not found. Please run script 005 first."
    exit 1
fi

source .env

# Check if Cognito stack is deployed
if [[ -z "$COGNITO_API_ENDPOINT" ]]; then
    log_error "COGNITO_API_ENDPOINT not set. Please deploy Cognito stack first (script 420)."
    exit 1
fi

log_success "Environment loaded"
end_step

# =============================================================================
# STEP 2: Prompt for Google Doc ID
# =============================================================================

start_step "Configure Google Doc ID"

if [[ -z "$GOOGLE_DOC_ID" ]]; then
    echo ""
    echo "📄 Google Doc Configuration"
    echo "============================"
    echo ""
    echo "Please create a Google Doc and paste the document ID here."
    echo "The document ID is the long string in the URL:"
    echo ""
    echo "  https://docs.google.com/document/d/YOUR_DOC_ID_HERE/edit"
    echo ""
    read -p "Enter Google Doc ID: " GOOGLE_DOC_ID

    if [[ -z "$GOOGLE_DOC_ID" ]]; then
        log_error "Google Doc ID is required"
        exit 1
    fi

    # Save to .env
    update_env_var "GOOGLE_DOC_ID" "$GOOGLE_DOC_ID"
    log_success "Saved GOOGLE_DOC_ID to .env"
else
    log_info "Using existing GOOGLE_DOC_ID: $GOOGLE_DOC_ID"
fi

end_step

# =============================================================================
# STEP 3: Prompt for credentials file
# =============================================================================

start_step "Configure Google Cloud credentials"

# Default credentials path
DEFAULT_CREDS_PATH="$REPO_ROOT/google-docs-test/credentials.json"
CREDENTIALS_PATH="${GOOGLE_CREDENTIALS_PATH:-$DEFAULT_CREDS_PATH}"

echo ""
echo "🔑 Google Cloud Service Account Credentials"
echo "==========================================="
echo ""
echo "You need a service account credentials.json file."
echo ""
echo "To create one:"
echo "  1. Go to: https://console.cloud.google.com/apis/credentials"
echo "  2. Click 'Create Credentials' → 'Service Account'"
echo "  3. Grant 'Editor' role"
echo "  4. Click 'Keys' → 'Add Key' → 'JSON'"
echo "  5. Download the JSON file"
echo ""

if [[ -f "$CREDENTIALS_PATH" ]]; then
    log_info "Found existing credentials at: $CREDENTIALS_PATH"

    # Auto-use existing file if GOOGLE_CREDENTIALS_BASE64 is already set
    if [[ -n "$GOOGLE_CREDENTIALS_BASE64" ]]; then
        log_info "Using existing credentials (already configured)"
    else
        read -p "Use this file? (y/n): " use_existing

        if [[ "$use_existing" != "y" ]]; then
            read -p "Enter path to credentials.json: " custom_path
            if [[ ! -f "$custom_path" ]]; then
                log_error "File not found: $custom_path"
                exit 1
            fi
            CREDENTIALS_PATH="$custom_path"
        fi
    fi
else
    read -p "Enter path to credentials.json [$DEFAULT_CREDS_PATH]: " custom_path

    if [[ -n "$custom_path" ]]; then
        CREDENTIALS_PATH="$custom_path"
    fi

    if [[ ! -f "$CREDENTIALS_PATH" ]]; then
        log_error "File not found: $CREDENTIALS_PATH"
        log_error "Please download credentials.json from Google Cloud Console first"
        exit 1
    fi
fi

# Validate JSON format
if ! jq empty "$CREDENTIALS_PATH" 2>/dev/null; then
    log_error "Invalid JSON in credentials file: $CREDENTIALS_PATH"
    exit 1
fi

log_success "Credentials file validated: $CREDENTIALS_PATH"

# Extract service account email for sharing instructions
SERVICE_ACCOUNT_EMAIL=$(jq -r '.client_email' "$CREDENTIALS_PATH")
log_info "Service account email: $SERVICE_ACCOUNT_EMAIL"

# Save credentials path to .env
update_env_var "GOOGLE_CREDENTIALS_PATH" "$CREDENTIALS_PATH"

end_step

# =============================================================================
# STEP 4: Base64-encode credentials for Lambda
# =============================================================================

start_step "Base64-encode credentials for Lambda environment"

CREDENTIALS_BASE64=$(base64 -w 0 "$CREDENTIALS_PATH")

# Save to .env
update_env_var "GOOGLE_CREDENTIALS_BASE64" "$CREDENTIALS_BASE64"

log_success "Credentials encoded and saved to .env"
log_info "Encoded length: ${#CREDENTIALS_BASE64} characters"

end_step

# =============================================================================
# STEP 5: Update serverless.yml environment variables
# =============================================================================

start_step "Update serverless.yml with Google Docs configuration"

SERVERLESS_YML="$REPO_ROOT/cognito-stack/serverless.yml"

if [[ ! -f "$SERVERLESS_YML" ]]; then
    log_error "serverless.yml not found at: $SERVERLESS_YML"
    exit 1
fi

# Verify Google Docs functions are in serverless.yml
if ! grep -q "initializeGoogleDocsLiveSection:" "$SERVERLESS_YML"; then
    log_error "Google Docs functions not found in serverless.yml"
    log_error "Please ensure serverless.yml includes Google Docs Lambda functions"
    exit 1
fi

log_success "serverless.yml contains Google Docs functions"

end_step

# =============================================================================
# STEP 6: Install dependencies
# =============================================================================

start_step "Install googleapis dependency"

cd "$REPO_ROOT/cognito-stack"

if [[ ! -f "package.json" ]]; then
    log_error "package.json not found in cognito-stack/"
    exit 1
fi

# Check if googleapis is already in package.json
if ! grep -q "googleapis" package.json; then
    log_warn "googleapis not found in package.json, adding it..."
    npm install googleapis@^128.0.0 --save
else
    log_info "googleapis already in package.json"
fi

# Install/update dependencies
npm install

log_success "Dependencies installed"

end_step

# =============================================================================
# STEP 7: Deploy Lambda functions
# =============================================================================

start_step "Deploy updated Lambda functions with Google Docs support"

echo ""
log_info "Deploying serverless stack with Google Docs integration..."
echo ""

# Export required environment variables for serverless
export COGNITO_CLOUDFRONT_URL
export GOOGLE_CREDENTIALS_BASE64

cd "$REPO_ROOT/cognito-stack"

# Run serverless deploy (use npx to run local serverless)
npx serverless deploy

log_success "Lambda functions deployed successfully"

end_step

# =============================================================================
# STEP 8: Update UI configuration
# =============================================================================

start_step "Deploy UI with Google Doc ID"

cd "$REPO_ROOT"

log_info "Running script 425 to update UI with Google Doc ID..."

if [[ -x "./scripts/425-deploy-recorder-ui.sh" ]]; then
    ./scripts/425-deploy-recorder-ui.sh
    log_success "UI deployed with Google Docs configuration"
else
    log_warn "Script 425 not found or not executable, skipping UI update"
    log_warn "You may need to manually deploy the UI"
fi

end_step

# =============================================================================
# STEP 9: Provide sharing instructions
# =============================================================================

echo ""
echo "🎉 Google Docs Integration Setup Complete!"
echo "==========================================="
echo ""
echo "📋 Next Steps:"
echo ""
echo "1. Share your Google Doc with the service account:"
echo ""
echo "   Service Account Email: $SERVICE_ACCOUNT_EMAIL"
echo ""
echo "   a. Open your Google Doc: https://docs.google.com/document/d/$GOOGLE_DOC_ID/edit"
echo "   b. Click 'Share' button"
echo "   c. Paste the email: $SERVICE_ACCOUNT_EMAIL"
echo "   d. Grant 'Editor' permissions"
echo "   e. Click 'Send'"
echo ""
echo "2. Test the integration:"
echo ""
echo "   a. Open the audio recorder: $COGNITO_CLOUDFRONT_URL/audio.html"
echo "   b. Log in with your Cognito credentials"
echo "   c. Click 'Start Recording'"
echo "   d. Speak into your microphone"
echo "   e. Watch transcription appear in Google Doc in real-time!"
echo ""
echo "3. Verify configuration:"
echo ""
echo "   Google Doc ID: $GOOGLE_DOC_ID"
echo "   API Endpoint: $COGNITO_API_ENDPOINT"
echo "   CloudFront URL: $COGNITO_CLOUDFRONT_URL"
echo ""
echo "📄 Logs saved to: $LOG_FILE"
echo ""
log_success "Setup complete!"
