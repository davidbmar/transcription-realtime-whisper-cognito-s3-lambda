#!/bin/bash
# Interactive Environment Configuration Script
# Generates .env file from .env.template

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$SCRIPT_DIR"

TEMPLATE_FILE=".env.template"
ENV_FILE=".env"
BACKUP_FILE=".env.backup-$(date +%Y%m%d-%H%M%S)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo "============================================================================"
echo -e "${CYAN}Transcription API - Environment Configuration${NC}"
echo "============================================================================"
echo ""

# Backup existing .env if it exists
if [ -f "$ENV_FILE" ]; then
    echo -e "${YELLOW}📋 Backing up existing .env to $BACKUP_FILE${NC}"
    cp "$ENV_FILE" "$BACKUP_FILE"
fi

# Copy template
if [ ! -f "$TEMPLATE_FILE" ]; then
    echo -e "${RED}❌ Error: $TEMPLATE_FILE not found${NC}"
    exit 1
fi

cp "$TEMPLATE_FILE" "$ENV_FILE"

# ============================================================================
# Helper Functions
# ============================================================================

ask_question() {
    local var_name=$1
    local prompt=$2
    local default=$3
    local value

    if [ -n "$default" ]; then
        read -p "$(echo -e ${BLUE}🔹 $prompt ${NC}[${GREEN}$default${NC}]: )" value
        value=${value:-$default}
    else
        read -p "$(echo -e ${BLUE}🔹 $prompt: ${NC})" value
        while [ -z "$value" ]; do
            echo -e "${RED}   This field is required.${NC}"
            read -p "$(echo -e ${BLUE}🔹 $prompt: ${NC})" value
        done
    fi

    echo "$value"
}

detect_aws_account() {
    aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "UNKNOWN"
}

detect_aws_region() {
    aws configure get region 2>/dev/null || echo "us-east-2"
}

generate_deployment_id() {
    echo "deploy-$(date +%Y%m%d-%H%M%S)"
}

update_env_var() {
    local var_name=$1
    local value=$2

    # Escape special characters for sed
    value=$(echo "$value" | sed 's/[&/\]/\\&/g')

    # Update .env file
    sed -i "s|{{$var_name}}|$value|g" "$ENV_FILE"
}

# ============================================================================
# Question Flow
# ============================================================================

echo ""
echo -e "${CYAN}📍 AWS Configuration${NC}"
echo "============================================================================"

# Detect AWS account
AWS_ACCOUNT_ID=$(detect_aws_account)
if [ "$AWS_ACCOUNT_ID" != "UNKNOWN" ]; then
    echo -e "${GREEN}✅ Detected AWS Account ID: $AWS_ACCOUNT_ID${NC}"
    update_env_var "AWS_ACCOUNT_ID" "$AWS_ACCOUNT_ID"
else
    AWS_ACCOUNT_ID=$(ask_question "AWS_ACCOUNT_ID" "Enter AWS Account ID")
    update_env_var "AWS_ACCOUNT_ID" "$AWS_ACCOUNT_ID"
fi

AWS_REGION=$(detect_aws_region)
AWS_REGION=$(ask_question "AWS_REGION" "AWS Region" "$AWS_REGION")
update_env_var "AWS_REGION" "$AWS_REGION"

echo ""
echo -e "${CYAN}🖥️  GPU Configuration${NC}"
echo "============================================================================"

GPU_INSTANCE_TYPE=$(ask_question "GPU_INSTANCE_TYPE" "GPU Instance Type" "g4dn.xlarge")
update_env_var "GPU_INSTANCE_TYPE" "$GPU_INSTANCE_TYPE"

GPU_SPOT=$(ask_question "GPU_SPOT_ENABLED" "Use Spot Instances? (true/false)" "true")
update_env_var "GPU_SPOT_ENABLED" "$GPU_SPOT"

SSH_KEY=$(ask_question "SSH_KEY_NAME" "SSH Key Name (must exist in AWS)")
update_env_var "SSH_KEY_NAME" "$SSH_KEY"

echo ""
echo -e "${CYAN}💾 Storage Configuration${NC}"
echo "============================================================================"

S3_MODEL_BUCKET=$(ask_question "S3_MODEL_BUCKET" "S3 Bucket for WhisperLive Models" "dbm-cf-2-web")
update_env_var "S3_MODEL_BUCKET" "$S3_MODEL_BUCKET"

APP_NAME=$(ask_question "APP_NAME" "Application Name" "transcription-api")
update_env_var "APP_NAME" "$APP_NAME"

S3_BUCKET_NAME=$(ask_question "S3_BUCKET_NAME" "S3 Bucket for User Data" "${APP_NAME}-storage")
update_env_var "S3_BUCKET_NAME" "$S3_BUCKET_NAME"

