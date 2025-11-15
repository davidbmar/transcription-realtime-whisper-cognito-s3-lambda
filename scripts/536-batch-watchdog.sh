#!/bin/bash

#============================================================================
# Script: 536-batch-watchdog.sh
# Description: Safety watchdog that kills long-running batch transcription jobs
#              and ensures GPU shutdown to prevent runaway costs
#
# Usage: ./scripts/536-batch-watchdog.sh
#
# Environment Variables:
#   BATCH_MAX_RUNTIME_MINUTES - Maximum runtime in minutes (default: 110 = 1h 50min)
#   BATCH_LOCK_FILE - Path to batch lock file (default: /tmp/batch-transcribe.lock)
#
# Design:
#   - Runs as independent watchdog (called by systemd timer or cron)
#   - Checks if batch transcription is running
#   - If runtime exceeds threshold, terminates process and ensures GPU shutdown
#   - Logs all actions to /var/log/batch-watchdog.log
#
# Safety:
#   - Sends SIGTERM first (triggers cleanup trap in 515)
#   - Waits 10 seconds for graceful shutdown
#   - Sends SIGKILL if process still alive
#   - Verifies GPU shutdown and forces stop if needed
#============================================================================

set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common-functions.sh"
source "$SCRIPT_DIR/lib/gpu-cost-functions.sh"

# Configuration
LOCK_FILE="${BATCH_LOCK_FILE:-/tmp/batch-transcribe.lock}"
MAX_RUNTIME_MINUTES="${BATCH_MAX_RUNTIME_MINUTES:-110}"  # 1h 50min (10min buffer before next 2h run)
WATCHDOG_LOG="/var/log/batch-watchdog.log"

# GPU configuration
load_environment
GPU_ID="${GPU_INSTANCE_ID}"

#============================================================================
# Logging Functions
#============================================================================

log_watchdog() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Log to file
    echo "[$timestamp] [$level] $message" | sudo tee -a "$WATCHDOG_LOG" >/dev/null

    # Also log to console with color
    case "$level" in
        ERROR)   log_error "$message" ;;
        WARN)    log_warn "$message" ;;
        SUCCESS) log_success "$message" ;;
        *)       log_info "$message" ;;
    esac
}

#============================================================================
# GPU Verification
#============================================================================

verify_gpu_stopped() {
    local gpu_id="$1"

    log_watchdog INFO "Verifying GPU state..."

    local state=$(aws ec2 describe-instances \
        --instance-ids "$gpu_id" \
        --region "$AWS_REGION" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text 2>/dev/null || echo "unknown")

    if [ "$state" = "stopped" ]; then
        log_watchdog SUCCESS "GPU is confirmed stopped"
        return 0
    elif [ "$state" = "stopping" ]; then
        log_watchdog WARN "GPU is stopping, waiting for confirmation..."
        if aws ec2 wait instance-stopped --instance-ids "$gpu_id" --region "$AWS_REGION" 2>/dev/null; then
            log_watchdog SUCCESS "GPU stopped successfully"
            return 0
        else
            log_watchdog WARN "GPU stop wait timed out"
            return 1
        fi
    else
        log_watchdog ERROR "GPU is still running (state: $state)"
        return 1
    fi
}

force_gpu_shutdown() {
    local gpu_id="$1"

    log_watchdog WARN "Forcing GPU shutdown..."

    if aws ec2 stop-instances --instance-ids "$gpu_id" --region "$AWS_REGION" &>/dev/null; then
        log_watchdog INFO "GPU stop command sent, waiting for confirmation..."

        if aws ec2 wait instance-stopped --instance-ids "$gpu_id" --region "$AWS_REGION" 2>/dev/null; then
            log_watchdog SUCCESS "GPU force-stopped successfully"

            # Log to cost tracker
            local stop_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            gpu_log_stop "$gpu_id" "0" "unknown" "$stop_time" "watchdog-forced"

            return 0
        else
            log_watchdog ERROR "GPU stop wait timed out after force command"
            return 1
        fi
    else
        log_watchdog ERROR "Failed to send GPU stop command"
        log_watchdog ERROR "MANUAL INTERVENTION REQUIRED: aws ec2 stop-instances --instance-ids $gpu_id"
        return 1
    fi
}

#============================================================================
# Main Watchdog Logic
#============================================================================

