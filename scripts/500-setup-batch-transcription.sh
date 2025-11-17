#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Script 500: Setup Batch Transcription System
# ============================================================================
# Installs dependencies for batch transcription on the GPU instance.
#
# What this does:
# 1. Verifies GPU instance connectivity
# 2. Checks if faster-whisper is already installed (from WhisperLive setup)
# 3. Installs any missing Python dependencies
# 4. Verifies batch transcription script can import required modules
# 5. Tests batch transcription with a sample audio file
#
# Requirements:
# - .env variables: GPU_INSTANCE_IP, GPU_SSH_KEY_PATH
# - GPU instance must be running
# - WhisperLive must be already installed (from 310-configure-whisperlive-gpu.sh)
#
# Total time: ~2-3 minutes
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
source "$PROJECT_ROOT/scripts/riva-common-library.sh"

echo "============================================"
echo "500: Setup Batch Transcription System"
echo "============================================"
echo ""

log_info "This script will:"
log_info "  1. Verify GPU instance connectivity"
log_info "  2. Check WhisperLive installation"
log_info "  3. Verify faster-whisper dependencies"
log_info "  4. Test Python import capabilities"
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

# Dynamically resolve GPU IP from instance ID
log_info "Resolving GPU IP from instance ID: ${GPU_INSTANCE_ID}"
GPU_IP=$(get_instance_ip "$GPU_INSTANCE_ID")
if [ -z "$GPU_IP" ] || [ "$GPU_IP" = "None" ]; then
    log_error "Failed to resolve GPU IP from instance ID: ${GPU_INSTANCE_ID}"
    log_info "Make sure:"
    log_info "  - GPU instance is running"
    log_info "  - GPU_INSTANCE_ID is correct in .env"
    log_info "  - AWS credentials are configured"
    exit 1
fi
log_success "Resolved GPU IP: $GPU_IP"
echo ""

log_info "Step 1/4: Verifying SSH access to GPU instance..."
if ! ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$GPU_IP" "echo 'SSH OK'" &>/dev/null; then
    log_error "Cannot SSH to GPU instance at $GPU_IP"
    log_info "Make sure:"
    log_info "  - GPU instance is running"
    log_info "  - Security group allows SSH from this IP"
    log_info "  - SSH key path is correct: $GPU_SSH_KEY_PATH"
    exit 1
fi
log_success "SSH connection verified"
echo ""

log_info "Step 2/4: Checking WhisperLive installation..."
WHISPERLIVE_INSTALLED=$(ssh -i "$SSH_KEY" "$SSH_USER@$GPU_IP" \
    "test -d ~/whisperlive/WhisperLive && echo 'yes' || echo 'no'")

if [ "$WHISPERLIVE_INSTALLED" != "yes" ]; then
    log_error "WhisperLive not found on GPU instance"
    log_info "Please run: ./scripts/310-configure-whisperlive-gpu.sh first"
    exit 1
fi
log_success "WhisperLive installation found"
echo ""

log_info "Step 3/4: Verifying faster-whisper installation..."
FASTER_WHISPER_OK=$(ssh -i "$SSH_KEY" "$SSH_USER@$GPU_IP" \
    "cd ~/whisperlive/WhisperLive && source venv/bin/activate && python3 -c 'import faster_whisper; print(\"ok\")' 2>/dev/null || echo 'error'")

if [ "$FASTER_WHISPER_OK" != "ok" ]; then
    log_warn "faster-whisper not available, installing..."

    ssh -i "$SSH_KEY" "$SSH_USER@$GPU_IP" <<'REMOTE_SCRIPT'
        cd ~/whisperlive/WhisperLive
        source venv/bin/activate
        pip install faster-whisper
REMOTE_SCRIPT

    log_success "faster-whisper installed"
else
    log_success "faster-whisper already installed"
fi
echo ""

log_info "Step 4/4: Testing Python imports..."
TEST_RESULT=$(ssh -i "$SSH_KEY" "$SSH_USER@$GPU_IP" \
    "cd ~/whisperlive/WhisperLive && source venv/bin/activate && python3 -c 'from faster_whisper import WhisperModel; print(\"success\")' 2>&1")

if [[ "$TEST_RESULT" == *"success"* ]]; then
    log_success "All Python dependencies verified"
else
    log_error "Python import test failed:"
    echo "$TEST_RESULT"
    exit 1
fi
echo ""

# ============================================================================
# Success Reporting
# ============================================================================

echo ""
log_info "==================================================================="
log_success "✅ BATCH TRANSCRIPTION SETUP COMPLETE"
log_info "==================================================================="
echo ""
log_info "Summary:"
log_info "  - GPU instance accessible via SSH"
log_info "  - WhisperLive installation verified"
log_info "  - faster-whisper module available"
log_info "  - Python dependencies ready"
echo ""
log_info "Next Steps:"
log_info "  1. Deploy batch worker script: ./scripts/505-deploy-batch-worker.sh"
log_info "  2. Or test manually: ssh to GPU and run batch-transcribe-audio.py"
echo ""
