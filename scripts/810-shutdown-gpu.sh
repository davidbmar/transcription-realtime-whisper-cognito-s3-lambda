#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# RIVA-210: Safely Shutdown GPU Instance
# ============================================================================
# Stops the GPU worker instance to save costs while preserving all state.
# All models and configuration remain intact for quick startup.
#
# What this does:
# 1. Verifies GPU instance is running
# 2. Stops the GPU EC2 instance
# 3. Confirms shutdown
#
# Cost savings: ~$0.526/hour when stopped (only EBS storage)
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
    echo "To fix this, run one of these commands first:"
    echo ""
    echo "Option 1: Use an existing GPU instance"
    echo "  1. List available GPUs:"
    echo "     aws ec2 describe-instances --region us-east-2 --filters \"Name=instance-type,Values=g4dn.*\" --output table"
    echo ""
    echo "  2. Start the GPU and set instance ID:"
    echo "     ./scripts/730-start-gpu-instance.sh --instance-id i-XXXXXXXXX"
    echo ""
    echo "Option 2: Create a new GPU instance"
    echo "  ./scripts/020-deploy-gpu-instance.sh"
    echo ""
    exit 1
fi

REGION="${AWS_REGION:-us-east-2}"

log_info "🛑 Shutting down GPU instance"
log_info "Instance: $GPU_INSTANCE_ID"
log_info "Region: $REGION"
echo ""

# Check current state
log_info "Checking instance state..."
STATE=$(aws ec2 describe-instances \
  --instance-ids "$GPU_INSTANCE_ID" \
  --region "$REGION" \
  --query 'Reservations[0].Instances[0].State.Name' \
  --output text)

if [ "$STATE" = "stopped" ]; then
  log_success "✅ Instance already stopped"
  exit 0
fi

if [ "$STATE" != "running" ]; then
  log_warn "⚠️  Instance in state: $STATE (not running or stopped)"
  exit 1
fi

log_info "Current state: $STATE"
echo ""

# Stop instance
log_info "Stopping instance..."
aws ec2 stop-instances \
  --instance-ids "$GPU_INSTANCE_ID" \
  --region "$REGION" \
  --output text

echo ""
log_info "Waiting for instance to stop (this may take 30-60 seconds)..."
aws ec2 wait instance-stopped \
  --instance-ids "$GPU_INSTANCE_ID" \
  --region "$REGION"

log_success "✅ GPU instance stopped successfully"
echo ""
log_info "💰 Cost savings: ~\$0.526/hour (only EBS storage charges apply)"
log_info "📁 All data preserved: /opt/riva/models_conformer_ctc_streaming/"
echo ""
log_info "To restart tomorrow: ./scripts/820-startup-restore.sh"
