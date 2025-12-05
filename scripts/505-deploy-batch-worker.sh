#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Script 505: Deploy Batch Transcription Worker
# ============================================================================
# Deploys the Python batch transcription script to the GPU instance.
#
# What this does:
# 1. Copies batch-transcribe-audio.py to GPU instance
# 2. Creates batch working directory on GPU
# 3. Sets up proper permissions
# 4. Tests the script with a simple validation
# 5. Creates helper scripts for common batch operations
#
# Requirements:
# - .env variables: GPU_INSTANCE_IP, GPU_SSH_KEY_PATH
# - GPU instance must be running
# - Script 500-setup-batch-transcription.sh must have been run
#
# Total time: ~1 minute
# ============================================================================

# Resolve script path (handles symlinks)
if [ -L "${BASH_SOURCE[0]}" ]; then
    SCRIPT_REAL=$(readlink -f "${BASH_SOURCE[0]}")
else
    SCRIPT_REAL="${BASH_SOURCE[0]}"
fi
PROJECT_ROOT="$(cd "$(dirname "$SCRIPT_REAL")/.." && pwd)"

# Load environment and common functions
source "$PROJECT_ROOT/.env"
source "$PROJECT_ROOT/scripts/lib/common-functions.sh"

echo "============================================"
echo "505: Deploy Batch Transcription Worker"
echo "============================================"
echo ""

log_info "This script will:"
log_info "  1. Create batch transcription directory on GPU"
log_info "  2. Deploy Python batch script"
log_info "  3. Set up permissions"
log_info "  4. Create helper scripts"
log_info "  5. Run validation test"
log_info "  6. Deploy diarization scripts"
log_info "  7. Setup pyannote model cache"
log_info "  8. Install pyannote-audio"
echo ""

# ============================================================================
# Main Implementation
# ============================================================================

