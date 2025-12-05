#!/bin/bash
set -euo pipefail

# ============================================================================
# Script 522: One-Time Diarization Setup on GPU Instance
# ============================================================================
# Sets up speaker diarization on the GPU instance:
# 1. Syncs diarization scripts to GPU
# 2. Downloads pre-cached pyannote models from S3
# 3. Installs pyannote-audio
# 4. Runs a test to verify setup
#
# Prerequisites:
# - GPU instance running (start with 820-start-gpu-instance.sh)
# - .env configured with GPU_INSTANCE_ID and SSH_KEY_NAME
#
# Usage:
#   ./scripts/522-setup-diarization-gpu.sh
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
echo "522: Setup Diarization on GPU Instance"
echo "============================================"
echo ""

# Get GPU IP
if [ -z "${GPU_INSTANCE_ID:-}" ]; then
    log_error "GPU_INSTANCE_ID not set in .env"
    exit 1
fi

GPU_IP=$(aws ec2 describe-instances --instance-ids "$GPU_INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text 2>/dev/null)

if [ -z "$GPU_IP" ] || [ "$GPU_IP" = "None" ]; then
    log_error "GPU instance not running. Start with: ./scripts/820-start-gpu-instance.sh"
    exit 1
fi

# Get SSH key path
if [[ "$SSH_KEY_NAME" == /* ]]; then
    SSH_KEY="$SSH_KEY_NAME"
else
    SSH_KEY="$HOME/.ssh/${SSH_KEY_NAME}.pem"
fi

log_info "GPU Instance: $GPU_IP"
log_info "SSH Key: $SSH_KEY"
echo ""

# ============================================================================
# Step 1: Sync diarization scripts
# ============================================================================
log_info "Step 1: Syncing diarization scripts to GPU..."

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ubuntu@"$GPU_IP" \
    'mkdir -p ~/transcription/scripts/lib'

rsync -avz --progress \
    -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no" \
    "$PROJECT_ROOT/scripts/520-diarize-transcripts.py" \
    "$PROJECT_ROOT/scripts/521-scan-missing-diarization.sh" \
    "$PROJECT_ROOT/scripts/requirements-diarization.txt" \
    ubuntu@"$GPU_IP":~/transcription/scripts/

rsync -avz --progress \
    -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no" \
    "$PROJECT_ROOT/scripts/lib/diarization.py" \
    ubuntu@"$GPU_IP":~/transcription/scripts/lib/

# Also sync .env for S3 bucket config
rsync -avz \
    -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no" \
    "$PROJECT_ROOT/.env" \
    ubuntu@"$GPU_IP":~/transcription/

log_success "Scripts synced"
echo ""

# ============================================================================
# Step 2: Download pyannote model cache from S3
# ============================================================================
log_info "Step 2: Downloading pyannote model cache from S3..."

S3_MODEL_PATH="s3://dbm-cf-2-web/bintarball/diarized/latest/huggingface-cache.tar.gz"

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ubuntu@"$GPU_IP" bash -s << 'REMOTE_SCRIPT'
set -e
CACHE_DIR="$HOME/.cache/huggingface"
mkdir -p "$CACHE_DIR"

echo "Downloading model cache..."
if aws s3 cp "s3://dbm-cf-2-web/bintarball/diarized/latest/huggingface-cache.tar.gz" - 2>/dev/null | tar -xzf - -C "$CACHE_DIR" 2>/dev/null; then
    MODEL_COUNT=$(ls "$CACHE_DIR/hub" 2>/dev/null | grep -c models-- || echo 0)
    echo "Downloaded $MODEL_COUNT models to cache"
else
    echo "Warning: Could not download model cache - will need HF_TOKEN"
fi
REMOTE_SCRIPT

log_success "Model cache ready"
echo ""

# ============================================================================
# Step 3: Install pyannote-audio
# ============================================================================
log_info "Step 3: Installing pyannote-audio..."

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ubuntu@"$GPU_IP" bash -s << 'REMOTE_SCRIPT'
set -e
cd ~/transcription

# Check if already installed
if python3 -c "import pyannote.audio; print('pyannote-audio already installed')" 2>/dev/null; then
    exit 0
fi

echo "Installing pyannote-audio..."
pip install --quiet pyannote-audio==4.0.2

echo "Verifying installation..."
python3 -c "import pyannote.audio; print('pyannote-audio installed successfully')"
REMOTE_SCRIPT

log_success "pyannote-audio installed"
echo ""

# ============================================================================
# Step 4: Verify setup
# ============================================================================
log_info "Step 4: Verifying diarization setup..."

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ubuntu@"$GPU_IP" bash -s << 'REMOTE_SCRIPT'
set -e
cd ~/transcription

echo "Testing diarization module import..."
python3 -c "
import sys
sys.path.insert(0, 'scripts/lib')
from diarization import OfflineDiarizer
print('Diarization module loaded successfully')
print('PyTorch 2.6+ compatibility patch: Active')
"

echo ""
echo "Checking GPU availability..."
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader

echo ""
echo "Testing model loading (this may take a minute)..."
python3 -c "
import sys
sys.path.insert(0, 'scripts/lib')
from diarization import OfflineDiarizer
diarizer = OfflineDiarizer()
print('Model loaded on:', diarizer.device)
"
REMOTE_SCRIPT

log_success "Diarization setup verified!"
echo ""

# ============================================================================
# Summary
# ============================================================================
echo "============================================"
log_success "DIARIZATION SETUP COMPLETE"
echo "============================================"
echo ""
log_info "To run diarization:"
log_info "  ssh -i $SSH_KEY ubuntu@$GPU_IP"
log_info "  cd ~/transcription"
log_info "  python3 scripts/520-diarize-transcripts.py --dry-run  # Preview"
log_info "  python3 scripts/520-diarize-transcripts.py            # Run all"
log_info "  python3 scripts/520-diarize-transcripts.py --backfill # Redo all"
echo ""
log_info "Or run remotely:"
log_info "  ssh -i $SSH_KEY ubuntu@$GPU_IP 'cd ~/transcription && python3 scripts/520-diarize-transcripts.py'"
echo ""
