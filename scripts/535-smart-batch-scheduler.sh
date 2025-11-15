#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Script 535: Smart Batch Transcription Scheduler
# ============================================================================
# Intelligent scheduler that only starts GPU when there's enough work to do.
# This script is designed to run periodically (via cron or systemd timer) and
# makes smart decisions about when to process batch transcriptions.
#
# What this does:
# 1. Check if batch transcription is already running (lock file)
# 2. Scan S3 for missing transcription chunks (512)
# 3. Compare missing count against threshold (default: 100)
# 4. If threshold met: Run batch transcription (515)
# 5. If threshold not met: Skip and log the queue size
# 6. Track queue trends over time
#
# Smart Features:
# - Configurable threshold (BATCH_THRESHOLD)
# - Prevents concurrent runs with lock file
# - Max runtime safety (BATCH_MAX_RUNTIME_HOURS)
# - Queue trend logging for adaptive scheduling
# - Graceful handling of persistent queues
#
# Configuration (.env):
#   BATCH_THRESHOLD=100              # Min chunks to trigger batch run
#   BATCH_MAX_RUNTIME_HOURS=2        # Safety cutoff for long runs
#   BATCH_SCHEDULER_CHECK_HOURS=2    # How often this runs
#
# Systemd timer setup:
#   - Use script 510 to configure systemd timer
#   - Default: Run every 2 hours
#
# Manual usage:
#   ./535-smart-batch-scheduler.sh         # Use default threshold
#   BATCH_THRESHOLD=50 ./535-smart-batch-scheduler.sh  # Custom threshold
#
# Requirements:
# - Scripts: 512 (scan), 515 (batch transcribe)
# - .env variables: BATCH_THRESHOLD, GPU_INSTANCE_ID
# - AWS CLI with S3 and EC2 access
# - jq installed
# ============================================================================

# Resolve script path (handles symlinks)
if [ -L "${BASH_SOURCE[0]}" ]; then
    SCRIPT_REAL=$(readlink -f "${BASH_SOURCE[0]}")
else
    SCRIPT_REAL="${BASH_SOURCE[0]}"
fi
PROJECT_ROOT="$(cd "$(dirname "$SCRIPT_REAL")/.." && pwd)"

# Load environment and libraries
source "$PROJECT_ROOT/.env"
source "$PROJECT_ROOT/scripts/lib/common-functions.sh"

echo "============================================"
echo "535: Smart Batch Transcription Scheduler"
echo "============================================"
echo ""

# ============================================================================
# Configuration
# ============================================================================

BATCH_THRESHOLD="${BATCH_THRESHOLD:-100}"
MAX_RUNTIME_HOURS="${BATCH_MAX_RUNTIME_HOURS:-2}"
CHECK_HOURS="${BATCH_SCHEDULER_CHECK_HOURS:-2}"

LOCK_FILE="/tmp/batch-transcribe.lock"
QUEUE_LOG="/var/log/batch-queue.log"
PENDING_JOBS_FILE="/tmp/pending-jobs.json"

# Validate tools
if ! command -v jq &>/dev/null; then
    log_error "jq is required but not installed"
    exit 1
fi

log_info "Scheduler Configuration:"
log_info "  Threshold:        $BATCH_THRESHOLD chunks"
log_info "  Check interval:   $CHECK_HOURS hours"
log_info "  Max runtime:      $MAX_RUNTIME_HOURS hours"
echo ""

# ============================================================================
# Helper Functions
# ============================================================================

# Ensure queue log directory exists
ensure_queue_log_dir() {
    local log_dir=$(dirname "$QUEUE_LOG")
    if [[ ! -d "$log_dir" ]]; then
        sudo mkdir -p "$log_dir"
        sudo chmod 755 "$log_dir"
    fi

    if [[ ! -f "$QUEUE_LOG" ]]; then
        sudo touch "$QUEUE_LOG"
        sudo chmod 644 "$QUEUE_LOG"
    fi
}

# Log queue size for trend analysis
log_queue_size() {
    local chunk_count="$1"
    local action="$2"  # "skipped" or "processing"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local epoch=$(date +%s)

    ensure_queue_log_dir

    # Format: TIMESTAMP|EPOCH|ACTION|CHUNK_COUNT|THRESHOLD
    echo "${timestamp}|${epoch}|${action}|${chunk_count}|${BATCH_THRESHOLD}" | \
        sudo tee -a "$QUEUE_LOG" >/dev/null
}

# Check if batch is already running
check_batch_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        local lock_time=$(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo "0")
        local now=$(date +%s)
        local age_hours=$(( (now - lock_time) / 3600 ))

        # Check if process is actually running
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            log_info "Batch transcription already running (PID: $lock_pid)"

            # Safety check: Has it been running too long?
            if [ $age_hours -ge $MAX_RUNTIME_HOURS ]; then
                log_warn "Batch has been running for ${age_hours}h (threshold: ${MAX_RUNTIME_HOURS}h)"
                log_warn "Consider investigating PID $lock_pid"
            fi

            return 1  # Lock exists and process is running
        else
            log_warn "Stale lock file found (PID: $lock_pid, age: ${age_hours}h)"
            log_info "Removing stale lock file"
            rm -f "$LOCK_FILE"
            return 0  # Lock removed, can proceed
        fi
    fi

    return 0  # No lock, can proceed
}

