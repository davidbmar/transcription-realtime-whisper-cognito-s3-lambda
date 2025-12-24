#!/bin/bash
set -euo pipefail

# ============================================================================
# Script 535: Smart Batch Transcription Scheduler
# ============================================================================
# Intelligent scheduler with RunPod-first strategy and AWS fallback.
#
# STRATEGY:
#   1. Check queue size against threshold
#   2. Try RunPod first (cheaper: $0.13-0.20/hr)
#   3. If RunPod fails OR queue still has items after 4 hours → AWS fallback
#   4. Human-readable logs for easy debugging
#
# WORKFLOW:
#   ┌─────────────────────────────────────────────────────────────────┐
#   │  Check Queue Size                                               │
#   │       ↓                                                         │
#   │  Below threshold? → Skip, log, exit                             │
#   │       ↓                                                         │
#   │  PRE-MERGE AUDIO (516-merge-chunks-worker.sh)                   │
#   │  - Runs on Edge Box (CPU, no GPU needed)                        │
#   │  - ffmpeg merges chunks → single audio.wav per session          │
#   │  - Ensures consistent speaker diarization                       │
#   │       ↓                                                         │
#   │  Try RunPod (850-start → 515-runpod-transcribe → 855-stop)      │
#   │       ↓                                                         │
#   │  Success? → Done!                                               │
#   │       ↓                                                         │
#   │  Failed OR 4h timeout with queue remaining?                     │
#   │       ↓                                                         │
#   │  Fallback to AWS EC2 (820-start → 515-aws-transcribe → 810-stop)│
#   └─────────────────────────────────────────────────────────────────┘
#
# Configuration (.env):
#   BATCH_THRESHOLD=100              # Min chunks to trigger batch run
#   BATCH_MAX_RUNTIME_HOURS=2        # Max time for single provider attempt
#   BATCH_SCHEDULER_CHECK_HOURS=2    # How often this runs (cron)
#   RUNPOD_FALLBACK_HOURS=4          # Hours before AWS fallback
#
# Usage:
#   ./535-smart-batch-scheduler.sh              # Normal run
#   ./535-smart-batch-scheduler.sh --dry-run    # Show what would happen
#   ./535-smart-batch-scheduler.sh --force-aws  # Skip RunPod, use AWS
#
# ============================================================================

# Resolve script path (handles symlinks)
if [ -L "${BASH_SOURCE[0]}" ]; then
    SCRIPT_REAL=$(readlink -f "${BASH_SOURCE[0]}")
else
    SCRIPT_REAL="${BASH_SOURCE[0]}"
fi
PROJECT_ROOT="$(cd "$(dirname "$SCRIPT_REAL")/.." && pwd)"

# Setup logging
mkdir -p "$PROJECT_ROOT/logs"
LOG_FILE="$PROJECT_ROOT/logs/535-scheduler-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Load environment and libraries
source "$PROJECT_ROOT/.env"
source "$PROJECT_ROOT/scripts/lib/common-functions.sh"

# ============================================================================
# Configuration
# ============================================================================

BATCH_THRESHOLD="${BATCH_THRESHOLD:-100}"
MAX_RUNTIME_HOURS="${BATCH_MAX_RUNTIME_HOURS:-2}"
CHECK_HOURS="${BATCH_SCHEDULER_CHECK_HOURS:-1}"
RUNPOD_FALLBACK_HOURS="${RUNPOD_FALLBACK_HOURS:-6}"

LOCK_FILE="/tmp/batch-transcribe.lock"
QUEUE_LOG="/var/log/batch-queue.log"
SCHEDULER_STATE="/tmp/scheduler-state.json"
PENDING_JOBS_FILE="/tmp/pending-jobs.json"

DRY_RUN=false
FORCE_AWS=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --force-aws)
            FORCE_AWS=true
            shift
            ;;
        --help)
            head -50 "$0" | grep "^#" | sed 's/^# //' | sed 's/^#//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# ============================================================================
# Human-Readable Logging
# ============================================================================

