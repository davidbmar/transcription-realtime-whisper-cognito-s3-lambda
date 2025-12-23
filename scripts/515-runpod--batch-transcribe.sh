#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Script 515-runpod: Run Batch Transcription via RunPod GPU
# ============================================================================
# Batch transcription using RunPod's WhisperX API with speaker diarization.
#
# PRESIGNED URL MODE (default for pre-merged audio.wav):
# 1. Generates presigned GET URL for audio.wav
# 2. Generates presigned PUT URL for transcription.json
# 3. POSTs tiny JSON with URLs to RunPod
# 4. RunPod downloads audio directly from S3 (bypasses proxy timeout)
# 5. RunPod uploads result directly to S3 (bypasses response size limits)
#
# LEGACY MODE (for sessions without pre-merged audio):
# 1. Downloads audio chunks from S3
# 2. Merges with ffmpeg locally
# 3. POSTs audio file to RunPod
# 4. Uploads result to S3
#
# Benefits of Presigned URL mode:
# - No 100s Cloudflare proxy timeout issues
# - Handles 4+ hour audio files
# - Faster (direct S3 transfer, not through proxy)
#
# Key difference from AWS version:
# - Uses HTTP API instead of SSH
# - Includes speaker diarization (WhisperX + pyannote)
# - Cheaper GPU ($0.13-0.20/hr vs $0.52/hr)
#
# Requirements:
# - .env variables: RUNPOD_HOST, RUNPOD_PORT, RUNPOD_API_KEY
# - RunPod pod running (use 850-runpod--start.sh first)
# - AWS credentials for S3 access
# ============================================================================

# Resolve script path (handles symlinks)
if [ -L "${BASH_SOURCE[0]}" ]; then
    SCRIPT_REAL=$(readlink -f "${BASH_SOURCE[0]}")
else
    SCRIPT_REAL="${BASH_SOURCE[0]}"
fi
PROJECT_ROOT="$(cd "$(dirname "$SCRIPT_REAL")/.." && pwd)"

# Load environment and common functions
set -a  # Auto-export all variables
source "$PROJECT_ROOT/.env"
set +a
source "$PROJECT_ROOT/scripts/lib/common-functions.sh"

echo "============================================"
echo "515-runpod: Batch Transcription via RunPod"
echo "============================================"
echo ""

# ============================================================================
# Configuration
# ============================================================================

S3_BUCKET="${COGNITO_S3_BUCKET:-}"
AWS_REGION="${AWS_REGION:-us-east-2}"
TEMP_DIR="/tmp/runpod-batch-$$"
REPORT_DIR="$PROJECT_ROOT/batch-reports"
REPORT_FILE="$REPORT_DIR/runpod-batch-$(date +%Y-%m-%d-%H%M).json"

# RunPod config
RUNPOD_HOST="${RUNPOD_HOST:-}"
RUNPOD_PORT="${RUNPOD_PORT:-443}"
RUNPOD_HTTPS="${RUNPOD_HTTPS:-true}"

# Build base URL
if [ "$RUNPOD_HTTPS" = "true" ]; then
    BASE_URL="https://${RUNPOD_HOST}"
else
    BASE_URL="http://${RUNPOD_HOST}:${RUNPOD_PORT}"
fi

# Processing config
BATCH_LIMIT="${BATCH_LIMIT:-0}"           # 0 = no limit
ENABLE_DIARIZATION="${ENABLE_DIARIZATION:-true}"
PRESIGNED_URL_EXPIRY="${PRESIGNED_URL_EXPIRY:-7200}"  # 2 hours default (generous for long audio)

# Diarization speaker count hints (improves accuracy when known)
# Set via env vars or command line: MIN_SPEAKERS=3 MAX_SPEAKERS=5 ./scripts/515-runpod--batch-transcribe.sh
MIN_SPEAKERS="${MIN_SPEAKERS:-}"          # Minimum expected speakers (empty = auto)
MAX_SPEAKERS="${MAX_SPEAKERS:-}"          # Maximum expected speakers (empty = auto)

