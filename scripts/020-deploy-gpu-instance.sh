#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# 020: Deploy GPU Instance
# ============================================================================
# Creates EC2 GPU instance with security groups and IAM roles for Riva ASR.
# This is a wrapper around the full GPU instance deployment script.
#
# What this does:
# 1. Validates .env configuration
# 2. Creates IAM role for S3 access
# 3. Creates security group with proper ports
# 4. Launches GPU instance (g4dn.xlarge by default)
# 5. Waits for instance to be running
# 6. Updates .env with instance ID and IP
# ============================================================================

echo "============================================"
echo "020: Deploy GPU Instance"
echo "============================================"
echo ""

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Check if .env exists
if [ ! -f "$PROJECT_ROOT/.env" ]; then
    echo "❌ Configuration file not found: $PROJECT_ROOT/.env"
    echo ""
    echo "Please run: ./scripts/005-setup-configuration.sh"
    exit 1
fi

# Load configuration
source "$PROJECT_ROOT/.env"

# Validate required variables
REQUIRED_VARS=(
    "AWS_REGION"
    "AWS_ACCOUNT_ID"
    "GPU_INSTANCE_TYPE"
    "SSH_KEY_NAME"
)

MISSING_VARS=()
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ]; then
        MISSING_VARS+=("$var")
    fi
done

if [ ${#MISSING_VARS[@]} -gt 0 ]; then
    echo "❌ Missing required configuration variables:"
    for var in "${MISSING_VARS[@]}"; do
        echo "  • $var"
    done
    echo ""
    echo "Please update your .env file or re-run: ./scripts/005-setup-configuration.sh"
    exit 1
fi

echo "Configuration validated:"
echo "  • AWS Region: $AWS_REGION"
echo "  • AWS Account: $AWS_ACCOUNT_ID"
echo "  • Instance Type: $GPU_INSTANCE_TYPE"
echo "  • SSH Key: $SSH_KEY_NAME"
echo ""

# Check if GPU instance already exists
if [ -n "${GPU_INSTANCE_ID:-}" ] && [ "$GPU_INSTANCE_ID" != "" ]; then
    echo "⚠️  GPU instance already exists: $GPU_INSTANCE_ID"
    echo ""

    # Check instance state
    INSTANCE_STATE=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --instance-ids "$GPU_INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text 2>/dev/null || echo "not-found")

    if [ "$INSTANCE_STATE" != "not-found" ]; then
        echo "Instance state: $INSTANCE_STATE"
        echo ""
        echo "Options:"
        echo "  1. Use existing instance: ./scripts/730-start-gpu-instance.sh"
        echo "  2. Terminate and redeploy: ./scripts/740-stop-gpu-instance.sh --terminate"
        echo "  3. Manage instances: ./scripts/710-gpu-instance-manager.sh"
        exit 0
    else
        echo "Instance ID in .env but instance not found in AWS (may have been terminated)"
        echo "Proceeding with new deployment..."
        echo ""
    fi
fi

# Call the full deployment script
echo "Deploying GPU instance..."
echo ""

"$SCRIPT_DIR/720-deploy-gpu-instance.sh" "$@"

echo ""
echo "========================================="
echo "✅ GPU INSTANCE DEPLOYMENT COMPLETE"
echo "========================================="
echo ""
echo "Next steps:"
echo "  1. Configure security groups: ./scripts/030-configure-security-groups.sh"
echo "  2. Deploy Conformer model: ./scripts/110-deploy-conformer-streaming.sh"
echo "  3. Or use the GPU manager: ./scripts/710-gpu-instance-manager.sh"
echo ""
