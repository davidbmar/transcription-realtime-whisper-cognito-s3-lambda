#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Script 522: Setup IAM Permissions for Bedrock (Topic Segmentation)
# ============================================================================
# Prerequisite script that configures IAM permissions needed for topic
# segmentation using Amazon Bedrock embeddings.
#
# What this does:
# 1. Detects current IAM user or role
# 2. Checks if Bedrock permissions already exist
# 3. Creates/attaches a minimal Bedrock policy for embeddings
#
# Options:
#   --full-access     Use AWS managed AmazonBedrockFullAccess policy
#   --minimal         Create minimal policy for embeddings only (default)
#   --dry-run         Show what would be done without making changes
#
# Usage:
#   ./scripts/522-setup-bedrock-iam.sh              # Minimal permissions
#   ./scripts/522-setup-bedrock-iam.sh --full-access  # Full Bedrock access
#   ./scripts/522-setup-bedrock-iam.sh --dry-run    # Preview changes
#
# Prerequisites:
#   - IAM permissions to attach policies (iam:AttachUserPolicy or iam:AttachRolePolicy)
#   - AWS CLI configured with credentials
#
# ============================================================================

# Resolve script path
if [ -L "${BASH_SOURCE[0]}" ]; then
    SCRIPT_REAL=$(readlink -f "${BASH_SOURCE[0]}")
else
    SCRIPT_REAL="${BASH_SOURCE[0]}"
fi
PROJECT_ROOT="$(cd "$(dirname "$SCRIPT_REAL")/.." && pwd)"

# Load environment
source "$PROJECT_ROOT/.env" 2>/dev/null || true
source "$PROJECT_ROOT/scripts/lib/common-functions.sh"

echo "============================================"
echo "522: Setup IAM for Bedrock (Topic Segmentation)"
echo "============================================"
echo ""

# Parse arguments
POLICY_TYPE="minimal"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --full-access)
            POLICY_TYPE="full"
            shift
            ;;
        --minimal)
            POLICY_TYPE="minimal"
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            log_error "Unknown argument: $1"
            echo "Usage: $0 [--full-access|--minimal] [--dry-run]"
            exit 1
            ;;
    esac
done

REGION="${AWS_REGION:-us-east-2}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
POLICY_NAME="CloudDriveBedrockEmbeddings"

log_info "Configuration:"
log_info "  Region: $REGION"
log_info "  Account: $ACCOUNT_ID"
log_info "  Policy type: $POLICY_TYPE"
log_info "  Dry run: $DRY_RUN"
echo ""

# ============================================================================
# Step 1: Detect IAM Identity
# ============================================================================

log_info "Step 1: Detecting IAM identity..."

CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)

if [[ "$CALLER_ARN" == *":user/"* ]]; then
    # IAM User
    IAM_TYPE="user"
    IAM_NAME=$(echo "$CALLER_ARN" | sed 's/.*:user\///')
    log_success "  ✅ Detected IAM User: $IAM_NAME"
elif [[ "$CALLER_ARN" == *":assumed-role/"* ]]; then
    # Assumed Role (EC2 instance role, etc.)
    IAM_TYPE="role"
    # Extract role name from assumed-role ARN
    IAM_NAME=$(echo "$CALLER_ARN" | sed 's/.*:assumed-role\///' | cut -d'/' -f1)
    log_success "  ✅ Detected IAM Role: $IAM_NAME"
elif [[ "$CALLER_ARN" == *":role/"* ]]; then
    # Direct role
    IAM_TYPE="role"
    IAM_NAME=$(echo "$CALLER_ARN" | sed 's/.*:role\///')
    log_success "  ✅ Detected IAM Role: $IAM_NAME"
else
    log_error "  ❌ Could not determine IAM identity type"
    log_error "  ARN: $CALLER_ARN"
    exit 1
fi
echo ""

# ============================================================================
# Step 2: Check Existing Bedrock Permissions
# ============================================================================

log_info "Step 2: Checking existing Bedrock permissions..."

# Test if we already have Bedrock access
BEDROCK_TEST=$(python3 -c "
import boto3
import json
try:
    client = boto3.client('bedrock-runtime', region_name='$REGION')
    response = client.invoke_model(
        modelId='amazon.titan-embed-text-v2:0',
        body=json.dumps({'inputText': 'test', 'dimensions': 256, 'normalize': True}),
        contentType='application/json',
        accept='application/json'
    )
    print('SUCCESS')
except Exception as e:
    if 'AccessDenied' in str(e):
        print('ACCESS_DENIED')
    else:
        print(f'ERROR: {e}')
" 2>&1)

if [[ "$BEDROCK_TEST" == "SUCCESS" ]]; then
    log_success "  ✅ Bedrock access already configured!"
    log_info ""
    log_info "No changes needed. You can run topic segmentation:"
    log_info "  ./scripts/523-setup-s3-vectors.sh"
    log_info "  ./scripts/524-segment-transcripts-by-topic.sh --session <path>"
    exit 0
elif [[ "$BEDROCK_TEST" == "ACCESS_DENIED" ]]; then
    log_warn "  ⚠️  Bedrock access denied - need to add permissions"
else
    log_warn "  ⚠️  Bedrock test failed: $BEDROCK_TEST"
fi
echo ""

# ============================================================================
# Step 3: Prepare Policy
# ============================================================================

log_info "Step 3: Preparing IAM policy..."

if [ "$POLICY_TYPE" = "full" ]; then
    # Use AWS managed policy
    POLICY_ARN="arn:aws:iam::aws:policy/AmazonBedrockFullAccess"
    log_info "  Using AWS managed policy: AmazonBedrockFullAccess"
else
    # Create minimal custom policy for embeddings only
    POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

    POLICY_DOCUMENT=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "BedrockEmbeddings",
            "Effect": "Allow",
            "Action": [
                "bedrock:InvokeModel"
            ],
            "Resource": [
                "arn:aws:bedrock:*::foundation-model/amazon.titan-embed-text-v2:0",
                "arn:aws:bedrock:*::foundation-model/amazon.titan-embed-text-v1"
            ]
        }
    ]
}
EOF
)

    log_info "  Creating minimal policy: $POLICY_NAME"
    log_info "  Permissions: bedrock:InvokeModel on Titan Embed models only"
