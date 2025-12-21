#!/bin/bash
set -euo pipefail
mkdir -p "$(dirname "$0")/../logs"
exec > >(tee -a "$(dirname "$0")/../logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Script 405: Setup IAM Role for Deployment
# ============================================================================
# Creates an IAM role for EC2 instances to deploy the CloudDrive stack.
#
# For DEV: Uses AdministratorAccess (simplest)
# For PROD: Uses explicit minimal permissions (more secure)
#
# Usage:
#   ./scripts/405-setup-deploy-iam-role.sh          # Default: dev mode
#   ./scripts/405-setup-deploy-iam-role.sh --prod   # Explicit permissions
#
# After running, attach the role to your EC2 instance:
#   EC2 Console → Instance → Actions → Security → Modify IAM role
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ROLE_NAME="clouddrive-deploy-role"
INSTANCE_PROFILE_NAME="clouddrive-deploy-profile"
PROD_MODE=false

# Parse arguments
if [[ "${1:-}" == "--prod" ]]; then
    PROD_MODE=true
fi

echo "============================================"
echo -e "${CYAN}405: Setup IAM Role for Deployment${NC}"
echo "============================================"
echo ""

if $PROD_MODE; then
    echo -e "${YELLOW}Mode: PRODUCTION (explicit minimal permissions)${NC}"
else
    echo -e "${GREEN}Mode: DEVELOPMENT (AdministratorAccess)${NC}"
fi
echo ""

# Check AWS credentials
if ! aws sts get-caller-identity &>/dev/null; then
    echo -e "${RED}Error: AWS credentials not configured${NC}"
    echo "Run 'aws configure' first or use an IAM role"
    exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "AWS Account: $ACCOUNT_ID"
echo "Role Name: $ROLE_NAME"
echo ""

# Trust policy for EC2
TRUST_POLICY=$(cat <<'EOF'
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "ec2.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF
)

# Check if role exists
if aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
    echo -e "${YELLOW}Role '$ROLE_NAME' already exists${NC}"
    read -p "Update permissions? [Y/n]: " UPDATE
    UPDATE="${UPDATE:-Y}"
    if [[ ! "$UPDATE" =~ ^[Yy] ]]; then
        echo "Skipping role update"
        exit 0
    fi
else
    echo "Creating IAM role: $ROLE_NAME"
    aws iam create-role \
        --role-name "$ROLE_NAME" \
        --assume-role-policy-document "$TRUST_POLICY" \
        --description "Role for deploying CloudDrive stack from EC2"
    echo -e "${GREEN}✅ Role created${NC}"
fi

# Detach existing policies first
echo ""
echo "Detaching existing policies..."
EXISTING_POLICIES=$(aws iam list-attached-role-policies --role-name "$ROLE_NAME" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || echo "")
for policy in $EXISTING_POLICIES; do
    echo "  Detaching: $policy"
    aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$policy" 2>/dev/null || true
done

if $PROD_MODE; then
    # =========================================================================
    # PRODUCTION: Explicit minimal permissions
    # =========================================================================
    echo ""
    echo -e "${CYAN}Attaching production policies (minimal permissions)...${NC}"

    POLICIES=(
        "arn:aws:iam::aws:policy/AmazonS3FullAccess"
        "arn:aws:iam::aws:policy/AmazonCognitoPowerUser"
        "arn:aws:iam::aws:policy/AWSLambda_FullAccess"
        "arn:aws:iam::aws:policy/AmazonAPIGatewayAdministrator"
        "arn:aws:iam::aws:policy/CloudFrontFullAccess"
        "arn:aws:iam::aws:policy/AWSCloudFormationFullAccess"
        "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
        "arn:aws:iam::aws:policy/IAMFullAccess"
    )

    for policy in "${POLICIES[@]}"; do
        policy_name=$(basename "$policy")
        echo "  Attaching: $policy_name"
        aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$policy"
    done

    echo ""
    echo -e "${GREEN}✅ Production policies attached${NC}"
    echo ""
    echo "Policies attached:"
    echo "  - AmazonS3FullAccess (S3 buckets, objects)"
    echo "  - AmazonCognitoPowerUser (User pools, identity pools)"
    echo "  - AWSLambda_FullAccess (Lambda functions)"
    echo "  - AmazonAPIGatewayAdministrator (API Gateway)"
    echo "  - CloudFrontFullAccess (CloudFront distributions)"
    echo "  - AWSCloudFormationFullAccess (CloudFormation stacks)"
    echo "  - CloudWatchLogsFullAccess (Log groups)"
    echo "  - IAMFullAccess (Create Lambda execution roles)"
else
    # =========================================================================
    # DEVELOPMENT: AdministratorAccess (simplest)
    # =========================================================================
    echo ""
    echo -e "${CYAN}Attaching AdministratorAccess (dev mode)...${NC}"

    aws iam attach-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-arn "arn:aws:iam::aws:policy/AdministratorAccess"

    echo -e "${GREEN}✅ AdministratorAccess attached${NC}"
    echo ""
    echo -e "${YELLOW}⚠️  Note: For production, run with --prod flag for minimal permissions${NC}"
fi

# Create instance profile if needed
echo ""
if aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" &>/dev/null; then
    echo "Instance profile '$INSTANCE_PROFILE_NAME' already exists"
else
    echo "Creating instance profile: $INSTANCE_PROFILE_NAME"
    aws iam create-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME"

    # Add role to instance profile
    aws iam add-role-to-instance-profile \
        --instance-profile-name "$INSTANCE_PROFILE_NAME" \
        --role-name "$ROLE_NAME"

    echo -e "${GREEN}✅ Instance profile created${NC}"
fi

echo ""
echo "============================================"
echo -e "${GREEN}✅ IAM Role Setup Complete${NC}"
echo "============================================"
echo ""
echo -e "${CYAN}Next steps:${NC}"
echo ""
echo "1. Attach the role to your EC2 instance:"
echo "   - Go to EC2 Console → Instances"
echo "   - Select your instance"
echo "   - Actions → Security → Modify IAM role"
echo "   - Select: $ROLE_NAME"
echo "   - Click 'Update IAM role'"
echo ""
echo "2. Verify on the EC2 instance:"
echo "   aws sts get-caller-identity"
echo ""
echo "3. Continue with deployment:"
echo "   ./scripts/410-configure-cognito-variables.sh"
echo "   ./scripts/420-deploy-cognito-stack.sh"
echo ""
