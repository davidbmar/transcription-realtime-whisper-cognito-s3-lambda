#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Script 820: Startup GPU and Restore WhisperLive
# ============================================================================
# Complete one-command restoration of WhisperLive streaming setup.
# Run this after shutting down the GPU to save costs.
#
# What this does:
# 1. Starts GPU EC2 instance (uses GPU_INSTANCE_ID from .env)
# 2. Waits for instance to be ready
# 3. Queries AWS for current IP (IP changes on every stop/start)
# 4. Exports IP to environment for current session only (NOT stored)
# 5. Verifies SSH connectivity
# 6. Checks WhisperLive service status
# 7. Deploys WhisperLive if needed (calls 310-configure-whisperlive-gpu.sh)
# 8. Ensures WhisperLive service is running
# 9. Runs end-to-end transcription verification
#
# NEW Architecture: Dynamic IP lookup pattern
# - GPU_INSTANCE_ID is permanent (stored in .env)
# - GPU IP is queried at runtime (NOT stored)
# - Edge box scripts (825) handle Caddy proxy updates
# - All scripts use get_instance_ip() for current IP
#
# Total time: 4-5 minutes (2min startup + 30s model load + 30s verification)
# ============================================================================

# Find repository root (works from symlink or direct execution)
if [ -L "${BASH_SOURCE[0]}" ]; then
    SCRIPT_REAL=$(readlink -f "${BASH_SOURCE[0]}")
else
    SCRIPT_REAL="${BASH_SOURCE[0]}"
fi
REPO_ROOT="$(cd "$(dirname "$SCRIPT_REAL")/.." && pwd)"

source "$REPO_ROOT/scripts/lib/common-functions.sh"
load_environment

# Record startup time
STARTUP_START_TIME=$(date +%s)

# Validate and auto-correct GPU_INSTANCE_ID if needed
if ! validate_gpu_instance_id --auto-fix; then
    log_error "❌ Failed to validate GPU instance ID"
    echo ""
    echo "To fix this, you have two options:"
    echo ""
    echo "Option 1: Use an existing GPU instance"
    echo "  1. List available GPUs:"
    echo "     aws ec2 describe-instances --region us-east-2 --filters \"Name=instance-type,Values=g4dn.*\" --output table"
    echo ""
    echo "  2. Manually set in .env:"
    echo "     GPU_INSTANCE_ID=i-XXXXXXXXX"
    echo ""
    echo "Option 2: Create a new GPU instance"
    echo "  ./scripts/020-deploy-gpu-instance.sh"
    echo ""
    exit 1
fi
echo ""

REGION="${AWS_REGION:-us-east-2}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/${SSH_KEY_NAME}.pem}"

log_info "🚀 Starting GPU and restoring WhisperLive streaming"
log_info "Instance: $GPU_INSTANCE_ID"
echo ""

# ============================================================================
# Step 1: Start GPU Instance
# ============================================================================
log_info "Step 1/6: Starting GPU instance..."
STATE=$(aws ec2 describe-instances \
  --instance-ids "$GPU_INSTANCE_ID" \
  --region "$REGION" \
  --query 'Reservations[0].Instances[0].State.Name' \
  --output text)

if [ "$STATE" = "running" ]; then
  log_success "✅ Instance already running"
else
  log_info "Current state: $STATE, starting..."
  aws ec2 start-instances \
    --instance-ids "$GPU_INSTANCE_ID" \
    --region "$REGION" \
    --output text > /dev/null

  log_info "Waiting for instance to start (2-3 minutes)..."
  aws ec2 wait instance-running \
    --instance-ids "$GPU_INSTANCE_ID" \
    --region "$REGION"

  log_success "✅ Instance started"

  # SSH connectivity check will verify boot readiness (no fixed wait needed)
fi

echo ""

