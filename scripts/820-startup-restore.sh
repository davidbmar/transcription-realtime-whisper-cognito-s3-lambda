#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Script 220: Startup GPU and Restore WhisperLive
# ============================================================================
# Complete one-command restoration of WhisperLive streaming setup.
# Run this after shutting down the GPU to save costs.
#
# What this does:
# 1. Starts GPU EC2 instance (uses GPU_INSTANCE_ID from .env)
# 2. Waits for instance to be ready
# 3. Queries AWS for current IP (IP changes on every stop/start)
# 4. If IP changed, updates ALL config files:
#    - .env (GPU_INSTANCE_IP, GPU_HOST)
#    - .env-http (DOMAIN, GPU_HOST)
# 5. If IP changed, updates AWS security groups
# 6. If IP changed, recreates Docker containers (Caddy) to load new IP
# 7. Verifies SSH connectivity
# 8. Checks WhisperLive service status
# 9. Deploys WhisperLive if needed (calls 310-configure-whisperlive-gpu.sh)
# 10. Ensures WhisperLive service is running
#
# Architecture: Instance ID is source of truth, IP is resolved at startup
# Total time: 3-5 minutes (2min startup + 1-3min deployment if needed)
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

# Validate GPU_INSTANCE_ID is set
if [ -z "${GPU_INSTANCE_ID:-}" ]; then
    log_error "❌ GPU_INSTANCE_ID not set in .env"
    echo ""
    echo "To fix this, you have two options:"
    echo ""
    echo "Option 1: Use an existing GPU instance"
    echo "  1. List available GPUs:"
    echo "     aws ec2 describe-instances --region us-east-2 --filters \"Name=instance-type,Values=g4dn.*\" --output table"
    echo ""
    echo "  2. Start the GPU and set instance ID:"
    echo "     ./scripts/730-start-gpu-instance.sh --instance-id i-XXXXXXXXX"
    echo "     (This will update .env with GPU_INSTANCE_ID)"
    echo ""
    echo "Option 2: Create a new GPU instance"
    echo "  ./scripts/020-deploy-gpu-instance.sh"
    echo ""
    exit 1
fi

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
# Step 2: Get Current IP and Update .env if Changed
# ============================================================================
log_info "Step 2/6: Checking GPU IP address..."
CURRENT_IP=$(aws ec2 describe-instances \
  --instance-ids "$GPU_INSTANCE_ID" \
  --region "$REGION" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

log_info "Current GPU IP: $CURRENT_IP"

OLD_IP=$(grep "^GPU_INSTANCE_IP=" .env | cut -d'=' -f2)

if [ "$CURRENT_IP" != "$OLD_IP" ]; then
  echo ""
  echo "╔════════════════════════════════════════════════════════════╗"
  echo "║                                                            ║"
  echo "║         ⚠️  CRITICAL: GPU IP ADDRESS HAS CHANGED          ║"
  echo "║                                                            ║"
  echo "╟────────────────────────────────────────────────────────────╢"
  echo "║  Old IP: $OLD_IP"
  echo "║  New IP: $CURRENT_IP"
  echo "╟────────────────────────────────────────────────────────────╢"
  echo "║  Actions being taken:                                      ║"
  echo "║   1. Updating all config files (.env, .env-http)           ║"
  echo "║   2. Exporting environment variables                       ║"
  echo "║   3. Reloading configuration                               ║"
  echo "║   4. Updating AWS security groups                          ║"
  echo "║   5. Recreating Docker containers (Caddy)                  ║"
  echo "╚════════════════════════════════════════════════════════════╝"
  echo ""

  log_info "Step 1/5: Updating configuration files..."

  # Update .env
  sed -i "s/^GPU_INSTANCE_IP=.*/GPU_INSTANCE_IP=$CURRENT_IP/" .env

  # Update GPU_HOST in main .env (create if doesn't exist)
  if grep -q "^GPU_HOST=" .env 2>/dev/null; then
    sed -i "s/^GPU_HOST=.*/GPU_HOST=$CURRENT_IP/" .env
  else
    echo "GPU_HOST=$CURRENT_IP" >> .env
  fi
  log_success "  ✅ .env updated"

  # Update .env-http (for WhisperLive edge proxy) - check multiple locations
  EDGE_ENV_HTTP_LOCATIONS=(
    "$HOME/event-b/whisper-live-test/.env-http"
    "$HOME/event-b/whisper-live-edge/.env-http"
    ".env-http"
  )

  ENV_HTTP_UPDATED=false
  for env_http_path in "${EDGE_ENV_HTTP_LOCATIONS[@]}"; do
    if [ -f "$env_http_path" ]; then
      sed -i "s/^DOMAIN=.*/DOMAIN=$CURRENT_IP/" "$env_http_path"
      sed -i "s/^GPU_HOST=.*/GPU_HOST=$CURRENT_IP/" "$env_http_path"
      log_success "  ✅ .env-http updated: $env_http_path"
      ENV_HTTP_UPDATED=true
    fi
  done

  if [ "$ENV_HTTP_UPDATED" = "false" ]; then
    log_info "  ℹ️  No .env-http found (edge proxy not configured)"
  fi

  log_success "✅ All configuration files updated"

  log_info "Step 2/5: Exporting environment variables..."
  export GPU_INSTANCE_IP="$CURRENT_IP"
  export GPU_HOST="$CURRENT_IP"
  log_success "✅ Variables exported for child scripts"

  log_info "Step 3/5: Reloading .env configuration..."
  load_environment
  log_success "✅ Configuration reloaded"

  log_info "Step 4/5: Updating AWS security groups..."
  if echo "1" | "$(dirname "$0")/030-configure-gpu-security.sh" > /dev/null 2>&1; then
    log_success "✅ Security groups updated successfully"
  else
    log_warn "⚠️  Security group update encountered issues"
    log_info "You may need to run manually: ./scripts/030-configure-gpu-security.sh"
  fi

  echo ""
  log_info "Step 5/5: Recreating Docker containers with new IP..."

  # Recreate Caddy container to pick up new GPU_HOST from .env-http
  if [ -f docker-compose.yml ]; then
    log_info "  Stopping Caddy container..."
    docker compose down 2>/dev/null || docker-compose down 2>/dev/null || true

    # Force remove if still exists (handles stale containers)
    if docker ps -a --format '{{.Names}}' | grep -q "whisperlive-edge"; then
      log_info "  Force removing stale Caddy container..."
      docker rm -f whisperlive-edge || true
    fi

    log_info "  Starting Caddy with updated GPU IP..."
    if docker compose up -d 2>/dev/null || docker-compose up -d 2>/dev/null; then
      log_success "  ✅ Caddy container recreated"
    else
      log_warn "  ⚠️  Failed to recreate Caddy container"
    fi
  fi

  echo ""
  echo "╔════════════════════════════════════════════════════════════╗"
  echo "║                                                            ║"
  echo "║    ✅ IP CHANGE COMPLETE - CONTINUING WITH DEPLOYMENT     ║"
  echo "║                                                            ║"
  echo "╚════════════════════════════════════════════════════════════╝"
  echo ""
else
  log_success "✅ IP unchanged: $CURRENT_IP"
fi

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
log_success "🎉 WhisperLive is ready for transcription!"
