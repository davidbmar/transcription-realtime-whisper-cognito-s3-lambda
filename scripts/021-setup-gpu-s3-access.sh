#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# 021: Setup GPU S3 Read-Only Access
# ============================================================================
# Creates IAM role with least-privilege S3 access for GPU instance.
# Enables secure S3 downloads of models without copying AWS credentials.
#
# What this does:
# 1. Creates IAM policy with S3 read-only access to model bucket
# 2. Creates IAM role for EC2 instances
# 3. Attaches policy to role
# 4. Creates instance profile
# 5. Associates instance profile with GPU instance
# ============================================================================

echo "============================================"
echo "021: Setup GPU S3 Access"
echo "============================================"
echo ""

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

# Check if .env exists
if [ ! -f "$ENV_FILE" ]; then
    echo "❌ Configuration file not found: $ENV_FILE"
    echo "Please run: ./scripts/005-setup-configuration.sh"
    exit 1
fi

# Load configuration
source "$ENV_FILE"

# Configuration
ROLE_NAME="${IAM_ROLE_NAME:-riva-gpu-role}"
INSTANCE_PROFILE_NAME="${IAM_INSTANCE_PROFILE_NAME:-riva-gpu-profile}"
POLICY_NAME="riva-gpu-policy"
S3_MODEL_BUCKET="${S3_MODEL_BUCKET:-dbm-cf-2-web}"
S3_COGNITO_BUCKET="${COGNITO_S3_BUCKET:-clouddrive-app-bucket}"

echo "Configuration:"
echo "  • Model Bucket: $S3_MODEL_BUCKET"
echo "  • Cognito Bucket: $S3_COGNITO_BUCKET (for transcripts/diarization)"
echo "  • AWS Region: $AWS_REGION"
echo "  • GPU Instance: ${GPU_INSTANCE_ID:-not set}"
echo "  • Role Name: $ROLE_NAME"
echo ""

# Check AWS credentials
echo "Verifying AWS credentials..."
if ! aws sts get-caller-identity &>/dev/null; then
    echo "❌ AWS credentials not configured"
    echo "Run: aws configure"
    exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "✅ AWS Account: $ACCOUNT_ID"
echo ""

# Check if GPU instance exists
if [ -n "${GPU_INSTANCE_ID:-}" ]; then
    echo "Verifying GPU instance..."
    if aws ec2 describe-instances --instance-ids "$GPU_INSTANCE_ID" --region "$AWS_REGION" &>/dev/null; then
        echo "✅ GPU instance found: $GPU_INSTANCE_ID"
    else
        echo "❌ GPU instance not found: $GPU_INSTANCE_ID"
        echo "Update GPU_INSTANCE_ID in .env or deploy GPU first"
        exit 1
    fi
else
    echo "⚠️  GPU_INSTANCE_ID not set - role will be created but not attached"
fi
echo ""

# ============================================================================
# Step 1: Create IAM Policy
# ============================================================================
echo "Step 1/5: Creating IAM policy..."

POLICY_DOCUMENT=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "ModelBucketReadOnly",
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:ListBucket"
            ],
            "Resource": [
                "arn:aws:s3:::${S3_MODEL_BUCKET}",
                "arn:aws:s3:::${S3_MODEL_BUCKET}/*"
            ]
        },
        {
            "Sid": "CognitoBucketReadWrite",
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:ListBucket"
            ],
            "Resource": [
                "arn:aws:s3:::${S3_COGNITO_BUCKET}",
                "arn:aws:s3:::${S3_COGNITO_BUCKET}/*"
            ]
        }
    ]
}
EOF
)

POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

if aws iam get-policy --policy-arn "$POLICY_ARN" &>/dev/null; then
    echo "✅ Policy already exists: $POLICY_NAME"
else
    echo "Creating policy: $POLICY_NAME"
    aws iam create-policy \
        --policy-name "$POLICY_NAME" \
        --policy-document "$POLICY_DOCUMENT" \
        --description "S3 access for Riva GPU: read $S3_MODEL_BUCKET, read/write $S3_COGNITO_BUCKET" \
        --output text
    echo "✅ Policy created: $POLICY_NAME"
fi
echo ""

# ============================================================================
# Step 2: Create IAM Role
# ============================================================================
echo "Step 2/5: Creating IAM role..."

