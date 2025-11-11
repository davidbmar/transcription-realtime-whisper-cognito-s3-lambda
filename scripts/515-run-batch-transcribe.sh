#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Script 515: Run Batch Transcription (Main Orchestrator)
# ============================================================================
# Main orchestrator for batch transcription system with smart GPU management.
# Scans S3 for missing transcriptions FIRST, then only starts GPU if needed.
#
# What this does:
# 1. Checks batch lock (skips if live session active)
# 2. Calls 512-scan-missing-chunks.sh (fast, no GPU)
# 3. If no missing chunks: Generates report and exits (no GPU start)
# 4. If missing chunks found:
#    - Checks GPU state (running/stopped)
#    - Starts GPU if stopped (sets WE_STARTED_GPU=true)
#    - Waits for GPU ready (~90 seconds)
#    - SSHs to GPU and transcribes all pending chunks
#    - Uploads results to S3
#    - Stops GPU if we started it (guaranteed via trap)
# 5. Generates batch report with costs and stats
#
# Requirements:
# - .env variables: COGNITO_S3_BUCKET, GPU_INSTANCE_IP, GPU_INSTANCE_ID,
#                   GPU_SSH_KEY_PATH, AWS_REGION, COGNITO_API_ENDPOINT
# - AWS credentials configured with EC2 permissions
# - Scripts 500, 505, 512 must exist
# - GPU instance must have batch-transcribe-audio.py deployed
#
# Total time:
# - If no jobs: ~5-15 seconds (scan only)
# - If jobs exist: ~3-10 minutes (GPU startup + transcription + shutdown)
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
echo "515: Run Batch Transcription"
echo "============================================"
echo ""

log_info "This script will:"
log_info "  1. Check batch lock status"
log_info "  2. Scan S3 for missing transcriptions (512)"
log_info "  3. Start GPU only if work exists"
log_info "  4. Transcribe all pending chunks"
log_info "  5. Generate batch report"
echo ""

# ============================================================================
# Configuration
# ============================================================================

