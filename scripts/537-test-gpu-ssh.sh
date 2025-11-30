#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Script 537: Test GPU SSH Connection (Pre-flight Check)
# ============================================================================
# Diagnostic script that verifies GPU SSH connectivity using dynamic IP lookup.
# This is a pre-flight check to run before batch transcription jobs.
#
# What this does:
# 1. Looks up current GPU IP from instance ID (dynamic lookup)
# 2. Tests SSH connectivity to GPU
# 3. Verifies GPU instance is running
# 4. Reports clear pass/fail status
#
# Requirements:
# - .env variables: GPU_INSTANCE_ID, AWS_REGION, SSH_KEY_PATH
#
# Total time: ~10 seconds
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
source "$PROJECT_ROOT/scripts/common-library.sh"

echo "============================================"
echo "537: Test GPU SSH Connection"
echo "============================================"
echo ""

log_info "This script will:"
log_info "  1. Look up current GPU IP from instance ID"
log_info "  2. Check GPU instance state"
log_info "  3. Test SSH connectivity"
log_info "  4. Report pass/fail status"
echo ""

# ============================================================================
# Step 1: Verify Instance ID Configuration
# ============================================================================

log_info "Step 1: Verifying configuration..."

if [ -z "${GPU_INSTANCE_ID:-}" ]; then
    log_error "GPU_INSTANCE_ID not set in .env"
    log_error "Please add: GPU_INSTANCE_ID=i-xxxxxxxxxxxxx"
    exit 1
fi

log_success "GPU Instance ID: $GPU_INSTANCE_ID"
echo ""

# ============================================================================
# Step 2: Check GPU Instance State
# ============================================================================

log_info "Step 2: Checking GPU instance state..."

INSTANCE_STATE=$(aws ec2 describe-instances \
    --instance-ids "$GPU_INSTANCE_ID" \
    --region "${AWS_REGION}" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text 2>/dev/null || echo "unknown")

log_info "Instance state: $INSTANCE_STATE"

if [ "$INSTANCE_STATE" != "running" ]; then
    log_error "GPU instance is not running (state: $INSTANCE_STATE)"
    log_error "Start the instance first: ./scripts/530-start-gpu-instance.sh"
    exit 1
fi

log_success "GPU instance is running"
echo ""

# ============================================================================
# Step 3: Dynamic IP Lookup
# ============================================================================

log_info "Step 3: Looking up current GPU IP address..."

# Use dynamic IP lookup from instance ID
GPU_IP=$(get_instance_ip "$GPU_INSTANCE_ID")

if [ -z "$GPU_IP" ] || [ "$GPU_IP" = "None" ]; then
    log_error "Failed to get GPU IP from instance ID: $GPU_INSTANCE_ID"
    log_error "Check AWS CLI access: aws ec2 describe-instances --instance-ids $GPU_INSTANCE_ID"
    exit 1
fi

log_success "Current GPU IP: $GPU_IP (looked up from instance ID)"
echo ""

# ============================================================================
# Step 4: Test SSH Connection
# ============================================================================

log_info "Step 4: Testing SSH connection to GPU..."

# Handle both absolute and relative paths for SSH key (match pattern from script 515)
if [[ "${GPU_SSH_KEY_PATH:-}" = /* ]]; then
    SSH_KEY="$GPU_SSH_KEY_PATH"  # Absolute path
else
    SSH_KEY="$PROJECT_ROOT/${GPU_SSH_KEY_PATH:-~/.ssh/id_rsa}"  # Relative path or default
fi
SSH_USER="${SSH_USER:-ubuntu}"

log_info "SSH Key: $SSH_KEY"
log_info "SSH User: $SSH_USER"
log_info "Target: $SSH_USER@$GPU_IP"
echo ""

# Test SSH connection with timeout
log_info "Attempting SSH connection (5 second timeout)..."

if ssh -i "$SSH_KEY" \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=5 \
    -o BatchMode=yes \
    "$SSH_USER@$GPU_IP" \
    "echo 'SSH connection successful'" &>/dev/null; then

    log_success "✅ SSH connection: PASS"
    SSH_RESULT="PASS"
else
    log_error "❌ SSH connection: FAIL"
    log_error "Could not connect to $SSH_USER@$GPU_IP"
    SSH_RESULT="FAIL"
fi

echo ""

# ============================================================================
# Step 5: Additional Diagnostics (if SSH failed)
# ============================================================================

if [ "$SSH_RESULT" = "FAIL" ]; then
    log_warn "Running additional diagnostics..."
    echo ""

    # Check security group
    log_info "Checking security group rules..."
    SG_ID=$(aws ec2 describe-instances \
        --instance-ids "$GPU_INSTANCE_ID" \
        --region "${AWS_REGION}" \
        --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' \
        --output text 2>/dev/null || echo "unknown")

    if [ "$SG_ID" != "unknown" ]; then
        log_info "Security Group: $SG_ID"

        # Check if SSH port 22 is open
        SSH_RULE=$(aws ec2 describe-security-groups \
            --group-ids "$SG_ID" \
            --region "${AWS_REGION}" \
            --query "SecurityGroups[0].IpPermissions[?FromPort==\`22\`]" \
            --output json 2>/dev/null || echo "[]")

        if [ "$SSH_RULE" = "[]" ]; then
            log_warn "Port 22 (SSH) may not be open in security group"
        else
            log_info "Port 22 is configured in security group"
        fi
    fi
    echo ""

    # Test basic connectivity
    log_info "Testing basic network connectivity..."
    if ping -c 1 -W 2 "$GPU_IP" &>/dev/null; then
        log_info "✅ Ping successful (host is reachable)"
    else
        log_warn "❌ Ping failed (network may be blocked)"
    fi

    echo ""
fi

# ============================================================================
# Final Report
# ============================================================================

echo ""
log_info "==================================================================="
if [ "$SSH_RESULT" = "PASS" ]; then
    log_success "✅ GPU SSH TEST PASSED"
    log_info "==================================================================="
    echo ""
    log_info "Summary:"
    log_info "  - GPU Instance ID: $GPU_INSTANCE_ID"
    log_info "  - Current IP: $GPU_IP (dynamic lookup)"
    log_info "  - Instance State: $INSTANCE_STATE"
    log_info "  - SSH Connection: WORKING"
    echo ""
    log_info "System is ready for batch transcription!"
    echo ""
    log_info "Next Steps:"
    log_info "  1. Run batch transcription: ./scripts/515-run-batch-transcribe.sh"
    log_info "  2. Or test WhisperLive: ./scripts/325-test-whisperlive-connection.sh"
    echo ""
    exit 0
else
    log_error "❌ GPU SSH TEST FAILED"
    log_info "==================================================================="
    echo ""
    log_info "Summary:"
    log_info "  - GPU Instance ID: $GPU_INSTANCE_ID"
    log_info "  - Current IP: $GPU_IP (dynamic lookup)"
    log_info "  - Instance State: $INSTANCE_STATE"
    log_info "  - SSH Connection: FAILED"
    echo ""
    log_info "Troubleshooting:"
    log_info "  1. Check security group allows SSH from this IP"
    log_info "  2. Verify SSH key is correct: $SSH_KEY"
    log_info "  3. Try manual SSH: ssh -i $SSH_KEY $SSH_USER@$GPU_IP"
    log_info "  4. Check GPU instance logs in AWS console"
    echo ""
    exit 1
fi