# Prints a nice header box
print_header() {
    local title="$1"
    local width=60
    local padding=$(( (width - ${#title} - 2) / 2 ))

    echo ""
    printf '═%.0s' $(seq 1 $width); echo ""
    printf '║%*s%s%*s║\n' $padding "" "$title" $((width - padding - ${#title} - 2)) ""
    printf '═%.0s' $(seq 1 $width); echo ""
    echo ""
}

# Prints a status line with icon
status_line() {
    local icon="$1"
    local label="$2"
    local value="$3"
    printf "  %s %-20s %s\n" "$icon" "$label" "$value"
}

# Log an event to the human-readable log
log_event() {
    local event="$1"
    local details="$2"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")

    echo ""
    echo "┌─────────────────────────────────────────────────────────────"
    echo "│ [$timestamp] $event"
    echo "│ $details"
    echo "└─────────────────────────────────────────────────────────────"
    echo ""
}

# ============================================================================
# State Management
# ============================================================================

save_state() {
    local provider="$1"
    local status="$2"
    local started_at="${3:-$(date +%s)}"

    cat > "$SCHEDULER_STATE" <<EOF
{
    "provider": "$provider",
    "status": "$status",
    "started_at": $started_at,
    "updated_at": $(date +%s),
    "missing_chunks_at_start": ${MISSING_CHUNKS:-0}
}
EOF
}

load_state() {
    if [ -f "$SCHEDULER_STATE" ]; then
        cat "$SCHEDULER_STATE"
    else
        echo '{"provider":"none","status":"idle","started_at":0}'
    fi
}

clear_state() {
    rm -f "$SCHEDULER_STATE"
}

# ============================================================================
# Queue Management
# ============================================================================

ensure_queue_log_dir() {
    local log_dir=$(dirname "$QUEUE_LOG")
    if [[ ! -d "$log_dir" ]]; then
        sudo mkdir -p "$log_dir" 2>/dev/null || mkdir -p "$log_dir"
    fi
    if [[ ! -f "$QUEUE_LOG" ]]; then
        sudo touch "$QUEUE_LOG" 2>/dev/null || touch "$QUEUE_LOG"
        sudo chmod 644 "$QUEUE_LOG" 2>/dev/null || true
    fi
}

log_queue_event() {
    local action="$1"
    local provider="$2"
    local chunk_count="$3"
    local details="${4:-}"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")

    ensure_queue_log_dir

    # Human-readable format
    echo "$timestamp | $action | Provider: $provider | Chunks: $chunk_count | $details" | \
        sudo tee -a "$QUEUE_LOG" >/dev/null 2>&1 || \
        echo "$timestamp | $action | Provider: $provider | Chunks: $chunk_count | $details" >> "$QUEUE_LOG"
}

get_missing_chunks() {
    # Log to stderr so it doesn't mix with the count output
    log_info "Scanning S3 for missing transcriptions..." >&2

    if ! "$PROJECT_ROOT/scripts/512-scan-missing-chunks.sh" >/dev/null 2>&1; then
        log_error "Failed to scan for missing chunks" >&2
        echo "0"
        return 1
    fi

    if [ ! -f "$PENDING_JOBS_FILE" ]; then
        echo "0"
        return 0
    fi

    # Use totalPendingJobs which includes both missing transcriptions AND re-diarization jobs
    jq -r '.totalPendingJobs // 0' "$PENDING_JOBS_FILE" 2>/dev/null || echo "0"
}

# ============================================================================
# Provider Functions
# ============================================================================

start_runpod() {
    log_event "STARTING RUNPOD" "Launching GPU pod on RunPod community cloud..."

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would execute: ./scripts/850-runpod--start.sh"
        return 0
    fi

    if "$PROJECT_ROOT/scripts/850-runpod--start.sh"; then
        log_success "RunPod started successfully"
        return 0
    else
        log_error "Failed to start RunPod"
        return 1
    fi
}

run_runpod_transcription() {
    log_event "RUNPOD TRANSCRIPTION" "Processing batch via RunPod WhisperX API..."

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would execute: ./scripts/515-runpod--batch-transcribe.sh"
        return 0
    fi

    if "$PROJECT_ROOT/scripts/515-runpod--batch-transcribe.sh"; then
        log_success "RunPod transcription completed"
        return 0
    else
        log_warn "RunPod transcription had issues"
        return 1
    fi
}

stop_runpod() {
    log_event "STOPPING RUNPOD" "Terminating pod to save costs..."

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would execute: ./scripts/855-runpod--stop.sh --force"
        return 0
    fi

    "$PROJECT_ROOT/scripts/855-runpod--stop.sh" --force 2>/dev/null || true
    log_success "RunPod stopped"
}

start_aws() {
    log_event "STARTING AWS EC2" "Launching GPU instance on AWS..."

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would execute: ./scripts/820-aws--startup-restore.sh"
        return 0
    fi

    if "$PROJECT_ROOT/scripts/820-aws--startup-restore.sh"; then
        log_success "AWS EC2 started successfully"
        return 0
    else
        log_error "Failed to start AWS EC2"
        return 1
    fi
}

run_aws_transcription() {
    log_event "AWS TRANSCRIPTION" "Processing batch via AWS EC2 GPU..."

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would execute: ./scripts/515-aws--batch-transcribe.sh"
        return 0
    fi

    if "$PROJECT_ROOT/scripts/515-aws--batch-transcribe.sh"; then
        log_success "AWS transcription completed"
        return 0
    else
        log_warn "AWS transcription had issues"
        return 1
    fi
}

stop_aws() {
    log_event "STOPPING AWS EC2" "Shutting down GPU instance to save costs..."

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would execute: ./scripts/810-aws--shutdown-gpu.sh"
        return 0
    fi

    "$PROJECT_ROOT/scripts/810-aws--shutdown-gpu.sh" 2>/dev/null || true
    log_success "AWS EC2 stopped"
}

# ============================================================================
# Check for Existing Run / Fallback Needed
# ============================================================================

check_runpod_fallback_needed() {
    local state=$(load_state)
    local provider=$(echo "$state" | jq -r '.provider')
    local started_at=$(echo "$state" | jq -r '.started_at')
    local now=$(date +%s)

    if [ "$provider" != "runpod" ]; then
        return 1  # Not a RunPod run, no fallback check needed
    fi

    local elapsed_hours=$(( (now - started_at) / 3600 ))

    if [ $elapsed_hours -ge $RUNPOD_FALLBACK_HOURS ]; then
        log_warn "RunPod has been running for ${elapsed_hours}h (threshold: ${RUNPOD_FALLBACK_HOURS}h)"
        return 0  # Fallback needed
    fi

    return 1  # No fallback needed yet
}

# ============================================================================
# Main Scheduler Logic
# ============================================================================

main() {
    print_header "SMART BATCH SCHEDULER"

    local run_start=$(date +%s)
    local run_timestamp=$(date "+%Y-%m-%d %H:%M:%S")

    echo "  Run started:     $run_timestamp"
    echo "  Log file:        $LOG_FILE"
    echo ""

    # Show configuration
    echo "  Configuration:"
    status_line "📊" "Threshold:" "$BATCH_THRESHOLD chunks"
    status_line "⏱️ " "Check interval:" "$CHECK_HOURS hours"
    status_line "🔄" "RunPod timeout:" "$RUNPOD_FALLBACK_HOURS hours"
    status_line "💰" "Strategy:" "RunPod first → AWS fallback"

    if [ "$DRY_RUN" = true ]; then
        echo ""
        log_warn "DRY RUN MODE - No actual changes will be made"
    fi

    if [ "$FORCE_AWS" = true ]; then
        echo ""
        log_warn "FORCE AWS MODE - Skipping RunPod, using AWS directly"
    fi

    echo ""

    # ========================================================================
    # Step 1: Check lock
    # ========================================================================

    log_info "Step 1: Checking for existing batch process..."

    if [ -f "$LOCK_FILE" ]; then
        local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            log_event "SKIPPED" "Batch already running (PID: $lock_pid)"
            exit 0
        else
            log_info "Removing stale lock file"
            rm -f "$LOCK_FILE"
        fi
    fi

    log_success "No active batch process"

    # ========================================================================
    # Step 2: Check queue size
    # ========================================================================

    log_info "Step 2: Scanning queue..."

    MISSING_CHUNKS=$(get_missing_chunks)

    echo ""
    status_line "📦" "Pending jobs:" "$MISSING_CHUNKS"
    status_line "🎯" "Threshold:" "$BATCH_THRESHOLD"
    echo ""

    if [ "$MISSING_CHUNKS" -lt "$BATCH_THRESHOLD" ]; then
        log_event "QUEUE BELOW THRESHOLD" "Found $MISSING_CHUNKS pending jobs, need $BATCH_THRESHOLD to trigger processing"

        log_queue_event "SKIPPED" "none" "$MISSING_CHUNKS" "Below threshold ($BATCH_THRESHOLD)"

        echo ""
        echo "  📝 Summary:"
        echo "     Nothing to do - queue is below threshold"
        echo "     Next check in $CHECK_HOURS hours"
        echo ""

        exit 0
    fi

    log_success "Queue threshold met! Processing $MISSING_CHUNKS pending jobs..."

    # ========================================================================
    # Step 3: Check for RunPod fallback
    # ========================================================================

    log_info "Step 3: Checking for pending RunPod fallback..."

    if check_runpod_fallback_needed; then
        log_event "RUNPOD TIMEOUT" "RunPod exceeded ${RUNPOD_FALLBACK_HOURS}h, switching to AWS"

        # Stop RunPod first
        stop_runpod
        clear_state

        # Force AWS
        FORCE_AWS=true
    else
        log_success "No fallback needed"
    fi

    # ========================================================================
    # Step 4: Pre-merge audio chunks (CPU, no GPU needed)
    # ========================================================================
    # This step merges 2-minute audio chunks into single files BEFORE GPU processing.
    # Why: WebM chunks cannot be concatenated with 'cat' - they need ffmpeg.
    # Running this on Edge Box (CPU) ensures WhisperX sees full audio for proper diarization.

    log_info "Step 4: Pre-merging audio chunks on Edge Box (CPU)..."

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would execute: ./scripts/516-merge-chunks-worker.sh"
    elif [ ! -x "$PROJECT_ROOT/scripts/516-merge-chunks-worker.sh" ]; then
        # Graceful fallback if merge script doesn't exist yet
        log_warn "Merge worker script not found - transcription will merge on-the-fly"
        log_info "Tip: Create 516-merge-chunks-worker.sh for faster processing"
    else
        if "$PROJECT_ROOT/scripts/516-merge-chunks-worker.sh"; then
            log_success "Audio chunks merged successfully"
        else
            log_warn "Merge worker had issues (transcription will merge on-the-fly as fallback)"
        fi
    fi

    echo ""

    # ========================================================================
    # Step 5: Run transcription
    # ========================================================================

    # Create lock
    echo $$ > "$LOCK_FILE"
    trap "rm -f '$LOCK_FILE'" EXIT

    local provider_used=""
    local success=false

    if [ "$FORCE_AWS" = true ]; then
        # ---- AWS Path ----
        provider_used="AWS"

        log_event "USING AWS EC2" "Starting AWS GPU workflow..."
        log_queue_event "STARTED" "aws" "$MISSING_CHUNKS" "Forced or fallback"

        save_state "aws" "running"

        if start_aws; then
            if run_aws_transcription; then
                success=true
            fi
            stop_aws
        fi

    else
        # ---- RunPod Path (Primary) ----
        provider_used="RunPod"

        log_event "USING RUNPOD" "Starting RunPod GPU workflow (cheaper option)..."
        log_queue_event "STARTED" "runpod" "$MISSING_CHUNKS" "Primary provider"

        save_state "runpod" "running"

        if start_runpod; then
            if run_runpod_transcription; then
                success=true
                stop_runpod
            else
                # RunPod transcription failed - try AWS
                log_event "RUNPOD FAILED" "Transcription failed, falling back to AWS..."
                stop_runpod

                provider_used="AWS (fallback)"
                log_queue_event "FALLBACK" "aws" "$MISSING_CHUNKS" "RunPod failed"

                save_state "aws" "running"

                if start_aws; then
                    if run_aws_transcription; then
                        success=true
                    fi
                    stop_aws
                fi
            fi
        else
            # RunPod failed to start - try AWS
            log_event "RUNPOD START FAILED" "Could not start RunPod, falling back to AWS..."

            provider_used="AWS (fallback)"
            log_queue_event "FALLBACK" "aws" "$MISSING_CHUNKS" "RunPod start failed"

            save_state "aws" "running"

            if start_aws; then
                if run_aws_transcription; then
                    success=true
                fi
                stop_aws
            fi
        fi
    fi

    clear_state

    # ========================================================================
    # Step 6: Verify and report
    # ========================================================================

    log_info "Step 6: Verifying results..."

    local remaining_chunks=$(get_missing_chunks)
    local processed=$((MISSING_CHUNKS - remaining_chunks))
    local run_end=$(date +%s)
    local duration_mins=$(( (run_end - run_start) / 60 ))

    print_header "SCHEDULER COMPLETE"

    echo "  📊 Results:"
    status_line "✅" "Provider used:" "$provider_used"
    status_line "📥" "Started with:" "$MISSING_CHUNKS chunks"
    status_line "📤" "Processed:" "$processed chunks"
    status_line "📦" "Remaining:" "$remaining_chunks chunks"
    status_line "⏱️ " "Duration:" "${duration_mins} minutes"
    echo ""

    if [ "$success" = true ] && [ "$remaining_chunks" -eq 0 ]; then
        log_success "All chunks processed successfully!"
        log_queue_event "COMPLETED" "$provider_used" "0" "All chunks processed in ${duration_mins}m"
    elif [ "$success" = true ]; then
        log_warn "Completed with $remaining_chunks chunks remaining"
        log_queue_event "PARTIAL" "$provider_used" "$remaining_chunks" "Processed $processed, ${duration_mins}m"
    else
        log_error "Transcription failed"
        log_queue_event "FAILED" "$provider_used" "$remaining_chunks" "Error during processing"
    fi

    echo ""
    echo "  📝 Next scheduled run in $CHECK_HOURS hours"
    echo "  📄 Log file: $LOG_FILE"
    echo ""
}

# ============================================================================
# Run
# ============================================================================

main "$@"
