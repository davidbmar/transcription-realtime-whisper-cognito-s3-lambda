#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Script 523: Setup for Topic Segmentation
# ============================================================================
# Verifies prerequisites for topic segmentation feature.
#
# NOTE: S3 Vectors was originally planned for caching embeddings, but it's
# currently in preview (July 2025) and not available in standard AWS SDK.
# The topic segmentation script (524) works without S3 Vectors - it uses
# Amazon Bedrock directly for embeddings.
#
# What this script does:
# 1. Verifies AWS credentials are configured
# 2. Verifies Amazon Bedrock access (Titan Text Embeddings V2)
# 3. Checks required .env configuration
#
# Usage:
#   ./scripts/523-setup-s3-vectors.sh
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
source "$PROJECT_ROOT/.env"
source "$PROJECT_ROOT/scripts/lib/common-functions.sh"

echo "============================================"
echo "523: Setup for Topic Segmentation"
echo "============================================"
echo ""

# Configuration with defaults
REGION="${AWS_REGION:-us-east-2}"
EMBEDDING_MODEL="${EMBEDDING_MODEL_ID:-amazon.titan-embed-text-v2:0}"
THRESHOLD="${TOPIC_SIMILARITY_THRESHOLD:-0.75}"

log_info "Configuration:"
log_info "  Region: $REGION"
log_info "  Embedding Model: $EMBEDDING_MODEL"
log_info "  Similarity Threshold: $THRESHOLD"
echo ""

# ============================================================================
# Step 1: Verify AWS Credentials
# ============================================================================

log_info "Step 1: Verifying AWS credentials..."

if aws sts get-caller-identity &>/dev/null; then
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    log_success "  ✅ AWS credentials valid (Account: $ACCOUNT_ID)"
else
    log_error "  ❌ AWS credentials not configured"
    log_error "  Run: aws configure"
    exit 1
fi
echo ""

# ============================================================================
# Step 2: Verify Bedrock Access
# ============================================================================

log_info "Step 2: Verifying Amazon Bedrock access..."

# Test with a simple embedding request
TEST_RESULT=$(python3 -c "
import boto3
import json
import sys

try:
    client = boto3.client('bedrock-runtime', region_name='$REGION')
    response = client.invoke_model(
        modelId='$EMBEDDING_MODEL',
        body=json.dumps({
            'inputText': 'test',
            'dimensions': 256,
            'normalize': True
        }),
        contentType='application/json',
        accept='application/json'
    )
    result = json.loads(response['body'].read())
    if 'embedding' in result and len(result['embedding']) > 0:
        print('SUCCESS')
    else:
        print('NO_EMBEDDING')
except Exception as e:
    print(f'ERROR: {e}')
" 2>&1)

if [[ "$TEST_RESULT" == "SUCCESS" ]]; then
    log_success "  ✅ Amazon Bedrock access verified"
    log_success "  ✅ Model $EMBEDDING_MODEL is accessible"
else
    log_error "  ❌ Amazon Bedrock access failed"
    log_error "  Error: $TEST_RESULT"
    echo ""
    log_info "To enable Bedrock access, run the IAM setup script:"
    log_info "  ./scripts/522-setup-bedrock-iam.sh"
    log_info ""
    log_info "Or manually attach the AmazonBedrockFullAccess policy to your IAM user/role."
    exit 1
fi
echo ""

# ============================================================================
# Step 3: Check .env Configuration
# ============================================================================

log_info "Step 3: Checking .env configuration..."

MISSING_CONFIG=false

if [ -z "${TOPIC_SIMILARITY_THRESHOLD:-}" ]; then
    log_warn "  ⚠️  TOPIC_SIMILARITY_THRESHOLD not set (will use default: 0.75)"
    log_info "     Add to .env: TOPIC_SIMILARITY_THRESHOLD=0.75"
else
    log_success "  ✅ TOPIC_SIMILARITY_THRESHOLD=$TOPIC_SIMILARITY_THRESHOLD"
fi

if [ -z "${EMBEDDING_MODEL_ID:-}" ]; then
    log_warn "  ⚠️  EMBEDDING_MODEL_ID not set (will use default: amazon.titan-embed-text-v2:0)"
else
    log_success "  ✅ EMBEDDING_MODEL_ID=$EMBEDDING_MODEL_ID"
fi

if [ -z "${COGNITO_S3_BUCKET:-}" ]; then
    log_error "  ❌ COGNITO_S3_BUCKET not set in .env"
    MISSING_CONFIG=true
else
    log_success "  ✅ COGNITO_S3_BUCKET=$COGNITO_S3_BUCKET"
fi

if [ "$MISSING_CONFIG" = true ]; then
    exit 1
fi

echo ""

# ============================================================================
# Step 4: Note about S3 Vectors
# ============================================================================

log_info "Step 4: About S3 Vectors (embedding cache)..."
echo ""
log_warn "  ℹ️  S3 Vectors is in AWS Preview (July 2025) and not yet available"
log_warn "     in standard AWS CLI/SDK. Topic segmentation will work without it."
log_info ""
log_info "  Current behavior:"
log_info "    - Embeddings are generated via Amazon Bedrock on each run"
log_info "    - No caching (each segment is re-embedded)"
log_info "    - Cost: ~\$0.0002 per transcript (5,000 tokens)"
log_info ""
log_info "  When S3 Vectors becomes available:"
log_info "    - Update boto3/botocore to latest version"
log_info "    - Script 524 will automatically use caching"
log_info "    - Subsequent runs will be faster and cheaper"
echo ""

# ============================================================================
# Summary
# ============================================================================

log_info "============================================"
log_success "✅ TOPIC SEGMENTATION SETUP COMPLETE"
log_info "============================================"
echo ""
log_info "You can now run topic segmentation:"
log_info ""
log_info "  # Process single session"
log_info "  ./scripts/524-segment-transcripts-by-topic.sh --session <path>"
log_info ""
log_info "  # Process all sessions"
log_info "  ./scripts/524-segment-transcripts-by-topic.sh --all"
log_info ""
log_info "  # Dry run (show what would be detected)"
log_info "  ./scripts/524-segment-transcripts-by-topic.sh --session <path> --dry-run"
echo ""
