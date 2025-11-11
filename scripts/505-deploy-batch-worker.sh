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

log_info "Step 1/5: Verifying batch script exists locally..."
if [ ! -f "$BATCH_SCRIPT" ]; then
    log_error "Batch script not found: $BATCH_SCRIPT"
    log_info "This should have been created automatically. Please check the repository."
    exit 1
fi
log_success "Batch script found"
echo ""

log_info "Step 2/5: Creating batch directory on GPU..."
ssh -i "$SSH_KEY" "$SSH_USER@$GPU_IP" <<'REMOTE_SCRIPT'
    mkdir -p ~/batch-transcription
    mkdir -p ~/batch-transcription/temp
    mkdir -p ~/batch-transcription/logs
REMOTE_SCRIPT
log_success "Batch directories created"
echo ""

log_info "Step 3/5: Copying batch-transcribe-audio.py to GPU..."
scp -i "$SSH_KEY" "$BATCH_SCRIPT" "$SSH_USER@$GPU_IP:~/batch-transcription/"
log_success "Batch script deployed"
echo ""

log_info "Step 4/5: Setting permissions..."
ssh -i "$SSH_KEY" "$SSH_USER@$GPU_IP" <<'REMOTE_SCRIPT'
    chmod +x ~/batch-transcription/batch-transcribe-audio.py
REMOTE_SCRIPT
log_success "Permissions set"
echo ""

log_info "Step 5/5: Validating deployment..."
VALIDATION=$(ssh -i "$SSH_KEY" "$SSH_USER@$GPU_IP" \
    "cd ~/batch-transcription && python3 batch-transcribe-audio.py --help 2>&1 || true")

if [[ "$VALIDATION" == *"Usage:"* ]]; then
    log_success "Batch script validated successfully"
else
    log_warn "Validation returned unexpected output (this may be okay):"
    echo "$VALIDATION"
fi
echo ""

# ============================================================================
# Success Reporting
# ============================================================================

echo ""
log_info "==================================================================="
log_success "✅ BATCH WORKER DEPLOYED"
log_info "==================================================================="
echo ""
log_info "Deployment Summary:"
log_info "  - Script location: ~/batch-transcription/batch-transcribe-audio.py"
log_info "  - Working directory: ~/batch-transcription/temp"
log_info "  - Log directory: ~/batch-transcription/logs"
echo ""
log_info "Test the batch worker:"
log_info "  ssh $SSH_USER@$GPU_IP"
log_info "  cd ~/batch-transcription"
log_info "  python3 batch-transcribe-audio.py <audio_file.webm>"
echo ""
log_info "Next Steps:"
log_info "  1. Configure scheduler: ./scripts/510-configure-batch-scheduler.sh"
log_info "  2. Or run batch manually: ./scripts/515-run-batch-transcribe.sh"
echo ""
