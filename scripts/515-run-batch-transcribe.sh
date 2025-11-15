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
source "$PROJECT_ROOT/scripts/lib/gpu-cost-functions.sh"

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

# Batch processing configuration (from .env, with defaults)
BATCH_SIZE="${BATCH_SIZE:-100}"                              # Process N chunks at once
BATCH_LIMIT="${BATCH_LIMIT:-0}"                              # Limit total chunks (0 = no limit, for testing)
BATCH_MAX_PARALLEL_DOWNLOAD="${BATCH_MAX_PARALLEL_DOWNLOAD:-20}"   # Concurrent S3 downloads
BATCH_MAX_PARALLEL_UPLOAD="${BATCH_MAX_PARALLEL_UPLOAD:-20}"       # Concurrent S3 uploads
BATCH_DOWNLOAD_THRESHOLD="${BATCH_DOWNLOAD_THRESHOLD:-30}"         # When to start GPU processing
BATCH_DOWNLOAD_TIMEOUT="${BATCH_DOWNLOAD_TIMEOUT:-60}"             # Max wait for initial downloads
WHISPER_MODEL="${WHISPER_MODEL:-small.en}"                          # Whisper model (tiny/base/small/medium)
WHISPER_COMPUTE_TYPE="${WHISPER_COMPUTE_TYPE:-float16}"            # Compute precision (int8/float16/float32)

# GPU cost tracking (from .env, with default)
GPU_HOURLY_COST="${GPU_HOURLY_COST:-0.526}"  # g4dn.xlarge on-demand pricing
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
        # Log GPU start event for cost tracking
        gpu_log_start "$GPU_ID" "batch-transcription-515"
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
        # Log GPU stop event for cost tracking
        gpu_log_stop "$GPU_ID" "batch-complete-515" "$CHUNKS_TRANSCRIBED"
    else
        log_warn "Timeout waiting for GPU to stop (stop was initiated)"
        # Log stop event even on timeout (stop was initiated)
        gpu_log_stop "$GPU_ID" "batch-timeout-515" "$CHUNKS_TRANSCRIBED"
    fi
}