fi
echo ""

# ============================================================================
# Step 4: Apply Policy
# ============================================================================

log_info "Step 4: Applying IAM policy..."

if [ "$DRY_RUN" = true ]; then
    log_warn "  DRY RUN - Would perform the following:"
    echo ""
    if [ "$POLICY_TYPE" = "minimal" ]; then
        log_info "  1. Create policy '$POLICY_NAME' with document:"
        echo "$POLICY_DOCUMENT" | sed 's/^/     /'
        echo ""
    fi
    log_info "  2. Attach policy to $IAM_TYPE '$IAM_NAME'"
    log_info "     Policy ARN: $POLICY_ARN"
    echo ""
    log_info "Run without --dry-run to apply changes."
    exit 0
fi

# Create minimal policy if needed
if [ "$POLICY_TYPE" = "minimal" ]; then
    # Check if policy already exists
    if aws iam get-policy --policy-arn "$POLICY_ARN" &>/dev/null; then
        log_info "  Policy '$POLICY_NAME' already exists"
    else
        log_info "  Creating policy '$POLICY_NAME'..."
        aws iam create-policy \
            --policy-name "$POLICY_NAME" \
            --policy-document "$POLICY_DOCUMENT" \
            --description "Minimal Bedrock permissions for CloudDrive topic segmentation" \
            --output text --query 'Policy.Arn'
        log_success "  ✅ Policy created"
    fi
fi

# Attach policy to user or role
if [ "$IAM_TYPE" = "user" ]; then
    # Check if already attached
    ATTACHED=$(aws iam list-attached-user-policies --user-name "$IAM_NAME" \
        --query "AttachedPolicies[?PolicyArn=='$POLICY_ARN'].PolicyName" --output text 2>/dev/null)

    if [ -n "$ATTACHED" ]; then
        log_info "  Policy already attached to user '$IAM_NAME'"
    else
        log_info "  Attaching policy to user '$IAM_NAME'..."
        aws iam attach-user-policy \
            --user-name "$IAM_NAME" \
            --policy-arn "$POLICY_ARN"
        log_success "  ✅ Policy attached to user"
    fi
else
    # Role
    ATTACHED=$(aws iam list-attached-role-policies --role-name "$IAM_NAME" \
        --query "AttachedPolicies[?PolicyArn=='$POLICY_ARN'].PolicyName" --output text 2>/dev/null)

    if [ -n "$ATTACHED" ]; then
        log_info "  Policy already attached to role '$IAM_NAME'"
    else
        log_info "  Attaching policy to role '$IAM_NAME'..."
        aws iam attach-role-policy \
            --role-name "$IAM_NAME" \
            --policy-arn "$POLICY_ARN"
        log_success "  ✅ Policy attached to role"
    fi
fi
echo ""

# ============================================================================
# Step 5: Verify Access
# ============================================================================

log_info "Step 5: Verifying Bedrock access..."

# Wait a moment for IAM to propagate
sleep 2

VERIFY_TEST=$(python3 -c "
import boto3
import json
try:
    client = boto3.client('bedrock-runtime', region_name='$REGION')
    response = client.invoke_model(
        modelId='amazon.titan-embed-text-v2:0',
        body=json.dumps({'inputText': 'verification test', 'dimensions': 256, 'normalize': True}),
        contentType='application/json',
        accept='application/json'
    )
    result = json.loads(response['body'].read())
    if 'embedding' in result:
        print('SUCCESS')
    else:
        print('NO_EMBEDDING')
except Exception as e:
    print(f'ERROR: {e}')
" 2>&1)

if [[ "$VERIFY_TEST" == "SUCCESS" ]]; then
    log_success "  ✅ Bedrock access verified!"
else
    log_warn "  ⚠️  Verification failed: $VERIFY_TEST"
    log_info "  IAM policies may take a few minutes to propagate."
    log_info "  Try running ./scripts/523-setup-s3-vectors.sh in a minute."
fi
echo ""

# ============================================================================
# Summary
# ============================================================================

log_info "============================================"
log_success "✅ IAM SETUP COMPLETE"
log_info "============================================"
echo ""
log_info "Policy attached:"
log_info "  Type: $IAM_TYPE"
log_info "  Name: $IAM_NAME"
log_info "  Policy: $([ "$POLICY_TYPE" = "full" ] && echo "AmazonBedrockFullAccess" || echo "$POLICY_NAME")"
echo ""
log_info "Next steps:"
log_info "  1. Verify setup: ./scripts/523-setup-s3-vectors.sh"
log_info "  2. Run topic segmentation: ./scripts/524-segment-transcripts-by-topic.sh --session <path>"
echo ""