# Async polling config
POLL_INTERVAL="${POLL_INTERVAL:-30}"      # Poll every 30 seconds
MAX_POLL_TIME="${MAX_POLL_TIME:-3600}"    # Max 1 hour per transcription

# Statistics
TIMESTAMP_START=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
CHUNKS_TRANSCRIBED=0
CHUNKS_FAILED=0
TOTAL_AUDIO_SECONDS=0
SPEAKERS_IDENTIFIED=0

# Speaker identification config
ENABLE_SPEAKER_ID="${ENABLE_SPEAKER_ID:-true}"
SPEAKER_ID_SCRIPT="$PROJECT_ROOT/scripts/561-identify-speakers-llm.py"

mkdir -p "$TEMP_DIR" "$REPORT_DIR"

# ============================================================================
# Cleanup
# ============================================================================

cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# ============================================================================
# Speaker Identification (Step 3: After Diarization)
# ============================================================================
# Pipeline: 1) Transcription -> 2) Diarization -> 3) Speaker Identification
#
# Uses Claude LLM to identify speakers from context clues like:
# - Self-identification ("this is Tim speaking")
# - Cross-references ("as Ryan mentioned")
# - Response patterns
#
# Adds 'speaker_names' field to transcript that UI reads to display real names.

identify_speakers() {
    local transcript_s3_path="$1"

    if [ "$ENABLE_SPEAKER_ID" != "true" ]; then
        log_info "  Speaker identification disabled"
        return 0
    fi

    if [ ! -f "$SPEAKER_ID_SCRIPT" ]; then
        log_warn "  Speaker ID script not found: $SPEAKER_ID_SCRIPT"
        return 0
    fi

    if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
        log_warn "  ANTHROPIC_API_KEY not set, skipping speaker identification"
        return 0
    fi

    log_info "  Identifying speakers with Claude..."

    # Run the LLM script to identify speakers and update the transcript
    if python3 "$SPEAKER_ID_SCRIPT" "$transcript_s3_path" --update 2>&1 | while read line; do
        echo "    $line"
    done; then
        SPEAKERS_IDENTIFIED=$((SPEAKERS_IDENTIFIED + 1))
        log_success "  Speaker identification complete"
        return 0
    else
        log_warn "  Speaker identification failed (non-critical)"
        return 0  # Don't fail the whole transcription
    fi
}

# ============================================================================
# Merge Speaker Turns (Step 4: After Speaker Identification)
# ============================================================================
# Consolidates consecutive segments from the same speaker into paragraphs.
# Makes transcripts more readable by grouping speech turns.

MERGE_TURNS_SCRIPT="$PROJECT_ROOT/scripts/562-merge-speaker-turns.py"
ENABLE_MERGE_TURNS="${ENABLE_MERGE_TURNS:-true}"

merge_speaker_turns() {
    local transcript_s3_path="$1"

    if [ "$ENABLE_MERGE_TURNS" != "true" ]; then
        log_info "  Speaker turn merging disabled"
        return 0
    fi

    if [ ! -f "$MERGE_TURNS_SCRIPT" ]; then
        log_warn "  Merge turns script not found: $MERGE_TURNS_SCRIPT"
        return 0
    fi

    log_info "  Merging consecutive speaker turns..."

    if python3 "$MERGE_TURNS_SCRIPT" "$transcript_s3_path" --update 2>&1 | while read line; do
        echo "    $line"
    done; then
        log_success "  Speaker turn merging complete"
        return 0
    else
        log_warn "  Speaker turn merging failed (non-critical)"
        return 0
    fi
}

# ============================================================================
# Topic Segmentation (Step 5: After Speaker Turn Merging)
# ============================================================================
# Uses semantic embeddings to detect topic changes in the transcript.
# Adds topic boundaries for better navigation and readability.