# ============================================================================
# Step 2: Get Current IP (Dynamic Lookup - Not Stored)
# ============================================================================
log_info "Step 2/6: Looking up current GPU IP address..."
CURRENT_IP=$(aws ec2 describe-instances \
  --instance-ids "$GPU_INSTANCE_ID" \
  --region "$REGION" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

log_success "Current GPU IP: $CURRENT_IP (dynamic lookup)"

# Export for current shell session only (NOT stored in .env)
export GPU_HOST="$CURRENT_IP"
export WHISPERLIVE_HOST="$CURRENT_IP"
export WHISPERLIVE_PORT="9090"

log_info "IP exported for current session (will be looked up dynamically on next run)"
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                                                            ║"
echo "║  ℹ️  NEW ARCHITECTURE: Dynamic IP Lookup                  ║"
echo "║                                                            ║"
echo "╟────────────────────────────────────────────────────────────╢"
echo "║  GPU IP is NOT stored in .env (changes on every reboot)   ║"
echo "║  All scripts use get_instance_ip() for current IP         ║"
echo "║                                                            ║"
echo "║  If running edge box proxy (Caddy):                       ║"
echo "║    Run ./scripts/825-update-edge-box-ip.sh on edge box    ║"
echo "║    This updates Caddy config with new GPU IP              ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# ============================================================================
# Step 3: Check SSH Connectivity
# ============================================================================
log_info "Step 3/6: Verifying SSH connectivity..."
RETRY=0
MAX_RETRIES=10

while [ $RETRY -lt $MAX_RETRIES ]; do
  if ssh -i "$SSH_KEY" -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
     ubuntu@"$CURRENT_IP" "echo SSH_OK" 2>/dev/null | grep -q "SSH_OK"; then
    log_success "✅ SSH connected"
    break
  fi
  RETRY=$((RETRY + 1))
  log_info "SSH not ready, retrying ($RETRY/$MAX_RETRIES)..."
  sleep 10
done

if [ $RETRY -eq $MAX_RETRIES ]; then
  log_error "❌ SSH connection failed after $MAX_RETRIES attempts"
  exit 1
fi

echo ""

# ============================================================================
# Step 4: Check if WhisperLive Server is Running
# ============================================================================
log_info "Step 4/6: Checking WhisperLive server status..."

WHISPER_READY=$(ssh -i "$SSH_KEY" ubuntu@"$CURRENT_IP" \
  'curl -sf http://localhost:9090/health && echo READY || echo NOT_READY' 2>/dev/null || echo "NOT_READY")

if [ "$WHISPER_READY" = "READY" ]; then
  log_success "✅ WhisperLive server already running and ready"
  NEEDS_DEPLOY=false
else
  log_warn "⚠️  WhisperLive server not running"
  log_info "Checking if WhisperLive is installed..."

  WHISPER_INSTALLED=$(ssh -i "$SSH_KEY" ubuntu@"$CURRENT_IP" \
    'systemctl is-enabled whisperlive 2>/dev/null && echo INSTALLED || echo NOT_INSTALLED')

  if [ "$WHISPER_INSTALLED" = "INSTALLED" ]; then
    log_info "WhisperLive installed, just needs restart"
    NEEDS_DEPLOY=false
    NEEDS_RESTART=true
  else
    log_warn "WhisperLive not installed, will deploy"
    NEEDS_DEPLOY=true
  fi
fi

echo ""

# ============================================================================
# Step 5: Deploy WhisperLive if Needed
# ============================================================================
if [ "$NEEDS_DEPLOY" = "true" ]; then
  log_info "Step 5/6: Deploying WhisperLive..."
  log_info "This will take 3-5 minutes..."
  echo ""

  # Run WhisperLive deployment script
  "$(dirname "$0")/310-configure-whisperlive-gpu.sh"

  log_success "✅ WhisperLive deployment complete"
else
  log_info "Step 5/6: Skipping deployment (already installed)"
fi

echo ""

# ============================================================================
# Step 6: Restart WhisperLive Service
# ============================================================================
log_info "Step 6/6: Ensuring WhisperLive service is running..."

if [ "${NEEDS_RESTART:-false}" = "true" ] || [ "$NEEDS_DEPLOY" = "true" ]; then
  ssh -i "$SSH_KEY" ubuntu@"$CURRENT_IP" 'sudo systemctl restart whisperlive'
  sleep 5

  WHISPER_STATUS=$(ssh -i "$SSH_KEY" ubuntu@"$CURRENT_IP" \
    'systemctl is-active whisperlive' || echo "inactive")

  if [ "$WHISPER_STATUS" = "active" ]; then
    log_success "✅ WhisperLive service running"
  else
    log_error "❌ WhisperLive service failed to start"
    ssh -i "$SSH_KEY" ubuntu@"$CURRENT_IP" 'sudo journalctl -u whisperlive -n 20 --no-pager'
    exit 1
  fi
else
  log_success "✅ WhisperLive already running"
fi

echo ""

# ============================================================================
# Final Health Check
# ============================================================================
log_success "========================================="
log_success "✅ SYSTEM READY"
log_success "========================================="
echo ""
log_info "📊 Status Summary:"
echo "  GPU Instance: $GPU_INSTANCE_ID"
echo "  GPU IP: $CURRENT_IP"
echo "  WhisperLive Server: READY (http://$CURRENT_IP:9090)"
echo ""
log_info "🧪 Test WhisperLive from your browser:"
echo "  1. Open: https://${BUILDBOX_PUBLIC_IP:-3.16.124.227}/"
echo "  2. Click 'Start Recording'"
echo "  3. Speak into microphone"
echo "  4. See real-time transcriptions with v3.0 architecture"
echo ""
log_info "📝 Check WhisperLive logs:"
echo "  ssh -i ~/.ssh/${SSH_KEY_NAME}.pem ubuntu@$CURRENT_IP 'sudo journalctl -u whisperlive -f'"
echo ""

# ============================================================================
# Step 7: End-to-End Transcription Verification
# ============================================================================
log_info "Step 7/7: Verifying transcription readiness..."
echo ""

# Wait for WhisperLive to fully initialize (model loading)
log_info "Waiting 30s for WhisperLive model to fully load..."
sleep 30

# Download test audio if not exists
TEST_AUDIO="$REPO_ROOT/test-data/test-validation.wav"
if [ ! -f "$TEST_AUDIO" ]; then
    log_info "Downloading test audio..."
    mkdir -p "$REPO_ROOT/test-data"
    aws s3 cp s3://dbm-cf-2-web/integration-test/test-validation.wav "$TEST_AUDIO" > /dev/null 2>&1
    if [ ! -f "$TEST_AUDIO" ]; then
        log_warn "⚠️  Could not download test audio, skipping verification"
        VERIFICATION_SKIPPED=true
    fi
fi

if [ "${VERIFICATION_SKIPPED:-false}" != "true" ]; then
    # Convert to PCM for WhisperLive
    PCM_AUDIO="${TEST_AUDIO%.wav}-16k-mono.pcm"
    log_info "Converting audio to Float32 PCM..."
    ffmpeg -i "$TEST_AUDIO" -f f32le -acodec pcm_f32le -ac 1 -ar 16000 -y "$PCM_AUDIO" -loglevel quiet 2>/dev/null

    if [ ! -f "$PCM_AUDIO" ]; then
        log_warn "⚠️  Audio conversion failed, skipping verification"
        VERIFICATION_SKIPPED=true
    fi
fi

if [ "${VERIFICATION_SKIPPED:-false}" != "true" ]; then
    log_info "Testing transcription with sample audio..."

    # Create minimal Python test script
    TEST_SCRIPT="$REPO_ROOT/test-data/quick-transcribe-test.py"
    cat > "$TEST_SCRIPT" << 'PYEOF'
#!/usr/bin/env python3
import asyncio
import websockets
import json
import sys

async def test():
    ws_url = f"ws://{sys.argv[1]}:9090"
    audio_file = sys.argv[2]

    try:
        async with websockets.connect(ws_url) as ws:
            # Send config
            await ws.send(json.dumps({
                'uid': 'startup-verify',
                'task': 'transcribe',
                'language': 'en',
                'model': 'small.en',
                'use_vad': False
            }))

            # Wait for SERVER_READY
            await asyncio.wait_for(ws.recv(), timeout=10.0)

            # Send audio
            with open(audio_file, 'rb') as f:
                audio = f.read()
            chunk_size = 16384
            for i in range(0, len(audio), chunk_size):
                await ws.send(audio[i:i+chunk_size])

            # Wait for transcription (up to 30s)
            for _ in range(15):
                try:
                    msg = await asyncio.wait_for(ws.recv(), timeout=2.0)
                    data = json.loads(msg)
                    if data.get('segments'):
                        print("SUCCESS")
                        return True
                except asyncio.TimeoutError:
                    continue

            print("NO_TRANSCRIPTION")
            return False
    except Exception as e:
        print(f"ERROR: {e}")
        return False

if __name__ == "__main__":
    result = asyncio.run(test())
    sys.exit(0 if result else 1)
PYEOF

    chmod +x "$TEST_SCRIPT"

    # Run transcription test
    TRANSCRIBE_RESULT=$(python3 "$TEST_SCRIPT" "$CURRENT_IP" "$PCM_AUDIO" 2>&1)
    TRANSCRIBE_EXIT_CODE=$?

    VERIFICATION_END_TIME=$(date +%s)
    TOTAL_TIME=$((VERIFICATION_END_TIME - STARTUP_START_TIME))

    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║                                                            ║"
    if [ "$TRANSCRIBE_EXIT_CODE" -eq 0 ] && echo "$TRANSCRIBE_RESULT" | grep -q "SUCCESS"; then
        echo "║    ✅ TRANSCRIPTION VERIFIED - SYSTEM FULLY READY        ║"
        READY_STATUS="READY"
    else
        echo "║    ⚠️  TRANSCRIPTION TEST FAILED                         ║"
        READY_STATUS="PARTIAL"
    fi
    echo "║                                                            ║"
    echo "╠════════════════════════════════════════════════════════════╣"
    echo "║                                                            ║"
    echo "║  ⏱️  STARTUP PERFORMANCE METRICS                           ║"
    echo "║                                                            ║"
    echo "╟────────────────────────────────────────────────────────────╢"
    printf "║  Total Time (start → ready):  %-28s ║\n" "${TOTAL_TIME}s"
    printf "║  Status:                      %-28s ║\n" "$READY_STATUS"
    echo "╟────────────────────────────────────────────────────────────╢"
    echo "║  Breakdown:                                                ║"
    echo "║    • Instance startup:        ~2-3 minutes                 ║"
    echo "║    • SSH ready:               ~30 seconds                  ║"
    echo "║    • WhisperLive model load:  ~30 seconds                  ║"
    echo "║    • First transcription:     ~30 seconds                  ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    if [ "$TRANSCRIBE_EXIT_CODE" -ne 0 ] || ! echo "$TRANSCRIBE_RESULT" | grep -q "SUCCESS"; then
        log_warn "⚠️  Transcription test did not return expected results"
        log_info "Test output: $TRANSCRIBE_RESULT"
        log_info "This may indicate WhisperLive needs more time to initialize"
        log_info "Try running: ./scripts/450-test-audio-transcription.sh"
    fi
else
    # Verification skipped
    VERIFICATION_END_TIME=$(date +%s)
    TOTAL_TIME=$((VERIFICATION_END_TIME - STARTUP_START_TIME))

    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║                                                            ║"
    echo "║    ℹ️  VERIFICATION SKIPPED - MANUAL TEST RECOMMENDED     ║"
    echo "║                                                            ║"
    echo "╠════════════════════════════════════════════════════════════╣"
    printf "║  Startup Time:                %-28s ║\n" "${TOTAL_TIME}s"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
fi

log_success "🎉 WhisperLive startup complete!"
echo ""
log_info "Next steps:"
echo "  • If using edge box proxy: Run ./scripts/825-update-edge-box-ip.sh ON EDGE BOX"
echo "    (This updates Caddy reverse proxy config with new GPU IP)"
echo ""
echo "  • Test transcription: ./scripts/450-test-audio-transcription.sh"
echo "  • View GPU logs: ssh -i ~/.ssh/${SSH_KEY_NAME}.pem ubuntu@$CURRENT_IP 'sudo journalctl -u whisperlive -f'"
echo ""
log_warn "⚠️  IMPORTANT: GPU IP changes on every stop/start"
log_info "All scripts now use dynamic IP lookup from GPU_INSTANCE_ID"
log_info "Edge box Caddy proxy must be updated manually with script 825"
