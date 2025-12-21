#!/bin/bash
set -euo pipefail

# ============================================================================
# Script 410: Configure Cognito Variables
# ============================================================================
# Sets required Cognito/S3 variables in .env for deployment.
# Pulls defaults from existing .env values (SERVICE_NAME, etc.)
# Does NOT overwrite existing serverless.yml, Lambda code, or UI files.
#
# Required for: ./scripts/420-deploy-cognito-stack.sh
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$REPO_ROOT/.env"

# Create logs directory if it doesn't exist
mkdir -p "$REPO_ROOT/logs"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo "============================================"
echo -e "${CYAN}410: Configure Cognito Variables${NC}"
echo "============================================"
echo ""

# Check .env exists
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}Error: .env not found. Run ./scripts/000-questions.sh first${NC}"
    exit 1
fi

# Load existing .env values
source "$ENV_FILE"

# Get current username for fallback defaults
USERNAME=$(whoami | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')
TIMESTAMP=$(date +%Y%m%d)

# Build smart defaults from existing .env
# Priority: existing COGNITO_* > APP_NAME > SERVICE_NAME > username-based
if [ -n "${COGNITO_APP_NAME:-}" ]; then
    DEFAULT_APP_NAME="$COGNITO_APP_NAME"
elif [ -n "${APP_NAME:-}" ]; then
    DEFAULT_APP_NAME="$APP_NAME"
elif [ -n "${SERVICE_NAME:-}" ]; then
    DEFAULT_APP_NAME="$SERVICE_NAME"
else
    DEFAULT_APP_NAME="clouddrive-${USERNAME}"
fi

if [ -n "${COGNITO_S3_BUCKET:-}" ]; then
    DEFAULT_BUCKET_NAME="$COGNITO_S3_BUCKET"
elif [ -n "${S3_BUCKET_NAME:-}" ]; then
    DEFAULT_BUCKET_NAME="$S3_BUCKET_NAME"
else
    DEFAULT_BUCKET_NAME="${DEFAULT_APP_NAME}-bucket-${TIMESTAMP}"
fi

# Only use existing COGNITO_DOMAIN if it's a real value, not a placeholder
if [ -n "${COGNITO_DOMAIN:-}" ] && [[ ! "$COGNITO_DOMAIN" =~ ^TO_BE ]]; then
    DEFAULT_DOMAIN="$COGNITO_DOMAIN"
else
    DEFAULT_DOMAIN="${DEFAULT_APP_NAME}-${TIMESTAMP}"
fi

DEFAULT_STAGE="${COGNITO_STAGE:-dev}"

# Check if all values already exist
if [ -n "${COGNITO_APP_NAME:-}" ] && [ -n "${COGNITO_S3_BUCKET:-}" ] && [ -n "${COGNITO_DOMAIN:-}" ] && [ -n "${COGNITO_STAGE:-}" ]; then
    echo -e "${GREEN}Found existing Cognito configuration in .env:${NC}"
    echo "  App Name:       $COGNITO_APP_NAME"
    echo "  S3 Bucket:      $COGNITO_S3_BUCKET"
    echo "  Cognito Domain: $COGNITO_DOMAIN"
    echo "  Stage:          $COGNITO_STAGE"
    echo ""
    read -p "Use these values? [Y/n]: " USE_EXISTING
    USE_EXISTING="${USE_EXISTING:-Y}"

    if [[ "$USE_EXISTING" =~ ^[Yy] ]]; then
        echo ""
        echo -e "${GREEN}Using existing configuration.${NC}"
        echo ""
        echo -e "${CYAN}Next step:${NC}"
        echo "  ./scripts/420-deploy-cognito-stack.sh"
        echo ""
        exit 0
    fi
    echo ""
fi

echo "Setting Cognito deployment configuration."
echo -e "${CYAN}Note: Bucket and domain names must be globally unique across all AWS accounts.${NC}"
echo ""

# App Name
read -p "Application name [${DEFAULT_APP_NAME}]: " APP_NAME
APP_NAME="${APP_NAME:-$DEFAULT_APP_NAME}"

# S3 Bucket
read -p "S3 bucket name [${DEFAULT_BUCKET_NAME}]: " BUCKET_NAME
BUCKET_NAME="${BUCKET_NAME:-$DEFAULT_BUCKET_NAME}"

# Cognito Domain
echo ""
echo -e "${CYAN}Cognito Domain Prefix:${NC}"
echo "  This creates your hosted login URL:"
echo "  https://<prefix>.auth.${AWS_REGION:-us-east-2}.amazoncognito.com"
echo ""
echo "  Requirements: lowercase, numbers, hyphens only (1-63 chars)"
echo "  Must be globally unique across all AWS accounts"
echo "  Example: myapp-prod-2025, transcription-davidmar"
echo ""
read -p "Cognito domain prefix [${DEFAULT_DOMAIN}]: " COGNITO_DOMAIN_INPUT
COGNITO_DOMAIN_INPUT="${COGNITO_DOMAIN_INPUT:-$DEFAULT_DOMAIN}"

# Stage
read -p "Deployment stage [${DEFAULT_STAGE}]: " STAGE
STAGE="${STAGE:-$DEFAULT_STAGE}"

echo ""
echo -e "${CYAN}Configuration Summary:${NC}"
echo "  App Name:       $APP_NAME"
echo "  S3 Bucket:      $BUCKET_NAME"
echo "  Cognito Domain: $COGNITO_DOMAIN_INPUT"
echo "  Stage:          $STAGE"
echo ""

read -p "Save to .env? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-Y}"

if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
    echo "Cancelled."
    exit 0
fi

# Remove existing Cognito variables if present
sed -i '/^SERVICE_NAME=/d' "$ENV_FILE" 2>/dev/null || true
sed -i '/^COGNITO_APP_NAME=/d' "$ENV_FILE" 2>/dev/null || true
sed -i '/^COGNITO_STAGE=/d' "$ENV_FILE" 2>/dev/null || true
sed -i '/^COGNITO_S3_BUCKET=/d' "$ENV_FILE" 2>/dev/null || true
sed -i '/^COGNITO_DOMAIN=/d' "$ENV_FILE" 2>/dev/null || true
sed -i '/^COGNITO_CLOUDFRONT_URL=https:\/\/placeholder/d' "$ENV_FILE" 2>/dev/null || true
sed -i '/^GOOGLE_CREDENTIALS_BASE64=$/d' "$ENV_FILE" 2>/dev/null || true
sed -i '/^# Cognito Configuration (set by 410/d' "$ENV_FILE" 2>/dev/null || true
sed -i '/^# Placeholders for first deployment/d' "$ENV_FILE" 2>/dev/null || true
sed -i '/^# SERVICE_NAME is used by/d' "$ENV_FILE" 2>/dev/null || true

# Add new values
cat >> "$ENV_FILE" << EOF

# Cognito Configuration (set by 410-configure-cognito-variables.sh)
# SERVICE_NAME is used by serverless.yml for the stack name
SERVICE_NAME=$APP_NAME
COGNITO_APP_NAME=$APP_NAME
COGNITO_STAGE=$STAGE
COGNITO_S3_BUCKET=$BUCKET_NAME
COGNITO_DOMAIN=$COGNITO_DOMAIN_INPUT

# Placeholders for first deployment (updated by 420 after deploy)
COGNITO_CLOUDFRONT_URL=https://placeholder.cloudfront.net
GOOGLE_CREDENTIALS_BASE64=
EOF

echo ""
echo -e "${GREEN}Variables saved to .env${NC}"
echo ""
echo -e "${CYAN}Next step:${NC}"
echo "  ./scripts/420-deploy-cognito-stack.sh"
echo ""