main() {
    log_watchdog INFO "=========================================="
    log_watchdog INFO "Batch Watchdog Check Started"
    log_watchdog INFO "Max runtime: ${MAX_RUNTIME_MINUTES} minutes"
    log_watchdog INFO "=========================================="

    # Check if lock file exists
    if [ ! -f "$LOCK_FILE" ]; then
        log_watchdog INFO "No batch transcription running (no lock file)"
        exit 0
    fi

    # Read PID from lock file
    local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")

    if [ -z "$lock_pid" ]; then
        log_watchdog WARN "Lock file exists but contains no PID, removing stale lock"
        rm -f "$LOCK_FILE"
        exit 0
    fi

    # Check if process is actually running
    if ! kill -0 "$lock_pid" 2>/dev/null; then
        log_watchdog WARN "Lock file references dead process (PID: $lock_pid), removing stale lock"
        rm -f "$LOCK_FILE"
        exit 0
    fi

    # Calculate runtime
    local lock_time=$(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo "0")
    local now=$(date +%s)
    local age_minutes=$(( (now - lock_time) / 60 ))

    log_watchdog INFO "Batch transcription running: PID $lock_pid, runtime: ${age_minutes} minutes"

    # Check if runtime exceeds threshold
    if [ $age_minutes -lt $MAX_RUNTIME_MINUTES ]; then
        log_watchdog INFO "Runtime within limits (${age_minutes}/${MAX_RUNTIME_MINUTES} min), no action needed"
        exit 0
    fi

    #========================================================================
    # SAFETY MECHANISM TRIGGERED
    #========================================================================

    log_watchdog ERROR "=========================================="
    log_watchdog ERROR "SAFETY THRESHOLD EXCEEDED"
    log_watchdog ERROR "Runtime: ${age_minutes} minutes (limit: ${MAX_RUNTIME_MINUTES})"
    log_watchdog ERROR "Terminating runaway batch process"
    log_watchdog ERROR "=========================================="

    # Log to cost tracker
    gpu_log_stop "$GPU_ID" "0" "unknown" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "watchdog-terminated"

    # Step 1: Send SIGTERM (triggers cleanup trap in script 515)
    log_watchdog WARN "Sending SIGTERM to PID $lock_pid (triggers cleanup trap)"
    if kill -TERM "$lock_pid" 2>/dev/null; then
        log_watchdog INFO "SIGTERM sent successfully"
    else
        log_watchdog WARN "Failed to send SIGTERM (process may have already exited)"
    fi

    # Step 2: Wait for graceful shutdown
    log_watchdog INFO "Waiting 10 seconds for graceful shutdown..."
    sleep 10

    # Step 3: Check if process still alive
    if kill -0 "$lock_pid" 2>/dev/null; then
        log_watchdog WARN "Process still alive after SIGTERM, sending SIGKILL"
        kill -9 "$lock_pid" 2>/dev/null || true
        sleep 2

        if kill -0 "$lock_pid" 2>/dev/null; then
            log_watchdog ERROR "Process survived SIGKILL! This should not happen."
        else
            log_watchdog SUCCESS "Process terminated with SIGKILL"
        fi
    else
        log_watchdog SUCCESS "Process terminated gracefully after SIGTERM"
    fi

    # Step 4: Create backoff marker to prevent immediate retry
    local backoff_file="/tmp/batch-transcribe-backoff"
    local backoff_until=$(( $(date +%s) + 3600 ))  # Block retries for 1 hour
    echo "$backoff_until" > "$backoff_file"
    log_watchdog WARN "Created backoff marker: no retries until $(date -d @$backoff_until)"

    # Step 5: Remove lock file
    log_watchdog INFO "Removing lock file"
    rm -f "$LOCK_FILE"

    # Step 5: Verify GPU is stopped
    log_watchdog INFO "Verifying GPU shutdown..."
    if ! verify_gpu_stopped "$GPU_ID"; then
        log_watchdog ERROR "GPU did not shut down automatically!"

        # Force GPU shutdown
        if force_gpu_shutdown "$GPU_ID"; then
            log_watchdog SUCCESS "GPU shutdown complete (forced)"
        else
            log_watchdog ERROR "=========================================="
            log_watchdog ERROR "CRITICAL: GPU SHUTDOWN FAILED"
            log_watchdog ERROR "GPU Instance: $GPU_ID"
            log_watchdog ERROR "MANUAL INTERVENTION REQUIRED"
            log_watchdog ERROR "Run: aws ec2 stop-instances --instance-ids $GPU_ID"
            log_watchdog ERROR "=========================================="
            exit 1
        fi
    else
        log_watchdog SUCCESS "GPU shutdown verified"
    fi

    log_watchdog SUCCESS "=========================================="
    log_watchdog SUCCESS "Safety mechanism complete"
    log_watchdog SUCCESS "Runaway process terminated"
    log_watchdog SUCCESS "GPU confirmed stopped"
    log_watchdog SUCCESS "System ready for next batch run"
    log_watchdog SUCCESS "=========================================="
}

# Run main function
main "$@"
