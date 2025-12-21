#!/bin/bash
set -euo pipefail

# ============================================================================
# Script 410: Configure Cognito Variables
# ============================================================================
# Sets required Cognito/S3 variables in .env for deployment.
# Does NOT overwrite existing serverless.yml, Lambda code, or UI files.
#
# Use this instead of 410-questions-setup-cognito-s3-lambda.sh when deploying
# from an existing repo (which already has all the code).
#
# Required for: ./scripts/420-deploy-cognito-stack.sh
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$REPO_ROOT/.env"

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
echo "This script sets the required variables for deploying"
echo "the Cognito/S3/Lambda stack. It does NOT regenerate any code."
echo ""

# Check .env exists
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}Error: .env not found. Run ./scripts/000-questions.sh first${NC}"
    exit 1
fi

# Get current username for defaults
USERNAME=$(whoami | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')
TIMESTAMP=$(date +%Y%m%d)

# Default values
DEFAULT_APP_NAME="clouddrive-${USERNAME}"
DEFAULT_BUCKET_NAME="clouddrive-${USERNAME}-${TIMESTAMP}"
DEFAULT_DOMAIN="clouddrive-${USERNAME}-${TIMESTAMP}"
DEFAULT_STAGE="dev"

echo -e "${CYAN}Note: Bucket and domain names must be globally unique across all AWS accounts.${NC}"
echo ""

# App Name
read -p "Application name [${DEFAULT_APP_NAME}]: " APP_NAME
APP_NAME="${APP_NAME:-$DEFAULT_APP_NAME}"

# S3 Bucket
read -p "S3 bucket name [${DEFAULT_BUCKET_NAME}]: " BUCKET_NAME
BUCKET_NAME="${BUCKET_NAME:-$DEFAULT_BUCKET_NAME}"

# Cognito Domain
read -p "Cognito domain prefix [${DEFAULT_DOMAIN}]: " COGNITO_DOMAIN
COGNITO_DOMAIN="${COGNITO_DOMAIN:-$DEFAULT_DOMAIN}"

# Stage
read -p "Deployment stage [${DEFAULT_STAGE}]: " STAGE
STAGE="${STAGE:-$DEFAULT_STAGE}"

echo ""
echo -e "${CYAN}Configuration Summary:${NC}"
echo "  App Name:       $APP_NAME"
echo "  S3 Bucket:      $BUCKET_NAME"
echo "  Cognito Domain: $COGNITO_DOMAIN"
echo "  Stage:          $STAGE"
echo ""

read -p "Save to .env? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-Y}"

if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
    echo "Cancelled."
    exit 0
fi

# Remove existing Cognito variables if present
sed -i '/^COGNITO_APP_NAME=/d' "$ENV_FILE" 2>/dev/null || true
sed -i '/^COGNITO_STAGE=/d' "$ENV_FILE" 2>/dev/null || true
sed -i '/^COGNITO_S3_BUCKET=/d' "$ENV_FILE" 2>/dev/null || true
sed -i '/^COGNITO_DOMAIN=/d' "$ENV_FILE" 2>/dev/null || true

# Add new values
cat >> "$ENV_FILE" << EOF

# Cognito Configuration (set by 410-configure-cognito-variables.sh)
COGNITO_APP_NAME=$APP_NAME
COGNITO_STAGE=$STAGE
COGNITO_S3_BUCKET=$BUCKET_NAME
COGNITO_DOMAIN=$COGNITO_DOMAIN
EOF

echo ""
echo -e "${GREEN}Variables saved to .env${NC}"
echo ""
echo -e "${CYAN}Next step:${NC}"
echo "  ./scripts/420-deploy-cognito-stack.sh"
echo ""