TOPIC_SEGMENT_SCRIPT="$PROJECT_ROOT/scripts/524-segment-transcripts-by-topic.py"
ENABLE_TOPIC_SEGMENTATION="${ENABLE_TOPIC_SEGMENTATION:-true}"

segment_by_topic() {
    local session_path="$1"

    if [ "$ENABLE_TOPIC_SEGMENTATION" != "true" ]; then
        log_info "  Topic segmentation disabled"
        return 0
    fi

    if [ ! -f "$TOPIC_SEGMENT_SCRIPT" ]; then
        log_warn "  Topic segmentation script not found: $TOPIC_SEGMENT_SCRIPT"
        return 0
    fi

    log_info "  Detecting topic boundaries..."

    if python3 "$TOPIC_SEGMENT_SCRIPT" --session "$session_path" 2>&1 | while read line; do
        echo "    $line"
    done; then
        log_success "  Topic segmentation complete"
        return 0
    else
        log_warn "  Topic segmentation failed (non-critical)"
        return 0
    fi
}

# ============================================================================
# Presigned URL Generation
# ============================================================================

# Generate presigned PUT URL for uploading result to S3
generate_put_url() {
    local s3_key="$1"
    local expiry="${2:-$PRESIGNED_URL_EXPIRY}"

    python3 << PYTHON
import boto3
s3 = boto3.client('s3', region_name='${AWS_REGION}')
url = s3.generate_presigned_url(
    'put_object',
    Params={
        'Bucket': '${S3_BUCKET}',
        'Key': '${s3_key}',
        'ContentType': 'application/json'
    },
    ExpiresIn=${expiry}
)
print(url)
PYTHON
}

# ============================================================================
# Async Job Polling
# ============================================================================

# Poll job status until complete or failed
# Returns 0 on success, 1 on failure
poll_job_status() {
    local job_id="$1"
    local start_time=$(date +%s)
    local poll_count=0

    log_info "    Polling job $job_id..."

    while true; do
        sleep "$POLL_INTERVAL"
        poll_count=$((poll_count + 1))

        local elapsed=$(($(date +%s) - start_time))

        # Check for timeout
        if [ "$elapsed" -gt "$MAX_POLL_TIME" ]; then
            log_error "    Job timed out after ${elapsed}s"
            return 1
        fi

        # Query job status
        local status_response=$(curl -s --max-time 15 "${BASE_URL}/status/${job_id}" 2>/dev/null)

        if [ -z "$status_response" ]; then
            log_warn "    [${poll_count}] No response from status endpoint"
            continue
        fi

        local status=$(echo "$status_response" | jq -r '.status // "unknown"' 2>/dev/null)
        local progress=$(echo "$status_response" | jq -r '.progress // 0' 2>/dev/null)
        local message=$(echo "$status_response" | jq -r '.message // ""' 2>/dev/null)

        log_info "    [${poll_count}] Status: $status (${progress}%) - $message"

        case "$status" in
            "completed")
                # Extract result info
                local segment_count=$(echo "$status_response" | jq -r '.segments_count // 0')
                local speaker_count=$(echo "$status_response" | jq -r '.speakers_count // 0')
                local duration=$(echo "$status_response" | jq -r '.duration_seconds // 0')
                local proc_time=$(echo "$status_response" | jq -r '.processing_time_seconds // 0')

                log_success "    Job completed in ${elapsed}s"
                log_info "    Segments: $segment_count | Speakers: $speaker_count | Duration: ${duration}s | GPU time: ${proc_time}s"

                # Set global vars for stats
                JOB_SEGMENTS=$segment_count
                JOB_SPEAKERS=$speaker_count
                JOB_DURATION=$duration
                JOB_PROC_TIME=$proc_time

                return 0
                ;;
            "failed")
                local error=$(echo "$status_response" | jq -r '.error // "unknown error"')
                log_error "    Job failed: $error"
                return 1
                ;;
            "queued"|"downloading"|"processing"|"uploading")
                # Still running, continue polling
                ;;
            *)
                log_warn "    Unknown status: $status"
                ;;
        esac
    done
}