# Handle both absolute and relative paths for SSH key
if [[ "$GPU_SSH_KEY_PATH" = /* ]]; then
    SSH_KEY="$GPU_SSH_KEY_PATH"  # Absolute path
else
    SSH_KEY="$PROJECT_ROOT/$GPU_SSH_KEY_PATH"  # Relative path
fi
SSH_USER="ubuntu"
GPU_IP="${GPU_INSTANCE_IP}"
GPU_ID="${GPU_INSTANCE_ID}"
S3_BUCKET="${COGNITO_S3_BUCKET}"
AWS_REGION="${AWS_REGION:-us-east-2}"
API_ENDPOINT="${COGNITO_API_ENDPOINT}"

PENDING_JOBS_FILE="/tmp/pending-jobs.json"
REPORT_DIR="$PROJECT_ROOT/batch-reports"
REPORT_FILE="$REPORT_DIR/batch-$(date +%Y-%m-%d-%H%M).json"

# GPU cost tracking
GPU_HOURLY_COST=0.526  # g4dn.xlarge on-demand pricing
WE_STARTED_GPU=false
GPU_START_TIME=""
GPU_STOP_TIME=""

# Statistics
TIMESTAMP_START=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
SCAN_START=$(date +%s)
SCAN_DURATION=0
CHUNKS_TRANSCRIBED=0
CHUNKS_FAILED=0

# ============================================================================
# Cleanup & Safety
# ============================================================================

cleanup() {
    local exit_code=$?

    # CRITICAL: Ensure GPU shutdown if we started it
    if [ "$WE_STARTED_GPU" = "true" ]; then
        log_warn "Ensuring GPU shutdown (trap cleanup)..."
        GPU_STOP_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        if aws ec2 stop-instances --instance-ids "$GPU_ID" --region "$AWS_REGION" &>/dev/null; then
            log_info "GPU stop initiated, waiting for confirmation..."
            if aws ec2 wait instance-stopped --instance-ids "$GPU_ID" --region "$AWS_REGION" 2>/dev/null; then
                log_success "GPU stopped successfully"
            else
                log_warn "GPU stop wait timed out, but stop was initiated"
            fi
        else
            log_error "Failed to stop GPU - MANUAL INTERVENTION REQUIRED"
            log_error "Run: aws ec2 stop-instances --instance-ids $GPU_ID"
        fi
    fi

    exit $exit_code
}
trap cleanup EXIT INT TERM

# ============================================================================
# Helper Functions
# ============================================================================

check_batch_lock() {
    log_info "Step 1: Checking batch lock status..."

    # Check lock via API
    LOCK_STATUS=$(curl -s "${API_ENDPOINT}/api/batch/lock-status" || echo '{"error": true}')

    if echo "$LOCK_STATUS" | jq -e '.locked == true' &>/dev/null; then
        log_info "Batch lock is ACTIVE - live session in progress"

        # Generate skipped report
        mkdir -p "$REPORT_DIR"
        cat > "$REPORT_FILE" <<EOF
{
  "timestamp": "$TIMESTAMP_START",
  "status": "skipped",
  "reason": "batch_lock_active",
  "lockStatus": $LOCK_STATUS
}
EOF

        log_info "Report saved: $REPORT_FILE"
        log_info "Exiting - batch will run after live session completes"
        exit 0
    fi

    log_success "No batch lock - safe to proceed"
}

run_scanner() {
    log_info "Step 2: Scanning S3 for missing transcriptions..." >&2

    # Call 512-scan script
    if [ ! -x "$PROJECT_ROOT/scripts/512-scan-missing-chunks.sh" ]; then
        log_error "Scanner script not found: scripts/512-scan-missing-chunks.sh" >&2
        log_info "Run: ./scripts/500-setup-batch-transcription.sh" >&2
        exit 1
    fi

    # Run scanner and capture output (last line is chunk count)
    SCANNER_OUTPUT=$("$PROJECT_ROOT/scripts/512-scan-missing-chunks.sh" 2>&1)
    MISSING_COUNT=$(echo "$SCANNER_OUTPUT" | tail -1)

    # Validate output
    if ! [[ "$MISSING_COUNT" =~ ^[0-9]+$ ]]; then
        log_error "Scanner did not return valid chunk count" >&2
        log_error "Output: $MISSING_COUNT" >&2
        exit 1
    fi

    SCAN_END=$(date +%s)
    SCAN_DURATION=$((SCAN_END - SCAN_START))

    log_success "Scan completed in ${SCAN_DURATION}s - Found $MISSING_COUNT missing chunks" >&2

    echo "$MISSING_COUNT"
}

check_gpu_state() {
    log_info "Checking GPU instance state..." >&2

    GPU_STATE=$(aws ec2 describe-instances \
        --instance-ids "$GPU_ID" \
        --region "$AWS_REGION" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text 2>/dev/null || echo "unknown")

    log_info "GPU state: $GPU_STATE" >&2
    echo "$GPU_STATE"
}

start_gpu() {
    log_info "Step 3: Starting GPU instance..."
    GPU_START_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    if ! aws ec2 start-instances --instance-ids "$GPU_ID" --region "$AWS_REGION" &>/dev/null; then
        log_error "Failed to start GPU instance"
        exit 1
    fi

    WE_STARTED_GPU=true
    log_info "GPU start initiated, waiting for running state..."

    if aws ec2 wait instance-running --instance-ids "$GPU_ID" --region "$AWS_REGION" 2>/dev/null; then
        log_success "GPU is running"
    else
        log_error "Timeout waiting for GPU to start"
        exit 1
    fi

    # Wait for SSH to be ready
    log_info "Waiting for SSH to be ready..."
    local retries=30
    local count=0

    while [ $count -lt $retries ]; do
        if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
            "$SSH_USER@$GPU_IP" "echo 'SSH OK'" &>/dev/null; then
            log_success "SSH connection ready"
            return 0
        fi
        count=$((count + 1))
        sleep 3
    done

    log_error "Timeout waiting for SSH"
    exit 1
}

stop_gpu() {
    log_info "Step 5: Stopping GPU instance..."
    GPU_STOP_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    if ! aws ec2 stop-instances --instance-ids "$GPU_ID" --region "$AWS_REGION" &>/dev/null; then
        log_error "Failed to stop GPU instance"
        return 1
    fi

    log_info "GPU stop initiated, waiting for stopped state..."

    if aws ec2 wait instance-stopped --instance-ids "$GPU_ID" --region "$AWS_REGION" 2>/dev/null; then
        log_success "GPU stopped successfully"
    else
        log_warn "Timeout waiting for GPU to stop (stop was initiated)"
    fi
}

transcribe_all_chunks() {
    log_info "Step 4: Transcribing all pending chunks..."

    # Read pending jobs
    if [ ! -f "$PENDING_JOBS_FILE" ]; then
        log_error "Pending jobs file not found: $PENDING_JOBS_FILE"
        exit 1
    fi

    local session_count=$(jq -r '.sessions | length' "$PENDING_JOBS_FILE")
    local total_chunks=$(jq -r '.totalMissingChunks' "$PENDING_JOBS_FILE")
    log_info "Processing $session_count sessions with $total_chunks missing chunks"
    echo ""

    # Process each session (use temp file to avoid fd conflicts with exec tee)
    local sessions_file="/tmp/batch-sessions-$$.json"
    jq -c '.sessions[]' "$PENDING_JOBS_FILE" > "$sessions_file"

    local session_num=0
    while read -r session_data; do
        session_num=$((session_num + 1))

        local session_path=$(echo "$session_data" | jq -r '.sessionPath')
        local session_id=$(echo "$session_data" | jq -r '.sessionId')
        local missing_chunks=$(echo "$session_data" | jq -r '.missingChunks[]')
        local chunk_count=$(echo "$session_data" | jq -r '.missingCount')

        log_info "Session $session_num/$session_count: $session_id ($chunk_count chunks)"

        # Transcribe each missing chunk
        for chunk_num in $missing_chunks; do
            local current_total=$((CHUNKS_TRANSCRIBED + CHUNKS_FAILED + 1))
            log_info "  Processing chunk $chunk_num [$current_total/$total_chunks total]..."
            if transcribe_chunk "$session_path" "$chunk_num"; then
                CHUNKS_TRANSCRIBED=$((CHUNKS_TRANSCRIBED + 1))
                log_success "  Chunk $chunk_num complete [$CHUNKS_TRANSCRIBED succeeded, $CHUNKS_FAILED failed]"
            else
                CHUNKS_FAILED=$((CHUNKS_FAILED + 1))
                log_warn "  Chunk $chunk_num failed [$CHUNKS_TRANSCRIBED succeeded, $CHUNKS_FAILED failed]"
            fi
        done

        echo ""
    done < "$sessions_file"

    rm -f "$sessions_file"

    log_success "Transcription complete: $CHUNKS_TRANSCRIBED succeeded, $CHUNKS_FAILED failed"
}

transcribe_chunk() {
    local session_path=$1
    local chunk_num=$2

    local audio_s3="s3://$S3_BUCKET/$session_path/chunk-${chunk_num}.webm"
    local trans_s3="s3://$S3_BUCKET/$session_path/transcription-chunk-${chunk_num}.json"
    local audio_edge="/tmp/batch-chunk-${chunk_num}.webm"
    local trans_edge="/tmp/batch-transcription-${chunk_num}.json"
    local audio_gpu="/tmp/batch-chunk-${chunk_num}.webm"
    local trans_gpu="/tmp/batch-transcription-${chunk_num}.json"

    log_info "  Chunk $chunk_num: Downloading audio from S3..."

    # Download audio from S3 to edge box
    if ! aws s3 cp "$audio_s3" "$audio_edge" 2>/dev/null; then
        log_error "    Failed to download audio from S3"
        return 1
    fi

    log_info "  Chunk $chunk_num: Transferring to GPU..."

    # Transfer audio to GPU
    if ! scp -i "$SSH_KEY" "$audio_edge" "$SSH_USER@$GPU_IP:$audio_gpu" 2>/dev/null; then
        log_error "    Failed to transfer audio to GPU"
        rm -f "$audio_edge"
        return 1
    fi

    log_info "  Chunk $chunk_num: Transcribing on GPU..."

    # Run transcription on GPU (with proper LD_LIBRARY_PATH for CUDA)
    if ! ssh -i "$SSH_KEY" "$SSH_USER@$GPU_IP" \
        "cd ~/whisperlive/WhisperLive && source venv/bin/activate && \
         export LD_LIBRARY_PATH=\$PWD/venv/lib/python3.9/site-packages/nvidia/cudnn/lib:\$PWD/venv/lib/python3.9/site-packages/nvidia/cublas/lib:\$LD_LIBRARY_PATH && \
         python3 ~/batch-transcription/batch-transcribe-audio.py '$audio_gpu' > '$trans_gpu' 2>&1"; then
        log_error "    Transcription failed on GPU"
        rm -f "$audio_edge"
        ssh -i "$SSH_KEY" "$SSH_USER@$GPU_IP" "rm -f '$audio_gpu' '$trans_gpu'" 2>/dev/null || true
        return 1
    fi

    log_info "  Chunk $chunk_num: Retrieving transcription..."

    # Transfer transcription back from GPU
    if ! scp -i "$SSH_KEY" "$SSH_USER@$GPU_IP:$trans_gpu" "$trans_edge" 2>/dev/null; then
        log_error "    Failed to retrieve transcription from GPU"
        rm -f "$audio_edge"
        ssh -i "$SSH_KEY" "$SSH_USER@$GPU_IP" "rm -f '$audio_gpu' '$trans_gpu'" 2>/dev/null || true
        return 1
    fi

    log_info "  Chunk $chunk_num: Uploading to S3..."

    # Upload transcription to S3
    if ! aws s3 cp "$trans_edge" "$trans_s3" 2>/dev/null; then
        log_error "    Failed to upload transcription to S3"
        rm -f "$audio_edge" "$trans_edge"
        ssh -i "$SSH_KEY" "$SSH_USER@$GPU_IP" "rm -f '$audio_gpu' '$trans_gpu'" 2>/dev/null || true
        return 1
    fi

    # Cleanup
    rm -f "$audio_edge" "$trans_edge"
    ssh -i "$SSH_KEY" "$SSH_USER@$GPU_IP" "rm -f '$audio_gpu' '$trans_gpu'" 2>/dev/null || true

    log_success "  Chunk $chunk_num: Complete"
    return 0
}

generate_report() {
    local status=$1
    local gpu_was_running=$2
    local missing_count=$3

    log_info "Step 6: Generating batch report..."

    local timestamp_end=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local total_end=$(date +%s)
    local total_duration=$((total_end - SCAN_START))

    # Calculate GPU cost
    local gpu_runtime=0
    local gpu_cost=0
    if [ -n "$GPU_START_TIME" ] && [ -n "$GPU_STOP_TIME" ]; then
        local start_epoch=$(date -d "$GPU_START_TIME" +%s 2>/dev/null || date +%s)
        local stop_epoch=$(date -d "$GPU_STOP_TIME" +%s 2>/dev/null || date +%s)
        gpu_runtime=$((stop_epoch - start_epoch))
        gpu_cost=$(awk "BEGIN {printf \"%.3f\", ($gpu_runtime / 3600.0) * $GPU_HOURLY_COST}")
    fi

    # Read scan data
    local sessions_scanned=0
    local sessions_with_missing=0
    if [ -f "$PENDING_JOBS_FILE" ]; then
        sessions_scanned=$(jq -r '.sessionsScanned' "$PENDING_JOBS_FILE" || echo "0")
        sessions_with_missing=$(jq -r '.sessionsWithMissingChunks' "$PENDING_JOBS_FILE" || echo "0")
    fi

    mkdir -p "$REPORT_DIR"

    cat > "$REPORT_FILE" <<EOF
{
  "timestamp": "$TIMESTAMP_START",
  "timestampEnd": "$timestamp_end",
  "status": "$status",
  "lockStatus": {
    "locked": false
  },
  "scan": {
    "sessionsScanned": $sessions_scanned,
    "sessionsWithMissingChunks": $sessions_with_missing,
    "totalMissingChunks": $missing_count,
    "durationSeconds": $SCAN_DURATION
  },
  "gpu": {
    "wasRunning": $gpu_was_running,
    "weStartedIt": $WE_STARTED_GPU,
    "startTime": "${GPU_START_TIME:-null}",
    "stopTime": "${GPU_STOP_TIME:-null}",
    "runtimeSeconds": $gpu_runtime,
    "costUSD": $gpu_cost
  },
  "transcription": {
    "chunksTranscribed": $CHUNKS_TRANSCRIBED,
    "chunksFailed": $CHUNKS_FAILED
  },
  "performance": {
    "totalDurationSeconds": $total_duration
  }
}
EOF

    log_success "Report saved: $REPORT_FILE"
}

# ============================================================================
# Main Execution
# ============================================================================

log_info "Starting batch transcription orchestrator..."
echo ""

# Step 1: Check batch lock
check_batch_lock
echo ""

# Step 2: Run scanner
MISSING_COUNT=$(run_scanner)
echo ""

# If no missing chunks, generate report and exit
if [ "$MISSING_COUNT" -eq 0 ]; then
    log_info "No missing chunks found - no GPU needed"
    generate_report "success" false 0

    log_info "==================================================================="
    log_success "✅ BATCH SCAN COMPLETE - NO WORK NEEDED"
    log_info "==================================================================="
    echo ""
    log_info "All audio chunks have transcriptions!"
    exit 0
fi

# Step 3: Check GPU state and start if needed
GPU_STATE=$(check_gpu_state)
GPU_WAS_RUNNING=false

if [ "$GPU_STATE" = "running" ]; then
    log_info "GPU is already running"
    GPU_WAS_RUNNING=true
elif [ "$GPU_STATE" = "stopped" ]; then
    start_gpu
    echo ""
else
    log_error "GPU state is '$GPU_STATE' - cannot proceed"
    exit 1
fi

# Step 4: Transcribe all pending chunks
transcribe_all_chunks
echo ""

# Step 5: Stop GPU if we started it
if [ "$WE_STARTED_GPU" = "true" ]; then
    stop_gpu
    echo ""
fi

# Step 6: Generate report
generate_report "success" $GPU_WAS_RUNNING "$MISSING_COUNT"
echo ""

# ============================================================================
# Success Reporting
# ============================================================================

log_info "==================================================================="
log_success "✅ BATCH TRANSCRIPTION COMPLETE"
log_info "==================================================================="
echo ""
log_info "Summary:"
log_info "  - Missing chunks found: $MISSING_COUNT"
log_info "  - Chunks transcribed: $CHUNKS_TRANSCRIBED"
log_info "  - Chunks failed: $CHUNKS_FAILED"
if [ "$WE_STARTED_GPU" = "true" ]; then
    log_info "  - GPU runtime: ${gpu_runtime}s (~$((gpu_runtime / 60)) minutes)"
    log_info "  - GPU cost: \$$gpu_cost"
fi
log_info "  - Report: $REPORT_FILE"
echo ""

if [ $CHUNKS_FAILED -gt 0 ]; then
    log_warn "Some chunks failed - check logs for details"
fi

log_info "Next Steps:"
log_info "  1. View report: cat $REPORT_FILE | jq ."
log_info "  2. Check scheduler: systemctl status batch-transcribe.timer"
log_info "  3. View logs: ls -lart logs/515-*.log"
echo ""
