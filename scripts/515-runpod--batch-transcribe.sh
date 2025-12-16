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
source "$PROJECT_ROOT/.env"
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

# Statistics
TIMESTAMP_START=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
CHUNKS_TRANSCRIBED=0
CHUNKS_FAILED=0
TOTAL_AUDIO_SECONDS=0

mkdir -p "$TEMP_DIR" "$REPORT_DIR"

# ============================================================================
# Cleanup
# ============================================================================

cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

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
    log_info "Scanning S3 for sessions missing transcription..."

    # List all audio sessions
    local sessions=$(aws s3 ls "s3://${S3_BUCKET}/users/" --recursive \
        | grep "metadata.json" \
        | awk '{print $4}' \
        | sed 's|/metadata.json||' \
        | sort -u)

    local missing_count=0
    local sessions_to_process=()

    while IFS= read -r session_path; do
        if [ -z "$session_path" ]; then
            continue
        fi

        # Check if transcription.json exists
        if ! aws s3 ls "s3://${S3_BUCKET}/${session_path}/transcription.json" &>/dev/null; then
            sessions_to_process+=("$session_path")
            missing_count=$((missing_count + 1))

            # Apply limit if set
            if [ "$BATCH_LIMIT" -gt 0 ] && [ "$missing_count" -ge "$BATCH_LIMIT" ]; then
                break
            fi
        fi
    done <<< "$sessions"

    log_info "Found $missing_count sessions missing transcription"
    printf '%s\n' "${sessions_to_process[@]}"
}

# ============================================================================
# Transcribe Single Session via RunPod API
# ============================================================================

transcribe_session() {
    local session_path="$1"
    local session_id=$(basename "$session_path")

    log_info "Processing session: $session_id"

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
        local result_s3_key="${session_path}/transcription.json"

        # GET URL for audio (using aws s3 presign)
        local audio_url=$(aws s3 presign "s3://${S3_BUCKET}/${audio_s3_key}" --expires-in "$PRESIGNED_URL_EXPIRY")

        # PUT URL for result (using boto3 - aws cli presign only does GET)
        local result_url=$(generate_put_url "$result_s3_key" "$PRESIGNED_URL_EXPIRY")

        if [ -z "$audio_url" ] || [ -z "$result_url" ]; then
            log_error "  Failed to generate presigned URLs"
            return 1
        fi

        log_info "  Sending to RunPod (presigned URL mode)..."

        local start_time=$(date +%s)

        # POST tiny JSON with URLs (bypasses proxy size/time limits)
        local response=$(curl -s --max-time 7200 \
            -X POST "${BASE_URL}/transcribe" \
            -H "Content-Type: application/json" \
            -d "{
                \"audio_url\": $(echo "$audio_url" | jq -Rs .),
                \"result_url\": $(echo "$result_url" | jq -Rs .),
                \"diarize\": ${ENABLE_DIARIZATION}
            }" \
            2>&1)

        local end_time=$(date +%s)
        local processing_time=$((end_time - start_time))

        # Check for success
        local status=$(echo "$response" | jq -r '.status // "error"' 2>/dev/null)

        if [ "$status" = "ok" ]; then
            local segment_count=$(echo "$response" | jq -r '.segments_count // 0')
            local speaker_count=$(echo "$response" | jq -r '.speakers_count // 0')
            local duration=$(echo "$response" | jq -r '.duration_seconds // 0')
            local proc_time=$(echo "$response" | jq -r '.processing_time_seconds // 0')

            log_success "  Transcription complete (presigned URL mode)"
            log_info "    Segments: $segment_count | Speakers: $speaker_count | Duration: ${duration}s | GPU time: ${proc_time}s"

            # Result already uploaded to S3 by RunPod - verify
            if aws s3 ls "s3://${S3_BUCKET}/${result_s3_key}" &>/dev/null; then
                log_success "  Result verified in S3"
            else
                log_warn "  Result not found in S3 - may still be uploading"
            fi

            # Update stats
            CHUNKS_TRANSCRIBED=$((CHUNKS_TRANSCRIBED + 1))
            TOTAL_AUDIO_SECONDS=$((TOTAL_AUDIO_SECONDS + estimated_seconds))

            return 0
        else
            log_error "  Transcription failed"
            echo "$response" | jq . 2>/dev/null || echo "$response"
            return 1
        fi
    else
        # ====================================================================
        # Priority 2: Download and merge chunks with ffmpeg
        # WebM is a container format - CANNOT be concatenated with 'cat'
        # ====================================================================
        log_info "  No pre-merged audio found, downloading chunks..."
        aws s3 sync "s3://${S3_BUCKET}/${session_path}/" "$audio_dir/" \
            --exclude "*" --include "chunk-*.webm" --include "chunk-*.wav" \
            --quiet

        # Find audio files
        local audio_files=($(find "$audio_dir" -name "chunk-*" -type f | sort -V))

        if [ ${#audio_files[@]} -eq 0 ]; then
            log_warn "  No audio chunks found, skipping"
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

    local start_time=$(date +%s)
    local response=$(curl -s --max-time 600 \
        -X POST "${BASE_URL}/transcribe/upload" \
        -F "file=@${audio_file}" \
        -F "diarize=${ENABLE_DIARIZATION}" \
        2>&1)
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
    echo "$response" | jq '.' > "$audio_dir/transcription.json"

    log_info "  Uploading transcription to S3..."
    aws s3 cp "$audio_dir/transcription.json" \
        "s3://${S3_BUCKET}/${session_path}/transcription.json" \
        --quiet

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
    "total_audio_seconds": $TOTAL_AUDIO_SECONDS,
    "diarization_enabled": $ENABLE_DIARIZATION,
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
    while IFS= read -r session_path; do
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