# ============================================================================
# Validate Prerequisites
# ============================================================================

validate_runpod() {
    log_info "Validating RunPod configuration..."

    if [ -z "$RUNPOD_HOST" ]; then
        log_error "RUNPOD_HOST not set in .env"
        echo ""
        echo "Start a RunPod pod first:"
        echo "  ./scripts/850-runpod--start.sh"
        return 1
    fi

    # Health check
    log_info "Checking RunPod health at $BASE_URL..."

    local health_response=$(curl -s --max-time 30 "${BASE_URL}/health" 2>/dev/null || echo '{"error": "connection failed"}')

    if echo "$health_response" | jq -e '.status' &>/dev/null; then
        local status=$(echo "$health_response" | jq -r '.status')
        local device=$(echo "$health_response" | jq -r '.device // "unknown"')
        local model=$(echo "$health_response" | jq -r '.model // "unknown"')

        log_success "RunPod is ready"
        log_info "  Status: $status | Device: $device | Model: $model"
        return 0
    else
        log_error "RunPod health check failed"
        echo "Response: $health_response"
        echo ""
        echo "Check pod status: ./scripts/851-runpod--status.sh"
        return 1
    fi
}

# ============================================================================
# Find Missing Transcriptions
# ============================================================================

find_missing_transcriptions() {
    # NOTE: All log output goes to stderr since stdout is captured by caller
    log_info "Scanning S3 for sessions missing transcription..." >&2
    log_info "  S3 bucket: ${S3_BUCKET}" >&2

    # List all audio sessions
    local sessions=$(aws s3 ls "s3://${S3_BUCKET}/users/" --recursive \
        | grep "metadata.json" \
        | awk '{print $4}' \
        | sed 's|/metadata.json||' \
        | sort -u)

    local total_sessions=$(echo "$sessions" | grep -c . || echo "0")
    log_info "  Found $total_sessions sessions with metadata.json" >&2

    local missing_count=0
    local sessions_to_process=()

    while IFS= read -r session_path; do
        if [ -z "$session_path" ]; then
            continue
        fi

        # Check if diarized transcription already exists (check both filenames)
        if aws s3 ls "s3://${S3_BUCKET}/${session_path}/transcription-diarized.json" &>/dev/null; then
            log_info "  [SKIPPED] $session_path (has transcription-diarized.json)" >&2
        elif aws s3 ls "s3://${S3_BUCKET}/${session_path}/transcription.json" &>/dev/null; then
            log_info "  [SKIPPED] $session_path (has transcription.json)" >&2
        else
            sessions_to_process+=("$session_path")
            missing_count=$((missing_count + 1))
            log_info "  [MISSING] $session_path" >&2

            # Apply limit if set
            if [ "$BATCH_LIMIT" -gt 0 ] && [ "$missing_count" -ge "$BATCH_LIMIT" ]; then
                log_info "  Limit reached ($BATCH_LIMIT)" >&2
                break
            fi
        fi
    done <<< "$sessions"

    log_info "Found $missing_count sessions missing transcription" >&2
    # Output only session paths to stdout (one per line)
    printf '%s\n' "${sessions_to_process[@]}"
}

# ============================================================================
# Transcribe Single Session via RunPod API
# ============================================================================