echo ""
echo -e "${CYAN}💳 Stripe Configuration (Optional - press Enter to skip)${NC}"
echo "============================================================================"

STRIPE_SK=$(ask_question "STRIPE_SECRET_KEY" "Stripe Secret Key (sk_...)" "SKIP" || echo "SKIP")
if [ "$STRIPE_SK" != "SKIP" ] && [ -n "$STRIPE_SK" ]; then
    update_env_var "STRIPE_SECRET_KEY" "$STRIPE_SK"

    STRIPE_PK=$(ask_question "STRIPE_PUBLISHABLE_KEY" "Stripe Publishable Key (pk_...)")
    update_env_var "STRIPE_PUBLISHABLE_KEY" "$STRIPE_PK"
else
    update_env_var "STRIPE_SECRET_KEY" "STRIPE_NOT_CONFIGURED"
    update_env_var "STRIPE_PUBLISHABLE_KEY" "STRIPE_NOT_CONFIGURED"
    update_env_var "STRIPE_WEBHOOK_SECRET" "STRIPE_NOT_CONFIGURED"
fi

echo ""
echo -e "${CYAN}🌐 Application Settings${NC}"
echo "============================================================================"

APP_DOMAIN=$(ask_question "APP_DOMAIN" "Application Domain (optional, press Enter to skip)" "NOT_CONFIGURED" || echo "NOT_CONFIGURED")
if [ "$APP_DOMAIN" = "NOT_CONFIGURED" ] || [ -z "$APP_DOMAIN" ]; then
    update_env_var "APP_DOMAIN" "NOT_CONFIGURED"
else
    update_env_var "APP_DOMAIN" "$APP_DOMAIN"
fi

APP_HOST=$(ask_question "APP_HOST" "Application Host" "0.0.0.0")
update_env_var "APP_HOST" "$APP_HOST"

APP_PORT=$(ask_question "APP_PORT" "Application Port" "8443")
update_env_var "APP_PORT" "$APP_PORT"

# ============================================================================
# Auto-Generated Values
# ============================================================================

echo ""
echo -e "${CYAN}🔧 Generating deployment metadata...${NC}"

DEPLOYMENT_ID=$(generate_deployment_id)
update_env_var "DEPLOYMENT_ID" "$DEPLOYMENT_ID"

DEPLOYMENT_TIMESTAMP=$(date -Iseconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S")
update_env_var "DEPLOYMENT_TIMESTAMP" "$DEPLOYMENT_TIMESTAMP"

update_env_var "CONFIG_VERSION" "4.0.0"

# Set placeholders for values that will be discovered by deployment scripts
update_env_var "GPU_INSTANCE_ID" "TO_BE_DISCOVERED"
update_env_var "GPU_INSTANCE_IP" "TO_BE_DISCOVERED"
update_env_var "SECURITY_GROUP_ID" "TO_BE_DISCOVERED"
update_env_var "BUILDBOX_SECURITY_GROUP" "TO_BE_DISCOVERED"
update_env_var "BUILDBOX_PUBLIC_IP" "TO_BE_DISCOVERED"
update_env_var "CLOUDFRONT_DISTRIBUTION_ID" "TO_BE_DISCOVERED"
update_env_var "CLOUDFRONT_URL" "TO_BE_DISCOVERED"
update_env_var "COGNITO_USER_POOL_ID" "TO_BE_DISCOVERED"
update_env_var "COGNITO_CLIENT_ID" "TO_BE_DISCOVERED"
update_env_var "COGNITO_IDENTITY_POOL_ID" "TO_BE_DISCOVERED"
update_env_var "COGNITO_DOMAIN" "TO_BE_DISCOVERED"
update_env_var "API_GATEWAY_URL" "TO_BE_DISCOVERED"
update_env_var "AUDIO_API_ENDPOINT" "TO_BE_DISCOVERED"

echo ""
echo "============================================================================"
echo -e "${GREEN}✅ Configuration Complete!${NC}"
echo "============================================================================"
echo ""
echo -e "${CYAN}📝 Configuration saved to: ${NC}$ENV_FILE"
if [ -f "$BACKUP_FILE" ]; then
    echo -e "${CYAN}📦 Previous config backed up to: ${NC}$BACKUP_FILE"
fi
echo ""
echo -e "${GREEN}🚀 Next Steps:${NC}"
echo -e "   ${YELLOW}1.${NC} Review .env file: ${CYAN}cat .env${NC}"
echo -e "   ${YELLOW}2.${NC} Run deployment: ${CYAN}./deploy/002${NC}"
echo -e "   ${YELLOW}3.${NC} Or run specific script: ${CYAN}./scripts/source/010-setup-build-box.sh${NC}"
echo ""