# Get queue statistics for last N hours
get_queue_stats() {
    local hours="${1:-24}"
    local cutoff_epoch=$(($(date +%s) - (hours * 3600)))

    if [[ ! -f "$QUEUE_LOG" ]]; then
        echo '{"trend":"unknown","avg_queue":0,"samples":0}'
        return 0
    fi

    local total=0
    local count=0
    local last_size=0

    while IFS='|' read -r timestamp epoch action chunk_count threshold; do
        if [[ $epoch -lt $cutoff_epoch ]]; then
            continue
        fi

        total=$((total + chunk_count))
        count=$((count + 1))
        last_size=$chunk_count
    done < "$QUEUE_LOG"

    if [[ $count -eq 0 ]]; then
        echo '{"trend":"unknown","avg_queue":0,"samples":0}'
        return 0
    fi

    local avg=$((total / count))
    local trend="stable"

    # Simple trend detection
    if [[ $last_size -gt $((avg + avg / 4)) ]]; then
        trend="growing"
    elif [[ $last_size -lt $((avg - avg / 4)) ]]; then
        trend="shrinking"
    fi

    cat <<EOF
{
  "trend": "$trend",
  "avg_queue": $avg,
  "current_queue": $last_size,
  "samples": $count,
  "period_hours": $hours
}
EOF
}

# ============================================================================
# Main Scheduler Logic
# ============================================================================

log_info "Step 1: Checking for existing batch process..."

if ! check_batch_lock; then
    log_info "Batch is currently running, skipping this run"
    log_info "Next check in $CHECK_HOURS hours"
    exit 0
fi

log_success "No batch lock - safe to proceed"
echo ""

# ============================================================================
# Step 2: Scan for missing chunks
# ============================================================================

log_info "Step 2: Scanning S3 for missing transcriptions..."

# Run scan script (512)
if ! "$PROJECT_ROOT/scripts/512-scan-missing-chunks.sh"; then
    log_error "Failed to scan for missing chunks"
    exit 1
fi

# Get missing chunk count from scan results
if [ ! -f "$PENDING_JOBS_FILE" ]; then
    log_error "Pending jobs file not found: $PENDING_JOBS_FILE"
    exit 1
fi

MISSING_CHUNKS=$(jq -r '.totalMissingChunks' "$PENDING_JOBS_FILE")

log_info "Missing chunks found: $MISSING_CHUNKS"
echo ""

# ============================================================================
# Step 3: Decide whether to run batch transcription
# ============================================================================

log_info "Step 3: Evaluating threshold..."
log_info "  Missing chunks: $MISSING_CHUNKS"
log_info "  Threshold:      $BATCH_THRESHOLD"
echo ""

if [ $MISSING_CHUNKS -lt $BATCH_THRESHOLD ]; then
    log_info "Below threshold - skipping batch transcription"
    log_info "  Missing: $MISSING_CHUNKS"
    log_info "  Need:    $BATCH_THRESHOLD"
    log_info "  Deficit: $((BATCH_THRESHOLD - MISSING_CHUNKS))"

    # Log queue size
    log_queue_size "$MISSING_CHUNKS" "skipped"

    # Show queue trend
    log_info ""
    log_info "Queue Trend (last 24h):"
    stats=$(get_queue_stats 24)
    trend=$(echo "$stats" | jq -r '.trend')
    avg=$(echo "$stats" | jq -r '.avg_queue')
    samples=$(echo "$stats" | jq -r '.samples')

    log_info "  Trend:   $trend"
    log_info "  Average: $avg chunks"
    log_info "  Samples: $samples checks"

    if [[ "$trend" == "growing" ]]; then
        log_warn "Queue is growing - may reach threshold soon"
    fi

    log_info ""
    log_info "Next check in $CHECK_HOURS hours"
    exit 0
fi

# ============================================================================
# Step 4: Run batch transcription
# ============================================================================

log_success "Threshold met! Starting batch transcription..."
log_info "  Missing chunks: $MISSING_CHUNKS"
log_info "  Threshold:      $BATCH_THRESHOLD"
echo ""

# Log queue size before processing
log_queue_size "$MISSING_CHUNKS" "processing"

# Run batch transcription (515)
log_info "Executing batch transcription..."
log_info "Command: $PROJECT_ROOT/scripts/515-run-batch-transcribe.sh"
echo ""

if "$PROJECT_ROOT/scripts/515-run-batch-transcribe.sh"; then
    log_success "Batch transcription completed successfully"
else
    exit_code=$?
    log_error "Batch transcription failed with exit code $exit_code"
    exit $exit_code
fi

echo ""
log_info "====================================================================="
log_success "SCHEDULER RUN COMPLETE"
log_info "====================================================================="
log_info ""
log_info "Summary:"
log_info "  - Chunks found:  $MISSING_CHUNKS"
log_info "  - Threshold:     $BATCH_THRESHOLD"
log_info "  - Action:        Batch transcription executed"
log_info ""
log_info "Next scheduled run in $CHECK_HOURS hours"
log_info ""