transcribe_session() {
    local session_path="$1"
    local session_id=$(basename "$session_path")

    log_info "Processing session: $session_id"

    # Check for session-specific speaker hints in metadata.json
    # These are set by the re-diarization UI feature
    local session_min_speakers="${MIN_SPEAKERS:-}"
    local session_max_speakers="${MAX_SPEAKERS:-}"

    local metadata_key="${session_path}/metadata.json"
    local metadata_json=$(aws s3 cp "s3://${S3_BUCKET}/${metadata_key}" - 2>/dev/null || echo "{}")

    if [ -n "$metadata_json" ] && [ "$metadata_json" != "{}" ]; then
        local meta_min=$(echo "$metadata_json" | jq -r '.diarization.minSpeakers // empty' 2>/dev/null)
        local meta_max=$(echo "$metadata_json" | jq -r '.diarization.maxSpeakers // empty' 2>/dev/null)

        if [ -n "$meta_min" ] && [ "$meta_min" != "null" ]; then
            session_min_speakers="$meta_min"
            log_info "  Using metadata speaker hint: minSpeakers=$meta_min"
        fi
        if [ -n "$meta_max" ] && [ "$meta_max" != "null" ]; then
            session_max_speakers="$meta_max"
            log_info "  Using metadata speaker hint: maxSpeakers=$meta_max"
        fi
    fi

    local audio_dir="$TEMP_DIR/$session_id"
    mkdir -p "$audio_dir"

    local audio_file=""
    local estimated_seconds=0
    local use_presigned_urls=false

    # ========================================================================
    # Priority 1: Check for pre-merged audio.wav (from 516-merge-chunks-worker)
    # This is the optimal path - single file with all audio for best diarization
    # Uses PRESIGNED URLs to bypass Cloudflare proxy timeout
    # ========================================================================
    if aws s3 ls "s3://${S3_BUCKET}/${session_path}/audio.wav" &>/dev/null; then
        log_info "  Found pre-merged audio.wav - using PRESIGNED URL mode"

        # Get file size from S3 to estimate duration
        local file_info=$(aws s3 ls "s3://${S3_BUCKET}/${session_path}/audio.wav" | head -1)
        local file_size=$(echo "$file_info" | awk '{print $3}')
        estimated_seconds=$((file_size / 32000))  # 16kHz, 16-bit = 32000 bytes/sec
        log_info "  Audio: ~$((file_size / 1024 / 1024))MB (~${estimated_seconds}s / ~$((estimated_seconds / 60))min)"

        # Generate presigned URLs
        log_info "  Generating presigned URLs (${PRESIGNED_URL_EXPIRY}s expiry)..."

        local audio_s3_key="${session_path}/audio.wav"
        local result_s3_key="${session_path}/transcription-diarized.json"

        # GET URL for audio (using aws s3 presign)
        local audio_url=$(aws s3 presign "s3://${S3_BUCKET}/${audio_s3_key}" --expires-in "$PRESIGNED_URL_EXPIRY")

        # PUT URL for result (using boto3 - aws cli presign only does GET)
        local result_url=$(generate_put_url "$result_s3_key" "$PRESIGNED_URL_EXPIRY")

        if [ -z "$audio_url" ] || [ -z "$result_url" ]; then
            log_error "  Failed to generate presigned URLs"
            return 1
        fi

        log_info "  Submitting job to RunPod (async mode)..."

        # Build JSON payload with optional speaker count hints
        # Use session-specific hints from metadata.json if available, otherwise global env vars
        local json_payload=$(jq -n \
            --arg audio_url "$audio_url" \
            --arg result_url "$result_url" \
            --argjson diarize "$ENABLE_DIARIZATION" \
            --argjson async true \
            --argjson min_speakers "${session_min_speakers:-null}" \
            --argjson max_speakers "${session_max_speakers:-null}" \
            '{
                audio_url: $audio_url,
                result_url: $result_url,
                diarize: $diarize,
                async_mode: $async
            } + (if $min_speakers then {min_speakers: $min_speakers} else {} end)
              + (if $max_speakers then {max_speakers: $max_speakers} else {} end)'
        )

        if [ -n "$session_min_speakers" ] || [ -n "$session_max_speakers" ]; then
            log_info "  Speaker hints: min=${session_min_speakers:-auto} max=${session_max_speakers:-auto}"
        fi

        # POST tiny JSON with URLs - returns job_id immediately
        local submit_response=$(curl -s --max-time 30 \
            -X POST "${BASE_URL}/transcribe" \
            -H "Content-Type: application/json" \
            -d "$json_payload" \
            2>&1)

        # Extract job_id
        local job_id=$(echo "$submit_response" | jq -r '.job_id // empty' 2>/dev/null)

        if [ -z "$job_id" ]; then
            log_error "  Failed to submit job"
            echo "$submit_response" | jq . 2>/dev/null || echo "$submit_response"
            return 1
        fi

        log_info "  Job submitted: $job_id"

        # Poll for completion (handles Cloudflare timeout by using short polling requests)
        if poll_job_status "$job_id"; then
            # Result already uploaded to S3 by RunPod - verify
            if aws s3 ls "s3://${S3_BUCKET}/${result_s3_key}" &>/dev/null; then
                log_success "  Result verified in S3"
            else
                log_warn "  Result not found in S3 - may still be uploading"
                sleep 5
                if aws s3 ls "s3://${S3_BUCKET}/${result_s3_key}" &>/dev/null; then
                    log_success "  Result now in S3"
                fi
            fi

            # Step 3: Speaker Identification (after diarization)
            identify_speakers "s3://${S3_BUCKET}/${result_s3_key}"

            # Step 4: Merge consecutive speaker turns into paragraphs
            merge_speaker_turns "s3://${S3_BUCKET}/${result_s3_key}"

            # Step 5: Topic segmentation (detect topic boundaries)
            segment_by_topic "${session_path}"

            # Update stats
            CHUNKS_TRANSCRIBED=$((CHUNKS_TRANSCRIBED + 1))
            TOTAL_AUDIO_SECONDS=$((TOTAL_AUDIO_SECONDS + estimated_seconds))

            return 0
        else
            log_error "  Transcription job failed"
            return 1
        fi
    else
        # ====================================================================
        # Priority 2: Download and merge chunks with ffmpeg
        # WebM is a container format - CANNOT be concatenated with 'cat'
        # ====================================================================
        log_info "  No pre-merged audio found, downloading chunks..."
        log_info "  S3 path: s3://${S3_BUCKET}/${session_path}/"
        log_info "  Local dir: $audio_dir"

        # Show what files exist in S3
        log_info "  Files in S3:"
        aws s3 ls "s3://${S3_BUCKET}/${session_path}/" 2>&1 | while read line; do
            log_info "    $line"
        done

        aws s3 sync "s3://${S3_BUCKET}/${session_path}/" "$audio_dir/" \
            --exclude "*" --include "chunk-*.webm" --include "chunk-*.wav" --include "chunk-*.m4a" --include "chunk-*.mp3" --include "chunk-*.mp4" \
            2>&1 | while read line; do log_info "    sync: $line"; done

        # Find audio files
        log_info "  Local files after sync:"
        ls -la "$audio_dir/" 2>&1 | while read line; do log_info "    $line"; done

        local audio_files=($(find "$audio_dir" -name "chunk-*" -type f | sort -V))

        if [ ${#audio_files[@]} -eq 0 ]; then
            log_warn "  No audio chunks found, skipping"
            log_warn "  Expected: chunk-*.webm, chunk-*.wav, chunk-*.m4a, chunk-*.mp3, or chunk-*.mp4"
            return 1
        fi

        log_info "  Found ${#audio_files[@]} audio chunks"

        if [ ${#audio_files[@]} -eq 1 ]; then
            # Single chunk - use directly
            audio_file="${audio_files[0]}"
            local file_size=$(stat -c%s "$audio_file" 2>/dev/null || stat -f%z "$audio_file" 2>/dev/null || echo "0")
            estimated_seconds=$((file_size / 16000))
        else
            # Multiple chunks - MUST use ffmpeg (not cat!) for proper merging
            log_info "  Merging chunks with ffmpeg (webm requires proper concatenation)..."

            # Check for ffmpeg
            if ! command -v ffmpeg &>/dev/null; then
                log_error "  ffmpeg not installed - required for merging webm chunks"
                log_info "  Tip: Run ./scripts/516-merge-chunks-worker.sh first to pre-merge audio"
                return 1
            fi

            # Create ffmpeg concat file
            local concat_file="$audio_dir/concat.txt"
            for chunk in "${audio_files[@]}"; do
                echo "file '$chunk'" >> "$concat_file"
            done

            # Merge to WAV (16kHz mono - optimal for transcription)
            local combined_audio="$audio_dir/combined.wav"
            if ! ffmpeg -y -f concat -safe 0 -i "$concat_file" \
                -ar 16000 -ac 1 -c:a pcm_s16le \
                "$combined_audio" \
                -loglevel warning 2>&1; then
                log_error "  ffmpeg merge failed"
                return 1
            fi

            audio_file="$combined_audio"
            local file_size=$(stat -c%s "$audio_file" 2>/dev/null || stat -f%z "$audio_file" 2>/dev/null || echo "0")
            estimated_seconds=$((file_size / 32000))
            log_info "  Merged audio: ~${estimated_seconds}s"
        fi
    fi

    # POST to RunPod WhisperX API
    log_info "  Sending to RunPod for transcription..."

    if [ -n "$session_min_speakers" ] || [ -n "$session_max_speakers" ]; then
        log_info "  Speaker hints: min=${session_min_speakers:-auto} max=${session_max_speakers:-auto}"
    fi

    local start_time=$(date +%s)
    local curl_args=("-s" "--max-time" "600" "-X" "POST" "${BASE_URL}/transcribe/upload"
        "-F" "file=@${audio_file}"
        "-F" "diarize=${ENABLE_DIARIZATION}")

    # Add optional speaker count hints (from session metadata or global env vars)
    [ -n "$session_min_speakers" ] && curl_args+=("-F" "min_speakers=${session_min_speakers}")
    [ -n "$session_max_speakers" ] && curl_args+=("-F" "max_speakers=${session_max_speakers}")

    local response=$(curl "${curl_args[@]}" 2>&1)
    local end_time=$(date +%s)
    local processing_time=$((end_time - start_time))

    # Check for error
    if echo "$response" | jq -e '.error' &>/dev/null; then
        log_error "  Transcription failed"
        echo "$response" | jq .
        return 1
    fi

    # Validate response has segments
    if ! echo "$response" | jq -e '.segments' &>/dev/null; then
        log_error "  Invalid response (no segments)"
        echo "$response" | head -200
        return 1
    fi

    local segment_count=$(echo "$response" | jq '.segments | length')
    local speaker_count=$(echo "$response" | jq '.speakers // [] | length')

    log_success "  Transcription complete: $segment_count segments, $speaker_count speakers, ${processing_time}s"

    # Save transcription to S3
    echo "$response" | jq '.' > "$audio_dir/transcription-diarized.json"

    log_info "  Uploading transcription to S3..."
    local result_s3_path="s3://${S3_BUCKET}/${session_path}/transcription-diarized.json"
    aws s3 cp "$audio_dir/transcription-diarized.json" "$result_s3_path" --quiet

    # Step 3: Speaker Identification (after diarization)
    identify_speakers "$result_s3_path"

    # Step 4: Merge consecutive speaker turns into paragraphs
    merge_speaker_turns "$result_s3_path"

    # Step 5: Topic segmentation (detect topic boundaries)
    segment_by_topic "${session_path}"

    # Update stats
    CHUNKS_TRANSCRIBED=$((CHUNKS_TRANSCRIBED + 1))
    TOTAL_AUDIO_SECONDS=$((TOTAL_AUDIO_SECONDS + estimated_seconds))

    # Cleanup
    rm -rf "$audio_dir"

    return 0
}

# ============================================================================
# Generate Report
# ============================================================================

generate_report() {
    local timestamp_end=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    cat > "$REPORT_FILE" <<EOF
{
    "type": "runpod-batch-transcription",
    "timestamp_start": "$TIMESTAMP_START",
    "timestamp_end": "$timestamp_end",
    "provider": "runpod",
    "gpu": "${RUNPOD_GPU_SELECTED:-unknown}",
    "sessions_transcribed": $CHUNKS_TRANSCRIBED,
    "sessions_failed": $CHUNKS_FAILED,
    "speakers_identified": $SPEAKERS_IDENTIFIED,
    "total_audio_seconds": $TOTAL_AUDIO_SECONDS,
    "diarization_enabled": $ENABLE_DIARIZATION,
    "speaker_id_enabled": $ENABLE_SPEAKER_ID,
    "endpoint": "$BASE_URL"
}
EOF

    log_success "Report saved: $REPORT_FILE"
}

# ============================================================================
# Main
# ============================================================================

main() {
    log_info "Starting RunPod batch transcription..."
    echo ""

    # Validate S3 bucket
    if [ -z "$S3_BUCKET" ]; then
        log_error "COGNITO_S3_BUCKET not set in .env"
        exit 1
    fi

    # Validate RunPod
    if ! validate_runpod; then
        exit 1
    fi
    echo ""

    # Find missing transcriptions
    local missing_sessions
    missing_sessions=$(find_missing_transcriptions)

    if [ -z "$missing_sessions" ]; then
        log_success "No sessions need transcription!"
        echo ""
        echo "All sessions are up to date."
        exit 0
    fi

    local session_count=$(echo "$missing_sessions" | wc -l | tr -d ' ')
    log_info "Processing $session_count sessions..."
    echo ""

    # Process each session
    # Note: The `|| [[ -n "$session_path" ]]` ensures the last line is processed
    # even if the input doesn't end with a newline (bash read quirk)
    while IFS= read -r session_path || [[ -n "$session_path" ]]; do
        if [ -z "$session_path" ]; then
            continue
        fi

        if transcribe_session "$session_path"; then
            log_success "Session complete"
        else
            CHUNKS_FAILED=$((CHUNKS_FAILED + 1))
            log_error "Session failed"
        fi
        echo ""
    done <<< "$missing_sessions"

    # Generate report
    generate_report

    # Run postprocessing to convert segments → paragraphs format
    # This creates transcription-processed.json files for fast editor loading
    if [ "$CHUNKS_TRANSCRIBED" -gt 0 ]; then
        echo ""
        log_info "Running postprocessing to create editor-ready files..."
        if [ -f "$PROJECT_ROOT/scripts/518-postprocess-transcripts.sh" ]; then
            "$PROJECT_ROOT/scripts/518-postprocess-transcripts.sh" || {
                log_warn "Postprocessing had errors (transcription still complete)"
            }
        else
            log_warn "Postprocessing script not found: 518-postprocess-transcripts.sh"
        fi
    fi

    # Summary
    echo ""
    echo "============================================"
    echo "Batch Transcription Complete"
    echo "============================================"
    echo ""
    echo "  Sessions transcribed: $CHUNKS_TRANSCRIBED"
    echo "  Sessions failed:      $CHUNKS_FAILED"
    echo "  Total audio:          ~$((TOTAL_AUDIO_SECONDS / 60)) minutes"
    echo "  Diarization:          $ENABLE_DIARIZATION"
    echo ""
    echo "  Report: $REPORT_FILE"
    echo ""

    if [ "$CHUNKS_FAILED" -gt 0 ]; then
        log_warn "Some sessions failed. Check logs for details."
        exit 1
    fi
}

main "$@"
