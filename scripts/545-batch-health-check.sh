#!/bin/bash
set -euo pipefail

# ============================================================================
# Script 545: Batch Scheduler Health Check
# ============================================================================
# Quick health check for the batch transcription system. Verifies that
# all components are configured correctly and ready to run.
#
# What this checks:
# 1. Required scripts exist and are executable
# 2. Environment variables are set
# 3. Log directories are writable
# 4. GPU instance is accessible
# 5. S3 bucket is accessible
# 6. Scheduler configuration (systemd timer if configured)
#
# Usage:
#   ./545-batch-health-check.sh
#
# Exit codes:
#   0 - All checks passed
#   1 - One or more checks failed
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
echo "545: Batch Scheduler Health Check"
echo "============================================"
echo ""

CHECKS_PASSED=0
CHECKS_FAILED=0

check_pass() {
    echo "  ✅ $1"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
}

check_fail() {
    echo "  ❌ $1"
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
}

check_warn() {
    echo "  ⚠️  $1"
}

# Check 1: Required scripts
echo "Checking required scripts..."
for script in 512-scan-missing-chunks.sh 515-run-batch-transcribe.sh 530-gpu-cost-tracker.sh 535-smart-batch-scheduler.sh 540-gpu-usage-reporter.sh; do
    if [[ -x "$PROJECT_ROOT/scripts/$script" ]]; then
        check_pass "$script exists and is executable"
    else
        check_fail "$script missing or not executable"
    fi
done
echo ""

# Check 2: Environment variables
echo "Checking environment variables..."
for var in GPU_INSTANCE_ID GPU_SSH_KEY_PATH COGNITO_S3_BUCKET AWS_REGION BATCH_THRESHOLD; do
    if [[ -n "${!var:-}" ]]; then
        check_pass "$var is set"
    else
        check_fail "$var not set in .env"
    fi
done
echo ""

# Check 3: Log directories
echo "Checking log directories..."
for log_path in /var/log/gpu-cost.log /var/log/batch-queue.log; do
    log_dir=$(dirname "$log_path")
    if sudo test -d "$log_dir" && sudo test -w "$log_dir"; then
        check_pass "$(dirname $log_path)/ is writable"
    else
        check_warn "$(dirname $log_path)/ may need sudo"
    fi
done

if [[ -d "$PROJECT_ROOT/logs" && -w "$PROJECT_ROOT/logs" ]]; then
    check_pass "$PROJECT_ROOT/logs/ is writable"
else
    check_fail "$PROJECT_ROOT/logs/ not writable"
fi
echo ""

# Check 4: GPU access
echo "Checking GPU instance access..."
if [[ -n "${GPU_INSTANCE_ID:-}" ]]; then
    gpu_state=$(aws ec2 describe-instances \
        --instance-ids "$GPU_INSTANCE_ID" \
        --region "$AWS_REGION" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text 2>/dev/null || echo "error")

    if [[ "$gpu_state" != "error" ]]; then
        check_pass "GPU instance accessible (state: $gpu_state)"
    else
        check_fail "Cannot access GPU instance"
    fi
else
    check_fail "GPU_INSTANCE_ID not set"
fi
echo ""

# Check 5: S3 access
echo "Checking S3 bucket access..."
if [[ -n "${COGNITO_S3_BUCKET:-}" ]]; then
    if aws s3 ls "s3://$COGNITO_S3_BUCKET/" --max-items 1 &>/dev/null; then
        check_pass "S3 bucket accessible: $COGNITO_S3_BUCKET"
    else
        check_fail "Cannot access S3 bucket: $COGNITO_S3_BUCKET"
    fi
else
    check_fail "COGNITO_S3_BUCKET not set"
fi
echo ""

# Check 6: Systemd timer (if configured)
echo "Checking systemd timer (if configured)..."
if systemctl list-timers batch-transcribe.timer &>/dev/null; then
    timer_status=$(systemctl is-active batch-transcribe.timer 2>/dev/null || echo "inactive")
    if [[ "$timer_status" == "active" ]]; then
        check_pass "Systemd timer is active"
        next_run=$(systemctl status batch-transcribe.timer 2>/dev/null | grep "Trigger:" | sed 's/.*Trigger: //')
        echo "     Next run: $next_run"
    else
        check_warn "Systemd timer exists but is inactive"
    fi
else
    check_warn "Systemd timer not configured (optional)"
fi
echo ""

# Summary
echo "============================================"
echo "Health Check Summary"
echo "============================================"
echo "  Passed:  $CHECKS_PASSED"
echo "  Failed:  $CHECKS_FAILED"
echo ""

if [[ $CHECKS_FAILED -eq 0 ]]; then
    echo "✅ All critical checks passed"
    echo ""
    exit 0
else
    echo "❌ Some checks failed - review configuration"
    echo ""
    exit 1
fi