transcribe_all_chunks() {
    log_info "Step 4: Transcribing all pending chunks..."
    log_info "Batch mode: $([[ $BATCH_SIZE -gt 1 ]] && echo "ENABLED (size=$BATCH_SIZE)" || echo "DISABLED (sequential)")"

    # Read pending jobs
    if [ ! -f "$PENDING_JOBS_FILE" ]; then
        log_error "Pending jobs file not found: $PENDING_JOBS_FILE"
        exit 1
    fi

    local session_count=$(jq -r '.sessions | length' "$PENDING_JOBS_FILE")
    local total_chunks=$(jq -r '.totalMissingChunks' "$PENDING_JOBS_FILE")

    # Apply limit if set (for testing)
    if [ $BATCH_LIMIT -gt 0 ] && [ $BATCH_LIMIT -lt $total_chunks ]; then
        log_info "BATCH_LIMIT set: Processing only $BATCH_LIMIT of $total_chunks chunks (for testing)"
        total_chunks=$BATCH_LIMIT
    fi

    log_info "Processing $session_count sessions with $total_chunks missing chunks"
    echo ""

    # Build flat list of all chunks to process
    local all_chunks=()
    local sessions_file="/tmp/batch-sessions-$$.json"
    jq -c '.sessions[]' "$PENDING_JOBS_FILE" > "$sessions_file"

    while read -r session_data; do
        local session_path=$(echo "$session_data" | jq -r '.sessionPath')
        local missing_chunks=$(echo "$session_data" | jq -r '.missingChunks[]')

        for chunk_num in $missing_chunks; do
            all_chunks+=("$session_path:$chunk_num")

            # Stop if we hit the limit
            if [ $BATCH_LIMIT -gt 0 ] && [ ${#all_chunks[@]} -ge $BATCH_LIMIT ]; then
                break 2
            fi
        done
    done < "$sessions_file"
    rm -f "$sessions_file"

    total_chunks=${#all_chunks[@]}
    log_info "Total chunks to process: $total_chunks"

    # Process chunks (batch or sequential)
    if [ $BATCH_SIZE -le 1 ]; then
        # Sequential processing (original behavior)
        log_info "Using SEQUENTIAL processing (BATCH_SIZE=1)"
        echo ""

        for chunk_info in "${all_chunks[@]}"; do
            local session_path="${chunk_info%:*}"
            local chunk_num="${chunk_info#*:}"
            local current_total=$((CHUNKS_TRANSCRIBED + CHUNKS_FAILED + 1))

            log_info "Processing chunk $chunk_num [$current_total/$total_chunks total]..."
            if transcribe_chunk "$session_path" "$chunk_num"; then
                CHUNKS_TRANSCRIBED=$((CHUNKS_TRANSCRIBED + 1))
                log_success "Chunk $chunk_num complete [$CHUNKS_TRANSCRIBED succeeded, $CHUNKS_FAILED failed]"
            else
                CHUNKS_FAILED=$((CHUNKS_FAILED + 1))
                log_warn "Chunk $chunk_num failed [$CHUNKS_TRANSCRIBED succeeded, $CHUNKS_FAILED failed]"
            fi
        done
    else
        # Batch processing (NEW optimization)
        log_info "Using BATCH processing (BATCH_SIZE=$BATCH_SIZE)"
        echo ""

        local batch_num=0
        for ((i=0; i<total_chunks; i+=BATCH_SIZE)); do
            batch_num=$((batch_num + 1))
            local batch_end=$((i + BATCH_SIZE))
            [ $batch_end -gt $total_chunks ] && batch_end=$total_chunks
            local batch_count=$((batch_end - i))

            log_info "Batch $batch_num: Processing chunks $((i+1))-$batch_end ($batch_count chunks)..."

            # Extract this batch's chunks
            local batch_chunks=("${all_chunks[@]:i:batch_count}")

            # Process the batch
            if transcribe_chunk_batch "${batch_chunks[@]}"; then
                CHUNKS_TRANSCRIBED=$((CHUNKS_TRANSCRIBED + batch_count))
                log_success "Batch $batch_num complete [$CHUNKS_TRANSCRIBED succeeded, $CHUNKS_FAILED failed]"
            else
                CHUNKS_FAILED=$((CHUNKS_FAILED + batch_count))
                log_warn "Batch $batch_num failed [$CHUNKS_TRANSCRIBED succeeded, $CHUNKS_FAILED failed]"
            fi
            echo ""
        done
    fi

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

transcribe_chunk_batch() {
    # Batch process multiple chunks at once (eliminates model reload overhead)
    # Args: Array of "session_path:chunk_num" strings
    local chunks=("$@")
    local batch_count=${#chunks[@]}
    local batch_id="batch-$$-$(date +%s)"
    local batch_dir_edge="/tmp/$batch_id"
    local batch_dir_gpu="/tmp/$batch_id"

    log_info "  Batch processing $batch_count chunks (pipelined I/O)..."

    # =============================================================================
    # PIPELINED BATCH PROCESSING APPROACH
    # =============================================================================
    # This function implements a hybrid pipeline that overlaps I/O operations with
    # GPU processing to minimize total execution time while preserving the critical
    # single-model-load optimization.
    #
    # Pipeline stages:
    #   1. S3 Download  (throttled, parallel)  - 30-40s for 100 chunks
    #   2. GPU Transfer (rsync, streaming)     - Starts as soon as downloads begin
    #   3. GPU Process  (single model load!)   - 180s for 100 chunks
    #   4. S3 Upload    (throttled, parallel)  - Overlapped with GPU processing
    #
    # Key optimization: Downloads start immediately and GPU transfer begins as soon
    # as the first batch of files (20-30) is ready. This eliminates the sequential
    # wait time while maintaining the single WhisperModel load benefit.
    #
    # Traditional sequential approach:
    #   Download ALL → Transfer ALL → Process ALL → Upload ALL = ~260s
    #
    # Pipelined approach:
    #   Download (parallel) → Transfer (streaming) → Process (single model)
    #        ↓ (overlap)           ↓ (overlap)
    #   Upload starts as GPU produces results
    #
    # Expected improvement: 20-30% reduction in total time for large batches
    # =============================================================================

    # Create batch directories
    mkdir -p "$batch_dir_edge"
    ssh -i "$SSH_KEY" "$SSH_USER@$GPU_IP" "mkdir -p '$batch_dir_gpu'" 2>/dev/null || true

    # =============================================================================
    # STAGE 1: PARALLEL S3 DOWNLOADS (Background, throttled at MAX_PARALLEL=20)
    # =============================================================================
    # Download audio files from S3 in parallel with throttling to prevent resource
    # exhaustion. Throttling at 20 concurrent downloads balances:
    #   - AWS S3 rate limits (5,500 req/s per prefix)
    #   - Network bandwidth
    #   - System resources (file descriptors, memory)
    #
    # Downloads run in background and continue while GPU transfer/processing starts
    # =============================================================================

    log_info "  Stage 1: Starting parallel S3 downloads (max $BATCH_MAX_PARALLEL_DOWNLOAD concurrent)..."
    local download_pids=()
    local chunk_index=0

    # Start all downloads in background (throttled)
    for chunk_info in "${chunks[@]}"; do
        local session_path="${chunk_info%:*}"
        local chunk_num="${chunk_info#*:}"
        local audio_s3="s3://$S3_BUCKET/$session_path/chunk-${chunk_num}.webm"
        local audio_file="$batch_dir_edge/chunk-${session_path//\//-}-${chunk_num}.webm"

        # Semaphore pattern: Wait if we have MAX_PARALLEL jobs running
        while [ $(jobs -r | wc -l) -ge $BATCH_MAX_PARALLEL_DOWNLOAD ]; do
            wait -n 2>/dev/null || true
        done

        # Download in background
        (
            if aws s3 cp "$audio_s3" "$audio_file" 2>/dev/null; then
                exit 0
            else
                log_error "  Failed to download: $audio_s3" >&2
                exit 1
            fi
        ) &

        download_pids+=($!)
        chunk_index=$((chunk_index + 1))
    done

    log_info "  Stage 1: $batch_count downloads started in background"

    # =============================================================================
    # STAGE 2: WAIT FOR INITIAL BATCH (Adaptive threshold)
    # =============================================================================
    # Wait for enough files to start GPU transfer. Threshold is adaptive:
    #   - Small batches (<30): Wait for all downloads (minimize transfer overhead)
    #   - Large batches (>=30): Wait for 30 files (start GPU processing sooner)
    #
    # This balances:
    #   - Transfer efficiency (rsync is faster with more files)
    #   - GPU utilization (start processing sooner on large batches)
    # =============================================================================

    local download_threshold=$BATCH_DOWNLOAD_THRESHOLD
    if [ $batch_count -lt 30 ]; then
        download_threshold=$batch_count
    else
        download_threshold=30
    fi

    log_info "  Stage 2: Waiting for $download_threshold files before GPU transfer..."

    local downloaded_count=0
    local wait_iterations=0
    local max_wait_iterations=$BATCH_DOWNLOAD_TIMEOUT  # 60 seconds max wait

    while [ $downloaded_count -lt $download_threshold ] && [ $wait_iterations -lt $max_wait_iterations ]; do
        sleep 1
        downloaded_count=$(ls -1 "$batch_dir_edge"/*.webm 2>/dev/null | wc -l || echo 0)
        wait_iterations=$((wait_iterations + 1))
    done

    if [ $downloaded_count -lt $download_threshold ]; then
        log_error "  Timeout waiting for initial downloads ($downloaded_count/$download_threshold after ${wait_iterations}s)"
        # Kill remaining download jobs
        for pid in "${download_pids[@]}"; do
            kill $pid 2>/dev/null || true
        done
        rm -rf "$batch_dir_edge"
        return 1
    fi

    log_success "  Stage 2: $downloaded_count files ready, starting GPU pipeline"

    # =============================================================================
    # STAGE 3: DEPLOY BATCH PROCESSOR TO GPU (One-time setup)
    # =============================================================================
    # Ensure the batch processor script exists on GPU. This script loads the
    # WhisperModel ONCE and processes all audio files sequentially, eliminating
    # the 5-8 second model load overhead per file.
    # =============================================================================

    ssh -i "$SSH_KEY" "$SSH_USER@$GPU_IP" "mkdir -p ~/batch-transcription" 2>/dev/null || true

    if ! ssh -i "$SSH_KEY" "$SSH_USER@$GPU_IP" "test -f ~/batch-transcription/batch-transcribe-audio-bulk.py" 2>/dev/null; then
        log_info "  Stage 3: Deploying batch processor to GPU..."
        if ! scp -i "$SSH_KEY" "$PROJECT_ROOT/scripts/batch-transcribe-audio-bulk.py" \
            "$SSH_USER@$GPU_IP:~/batch-transcription/" 2>/dev/null; then
            log_error "  Failed to deploy batch processor"
            rm -rf "$batch_dir_edge"
            ssh -i "$SSH_KEY" "$SSH_USER@$GPU_IP" "rm -rf '$batch_dir_gpu'" 2>/dev/null || true
            return 1
        fi
        log_success "  Stage 3: Batch processor deployed"
    fi

    # =============================================================================
    # STAGE 4: STREAMING GPU TRANSFER + PROCESSING (Pipelined)
    # =============================================================================
    # Start rsync in background to continuously transfer downloaded files to GPU.
    # As downloads complete, rsync picks them up automatically.
    #
    # Simultaneously start GPU processing. The GPU processor will:
    #   1. Load WhisperModel once (5-8s)
    #   2. Process all available .webm files
    #   3. Wait/retry if files are still being transferred
    #
    # This overlaps:
    #   - Ongoing S3 downloads
    #   - Rsync file transfers
    #   - GPU transcription processing
    # =============================================================================

    log_info "  Stage 4: Starting pipelined GPU transfer + processing..."

    # Start continuous rsync in background (updates as new files appear)
    (
        # Initial transfer of ready files
        rsync -az --partial -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no" \
            "$batch_dir_edge/" "$SSH_USER@$GPU_IP:$batch_dir_gpu/" 2>/dev/null

        # Continue syncing as downloads complete (check every 2s for 60s)
        for i in {1..30}; do
            sleep 2
            rsync -az --partial -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no" \
                "$batch_dir_edge/" "$SSH_USER@$GPU_IP:$batch_dir_gpu/" 2>/dev/null || true
        done
    ) &
    local rsync_pid=$!

    # Start GPU processing (runs in foreground, blocks until complete)
    log_info "  Stage 4: GPU processing started (single model load for all $batch_count chunks)"
    if ! ssh -i "$SSH_KEY" "$SSH_USER@$GPU_IP" \
        "cd ~/whisperlive/WhisperLive && source venv/bin/activate && \
         export LD_LIBRARY_PATH=\$PWD/venv/lib/python3.9/site-packages/nvidia/cudnn/lib:\$PWD/venv/lib/python3.9/site-packages/nvidia/cublas/lib:\$LD_LIBRARY_PATH && \
         python3 ~/batch-transcription/batch-transcribe-audio-bulk.py --input '$batch_dir_gpu' --output '$batch_dir_gpu' 2>&1"; then
        log_error "  Batch transcription failed on GPU"
        kill $rsync_pid 2>/dev/null || true
        rm -rf "$batch_dir_edge"
        ssh -i "$SSH_KEY" "$SSH_USER@$GPU_IP" "rm -rf '$batch_dir_gpu'" 2>/dev/null || true
        return 1
    fi

    # Kill rsync background process (GPU processing complete)
    kill $rsync_pid 2>/dev/null || true
    wait $rsync_pid 2>/dev/null || true

    log_success "  Stage 4: GPU processing complete"

    # =============================================================================
    # STAGE 5: WAIT FOR REMAINING DOWNLOADS (Ensure completeness)
    # =============================================================================
    # GPU processing is done, but some downloads may still be in progress.
    # Wait for all downloads to complete before checking success/failure counts.
    # =============================================================================

    log_info "  Stage 5: Waiting for remaining downloads to complete..."

    while [ $(jobs -r | wc -l) -gt 0 ]; do
        wait -n 2>/dev/null || true
    done

    # Verify all downloads succeeded
    local download_success=$(ls -1 "$batch_dir_edge"/*.webm 2>/dev/null | wc -l)
    local download_failed=$((batch_count - download_success))

    if [ $download_failed -gt 0 ]; then
        log_error "  $download_failed/$batch_count downloads failed"
        rm -rf "$batch_dir_edge"
        ssh -i "$SSH_KEY" "$SSH_USER@$GPU_IP" "rm -rf '$batch_dir_gpu'" 2>/dev/null || true
        return 1
    fi

    log_success "  Stage 5: All $batch_count downloads completed successfully"

    # =============================================================================
    # STAGE 6: RETRIEVE TRANSCRIPTIONS FROM GPU
    # =============================================================================
    # Pull completed transcription JSON files back from GPU to edge box.
    # Single rsync call is efficient for bulk transfer.
    # =============================================================================

    log_info "  Stage 6: Retrieving transcriptions from GPU..."
    if ! rsync -az -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no" \
                "$SSH_USER@$GPU_IP:$batch_dir_gpu/transcription-*.json" "$batch_dir_edge/" 2>/dev/null; then
        log_error "  Failed to retrieve transcriptions from GPU"
        rm -rf "$batch_dir_edge"
        ssh -i "$SSH_KEY" "$SSH_USER@$GPU_IP" "rm -rf '$batch_dir_gpu'" 2>/dev/null || true
        return 1
    fi

    log_success "  Stage 6: Retrieved transcriptions from GPU"

    # =============================================================================
    # STAGE 7: PARALLEL S3 UPLOADS (Throttled, background)
    # =============================================================================
    # Upload transcription results back to S3 in parallel, throttled at 20
    # concurrent uploads to match download throttling and respect AWS limits.
    # =============================================================================

    log_info "  Stage 7: Uploading $batch_count transcriptions to S3 (max 20 concurrent)..."
    # Using BATCH_MAX_PARALLEL_UPLOAD from .env
    local upload_success=0

    for chunk_info in "${chunks[@]}"; do
        local session_path="${chunk_info%:*}"
        local chunk_num="${chunk_info#*:}"
        local trans_s3="s3://$S3_BUCKET/$session_path/transcription-chunk-${chunk_num}.json"
        local trans_file="$batch_dir_edge/transcription-chunk-${session_path//\//-}-${chunk_num}.json"

        if [ ! -f "$trans_file" ]; then
            continue
        fi

        # Semaphore pattern: Wait if we have MAX_PARALLEL_UPLOAD jobs running
        while [ $(jobs -r | wc -l) -ge $BATCH_MAX_PARALLEL_UPLOAD ]; do
            wait -n 2>/dev/null || true
        done

        # Upload in background
        (
            if aws s3 cp "$trans_file" "$trans_s3" 2>/dev/null; then
                exit 0
            else
                log_error "  Failed to upload: $trans_s3" >&2
                exit 1
            fi
        ) &
    done

    # Wait for all uploads to complete
    while [ $(jobs -r | wc -l) -gt 0 ]; do
        wait -n 2>/dev/null || true
    done

    # Verify upload success
    upload_success=$(ls -1 "$batch_dir_edge"/transcription-*.json 2>/dev/null | wc -l)

    log_success "  Stage 7: Uploaded $upload_success transcriptions to S3"

    # Cleanup
    rm -rf "$batch_dir_edge"
    ssh -i "$SSH_KEY" "$SSH_USER@$GPU_IP" "rm -rf '$batch_dir_gpu'" 2>/dev/null || true

    log_success "  Batch complete: $batch_count chunks processed"
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