TRUST_POLICY=$(cat <<EOF
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

if aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
    echo "✅ Role already exists: $ROLE_NAME"
else
    echo "Creating role: $ROLE_NAME"
    aws iam create-role \
        --role-name "$ROLE_NAME" \
        --assume-role-policy-document "$TRUST_POLICY" \
        --description "S3 read-only access for Riva GPU instances" \
        --output text
    echo "✅ Role created: $ROLE_NAME"
fi
echo ""

# ============================================================================
# Step 3: Attach Policy to Role
# ============================================================================
echo "Step 3/5: Attaching policy to role..."

if aws iam list-attached-role-policies --role-name "$ROLE_NAME" \
    --query "AttachedPolicies[?PolicyArn=='${POLICY_ARN}']" --output text | grep -q "$POLICY_ARN"; then
    echo "✅ Policy already attached to role"
else
    echo "Attaching policy to role..."
    aws iam attach-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-arn "$POLICY_ARN"
    echo "✅ Policy attached successfully"
fi
echo ""

# ============================================================================
# Step 4: Create Instance Profile
# ============================================================================
echo "Step 4/5: Creating instance profile..."

if aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" &>/dev/null; then
    echo "✅ Instance profile already exists: $INSTANCE_PROFILE_NAME"
else
    echo "Creating instance profile: $INSTANCE_PROFILE_NAME"
    aws iam create-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" --output text
    echo "✅ Instance profile created: $INSTANCE_PROFILE_NAME"
fi

echo "Adding role to instance profile..."
if aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" \
    --query "InstanceProfile.Roles[?RoleName=='${ROLE_NAME}']" --output text | grep -q "$ROLE_NAME"; then
    echo "✅ Role already in instance profile"
else
    aws iam add-role-to-instance-profile \
        --instance-profile-name "$INSTANCE_PROFILE_NAME" \
        --role-name "$ROLE_NAME"
    echo "✅ Role added to instance profile"
fi
echo ""

# ============================================================================
# Step 5: Associate Instance Profile with GPU
# ============================================================================
if [ -n "${GPU_INSTANCE_ID:-}" ]; then
    echo "Step 5/5: Associating instance profile with GPU..."

    # Check if instance already has a profile
    CURRENT_PROFILE=$(aws ec2 describe-instances \
        --instance-ids "$GPU_INSTANCE_ID" \
        --region "$AWS_REGION" \
        --query "Reservations[0].Instances[0].IamInstanceProfile.Arn" \
        --output text 2>/dev/null || echo "None")

    if [ "$CURRENT_PROFILE" != "None" ] && [ "$CURRENT_PROFILE" != "null" ]; then
        CURRENT_PROFILE_NAME=$(basename "$CURRENT_PROFILE")
        echo "Instance already has profile: $CURRENT_PROFILE_NAME"

        if [ "$CURRENT_PROFILE_NAME" == "$INSTANCE_PROFILE_NAME" ]; then
            echo "✅ Correct profile already attached"
        else
            echo "Replacing with new profile..."
            # Get association ID
            ASSOCIATION_ID=$(aws ec2 describe-iam-instance-profile-associations \
                --region "$AWS_REGION" \
                --filters "Name=instance-id,Values=$GPU_INSTANCE_ID" \
                --query "IamInstanceProfileAssociations[0].AssociationId" \
                --output text)

            aws ec2 disassociate-iam-instance-profile \
                --region "$AWS_REGION" \
                --association-id "$ASSOCIATION_ID"

            sleep 2

            aws ec2 associate-iam-instance-profile \
                --region "$AWS_REGION" \
                --instance-id "$GPU_INSTANCE_ID" \
                --iam-instance-profile "Name=$INSTANCE_PROFILE_NAME"

            echo "✅ Instance profile replaced"
        fi
    else
        echo "Attaching instance profile to GPU..."
        aws ec2 associate-iam-instance-profile \
            --region "$AWS_REGION" \
            --instance-id "$GPU_INSTANCE_ID" \
            --iam-instance-profile "Name=$INSTANCE_PROFILE_NAME"
        echo "✅ Instance profile attached"
    fi
else
    echo "Step 5/5: Skipped (no GPU instance ID)"
fi
echo ""

# ============================================================================
# Update .env file
# ============================================================================
echo "Updating .env configuration..."

# Add IAM configuration if not present
if ! grep -q "^IAM_ROLE_NAME=" "$ENV_FILE"; then
    cat >> "$ENV_FILE" << EOF

# ============================================================================
# IAM Configuration (for S3 access)
# ============================================================================
IAM_ROLE_NAME=$ROLE_NAME
IAM_INSTANCE_PROFILE_NAME=$INSTANCE_PROFILE_NAME
IAM_POLICY_ARN=$POLICY_ARN
S3_MODEL_BUCKET=$S3_BUCKET
S3_READONLY_ACCESS_CONFIGURED=true
EOF
    echo "✅ Configuration saved to .env"
else
    echo "✅ IAM configuration already in .env"
fi
echo ""

# ============================================================================
# Verification
# ============================================================================
echo "========================================="
echo "✅ S3 ACCESS SETUP COMPLETE"
echo "========================================="
echo ""
echo "IAM Resources Created:"
echo "  • Policy: $POLICY_NAME"
echo "  • Role: $ROLE_NAME"
echo "  • Instance Profile: $INSTANCE_PROFILE_NAME"
echo ""
if [ -n "${GPU_INSTANCE_ID:-}" ]; then
    echo "  • Attached to: $GPU_INSTANCE_ID"
    echo ""
    echo "Verification:"
    echo "  SSH to GPU: ssh -i ~/.ssh/$SSH_KEY_NAME.pem ubuntu@${GPU_INSTANCE_IP:-<gpu-ip>}"
    echo "  Test model bucket: aws s3 ls s3://$S3_MODEL_BUCKET/"
    echo "  Test cognito bucket: aws s3 ls s3://$S3_COGNITO_BUCKET/"
else
    echo "  • Not attached (no GPU_INSTANCE_ID)"
fi
echo ""
echo "Next steps:"
echo "  1. Deploy Conformer-CTC model: ./scripts/110-deploy-conformer-streaming.sh"
echo "  2. GPU instance can now download models from S3 without credentials"
echo ""