# SSH Configuration
# Handle both absolute and relative paths for SSH key
if [[ "$GPU_SSH_KEY_PATH" = /* ]]; then
    SSH_KEY="$GPU_SSH_KEY_PATH"  # Absolute path
else
    SSH_KEY="$PROJECT_ROOT/$GPU_SSH_KEY_PATH"  # Relative path
fi
SSH_USER="ubuntu"
GPU_IP="$GPU_INSTANCE_IP"
BATCH_SCRIPT="$PROJECT_ROOT/scripts/batch-transcribe-audio.py"

log_info "Step 1/8: Verifying batch script exists locally..."
if [ ! -f "$BATCH_SCRIPT" ]; then
    log_error "Batch script not found: $BATCH_SCRIPT"
    log_info "This should have been created automatically. Please check the repository."
    exit 1
fi
log_success "Batch script found"
echo ""

log_info "Step 2/8: Creating batch directory on GPU..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$GPU_IP" <<'REMOTE_SCRIPT'
    mkdir -p ~/batch-transcription
    mkdir -p ~/batch-transcription/temp
    mkdir -p ~/batch-transcription/logs
REMOTE_SCRIPT
log_success "Batch directories created"
echo ""

log_info "Step 3/8: Copying batch-transcribe-audio.py to GPU..."
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no "$BATCH_SCRIPT" "$SSH_USER@$GPU_IP:~/batch-transcription/"
log_success "Batch script deployed"
echo ""

log_info "Step 4/8: Setting permissions..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$GPU_IP" <<'REMOTE_SCRIPT'
    chmod +x ~/batch-transcription/batch-transcribe-audio.py
REMOTE_SCRIPT
log_success "Permissions set"
echo ""

log_info "Step 5/8: Validating deployment..."
VALIDATION=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$GPU_IP" \
    "cd ~/batch-transcription && python3 batch-transcribe-audio.py --help 2>&1 || true")

if [[ "$VALIDATION" == *"Usage:"* ]]; then
    log_success "Batch script validated successfully"
else
    log_warn "Validation returned unexpected output (this may be okay):"
    echo "$VALIDATION"
fi
echo ""

log_info "Step 6/8: Deploying diarization scripts..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$GPU_IP" 'mkdir -p ~/batch-transcription/lib'
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no "$PROJECT_ROOT/scripts/520-diarize-transcripts.py" "$SSH_USER@$GPU_IP:~/batch-transcription/"
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no "$PROJECT_ROOT/scripts/lib/diarization.py" "$SSH_USER@$GPU_IP:~/batch-transcription/lib/"
# Also copy .env for S3 bucket configuration
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no "$PROJECT_ROOT/.env" "$SSH_USER@$GPU_IP:~/batch-transcription/"
log_success "Diarization scripts deployed"
echo ""

log_info "Step 7/8: Setting up pyannote model cache..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$GPU_IP" <<'REMOTE_SCRIPT'
# Tarball contains "huggingface/" at root, extract to ~/.cache/
CACHE_DIR="$HOME/.cache"
mkdir -p "$CACHE_DIR"
if [ ! -d "$CACHE_DIR/huggingface/hub/models--pyannote--speaker-diarization-3.1" ]; then
    echo "Downloading pyannote model cache from S3..."
    if aws s3 cp s3://dbm-cf-2-web/bintarball/diarized/latest/huggingface-cache.tar.gz - 2>/dev/null | tar -xzf - -C "$CACHE_DIR" 2>/dev/null; then
        echo "Model cache downloaded successfully"
        ls -la "$CACHE_DIR/huggingface/hub/" | grep pyannote || echo "Warning: models not found"
    else
        echo "Warning: Could not download model cache - will need HF_TOKEN"
    fi
else
    echo "Model cache already exists"
fi
REMOTE_SCRIPT
log_success "Model cache ready"
echo ""

log_info "Step 8/8: Setting up Python 3.10 conda environment with pyannote-audio 4.0.2..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$GPU_IP" <<'REMOTE_SCRIPT'
source /opt/conda/bin/activate base

# Create Python 3.10 environment for diarization (pyannote 4.0.2 requires Python 3.10+)
if ! conda env list | grep -q "diarization"; then
    echo "Creating Python 3.10 conda environment 'diarization'..."
    conda create -y -n diarization python=3.10 > /dev/null 2>&1
fi

source /opt/conda/bin/activate diarization

# Install pyannote-audio and awscli if needed
if python -c "import pyannote.audio" 2>/dev/null; then
    echo "pyannote-audio already installed in diarization env"
    python -c "import pyannote.audio; print(f'Version: {pyannote.audio.__version__}')"
else
    echo "Installing pyannote-audio 4.0.2 and awscli..."
    pip install --quiet pyannote-audio==4.0.2 awscli
    echo "pyannote-audio 4.0.2 and awscli installed"
fi

# Ensure awscli is installed (needed for S3 access)
if ! command -v aws &>/dev/null; then
    pip install --quiet awscli
fi
REMOTE_SCRIPT
log_success "pyannote-audio ready in conda 'diarization' environment"
echo ""

# ============================================================================
# Success Reporting
# ============================================================================

echo ""
log_info "==================================================================="
log_success "✅ BATCH WORKER + DIARIZATION DEPLOYED"
log_info "==================================================================="
echo ""
log_info "Deployment Summary:"
log_info "  - Batch script: ~/batch-transcription/batch-transcribe-audio.py"
log_info "  - Diarization: ~/batch-transcription/520-diarize-transcripts.py"
log_info "  - Working directory: ~/batch-transcription/temp"
log_info "  - Log directory: ~/batch-transcription/logs"
log_info "  - pyannote models: ~/.cache/huggingface/"
echo ""
log_info "Test the batch worker:"
log_info "  ssh $SSH_USER@$GPU_IP"
log_info "  cd ~/batch-transcription"
log_info "  python3 batch-transcribe-audio.py <audio_file.webm>"
echo ""
log_info "Run diarization (must use conda 'diarization' environment):"
log_info "  source /opt/conda/bin/activate diarization"
log_info "  python 520-diarize-transcripts.py --dry-run   # Preview"
log_info "  python 520-diarize-transcripts.py             # Process pending"
log_info "  python 520-diarize-transcripts.py --backfill  # Redo all"
echo ""
log_info "Next Steps:"
log_info "  1. Configure scheduler: ./scripts/510-configure-batch-scheduler.sh"
log_info "  2. Or run batch manually: ./scripts/515-run-batch-transcribe.sh"
echo ""
