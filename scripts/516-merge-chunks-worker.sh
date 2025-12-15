#!/bin/bash
set -euo pipefail

# Create logs directory if it doesn't exist
mkdir -p "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/logs"
exec > >(tee -a "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Script 516: Merge Audio Chunks Worker
# ============================================================================
# Pre-merges audio chunks on Edge Box (CPU) before RunPod GPU transcription.
# This ensures WhisperX sees the full audio for correct speaker diarization.
#
# Why this is needed:
# - Recording creates 2-min chunks (webm format)
# - WebM is a container format that CANNOT be concatenated with 'cat'
# - Per-chunk diarization produces inconsistent speaker IDs
# - Solution: Merge chunks BEFORE sending to RunPod
#
# What this does:
# 1. Scans S3 for sessions with chunk-XXX.webm files
# 2. Checks if merged audio (audio.wav) already exists
# 3. Downloads chunks to temp directory
# 4. Uses ffmpeg to concatenate into single WAV (16kHz mono)
# 5. Uploads merged audio.wav to S3
# 6. Optionally deletes original chunks (--delete-chunks)
#
# Requirements:
# - Runs on Edge Box (requires ffmpeg, no GPU needed)
# - AWS credentials for S3 access
# - .env with COGNITO_S3_BUCKET set
#
# Usage:
#   ./scripts/516-merge-chunks-worker.sh                    # Process all pending
#   ./scripts/516-merge-chunks-worker.sh --session X        # Process specific session
#   ./scripts/516-merge-chunks-worker.sh --dry-run          # Show what would be done
#   ./scripts/516-merge-chunks-worker.sh --delete-chunks    # Remove chunks after merge
#   ./scripts/516-merge-chunks-worker.sh --force            # Re-merge even if audio.wav exists
#   ./scripts/516-merge-chunks-worker.sh --limit N          # Process only N sessions
#
# Output:
#   s3://bucket/users/X/audio/sessions/Y/audio.wav  (merged file)
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
echo "516: Merge Audio Chunks Worker"
echo "============================================"
echo ""

# ============================================================================
# Configuration
# ============================================================================

S3_BUCKET="${COGNITO_S3_BUCKET:-}"
AWS_REGION="${AWS_REGION:-us-east-2}"
TEMP_DIR="/tmp/merge-chunks-$$"
REPORT_DIR="$PROJECT_ROOT/batch-reports"
REPORT_FILE="$REPORT_DIR/merge-chunks-$(date +%Y-%m-%d-%H%M).json"

# Processing options
DRY_RUN=false
DELETE_CHUNKS=false
FORCE_MERGE=false
SESSION_FILTER=""
LIMIT=0

# Statistics
TIMESTAMP_START=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
SESSIONS_MERGED=0
SESSIONS_SKIPPED=0
SESSIONS_FAILED=0
TOTAL_CHUNKS_PROCESSED=0
TOTAL_AUDIO_SECONDS=0

# ============================================================================
# Parse Arguments
# ============================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --session)
            SESSION_FILTER="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --delete-chunks)
            DELETE_CHUNKS=true
            shift
            ;;
        --force)
            FORCE_MERGE=true
            shift
            ;;
        --limit)
            LIMIT="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --session PATH    Process specific session path"
            echo "  --dry-run         Show what would be done without making changes"
            echo "  --delete-chunks   Delete original chunks after successful merge"
            echo "  --force           Re-merge even if audio.wav already exists"
            echo "  --limit N         Process only N sessions"
            echo "  -h, --help        Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0                                    # Process all pending sessions"
            echo "  $0 --dry-run                          # Preview what would be merged"
            echo "  $0 --session users/abc/audio/sessions/session_2025-12-15..."
            echo "  $0 --delete-chunks --limit 10         # Merge 10 sessions, delete chunks"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Create directories
mkdir -p "$TEMP_DIR" "$REPORT_DIR"

# ============================================================================
# Cleanup
# ============================================================================

cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# ============================================================================
# Validate Prerequisites
# ============================================================================

validate_prerequisites() {
    log_info "Validating prerequisites..."

    # Check S3 bucket
    if [ -z "$S3_BUCKET" ]; then
        log_error "COGNITO_S3_BUCKET not set in .env"
        exit 1
    fi

    # Check ffmpeg
    if ! command -v ffmpeg &>/dev/null; then
        log_error "ffmpeg not installed. Install with: sudo apt-get install ffmpeg"
        exit 1
    fi

    # Check AWS CLI
    if ! command -v aws &>/dev/null; then
        log_error "AWS CLI not installed"
        exit 1
    fi

    # Verify S3 access
    if ! aws s3 ls "s3://$S3_BUCKET" &>/dev/null; then
        log_error "Cannot access S3 bucket: $S3_BUCKET"
        exit 1
    fi

    log_success "Prerequisites validated"
    echo ""
}

# ============================================================================
# Find Sessions Needing Merge
# ============================================================================

find_sessions_needing_merge() {
    # Log to stderr so it doesn't mix with session path output
    log_info "Scanning S3 for sessions needing merge..." >&2

    local sessions_to_process=()
    local scan_count=0

    # If specific session provided, use that
    if [ -n "$SESSION_FILTER" ]; then
        # Verify session exists
        if aws s3 ls "s3://$S3_BUCKET/$SESSION_FILTER/" &>/dev/null; then
            sessions_to_process+=("$SESSION_FILTER")
        else
            log_error "Session not found: $SESSION_FILTER" >&2
            return 1
        fi
    else
        # Scan for all sessions with audio chunks
        # Look for metadata.json files which indicate valid sessions
        local sessions=$(aws s3 ls "s3://${S3_BUCKET}/users/" --recursive \
            | grep "audio/sessions/.*/metadata.json" \
            | awk '{print $4}' \
            | sed 's|/metadata.json||' \
            | sort -u)

        while IFS= read -r session_path; do
            if [ -z "$session_path" ]; then
                continue
            fi

            scan_count=$((scan_count + 1))

            # Check if session has audio chunks
            # Use head -1 and tr to ensure we get a single integer
            local chunk_count=$(aws s3 ls "s3://$S3_BUCKET/$session_path/" 2>/dev/null \
                | grep -c "chunk-.*\.webm" 2>/dev/null || echo "0")
            chunk_count=$(echo "$chunk_count" | tr -d '\n' | head -c 10)
            chunk_count=${chunk_count:-0}

            if [ "$chunk_count" -eq 0 ] 2>/dev/null; then
                continue
            fi

            # Check if audio.wav already exists (skip unless --force)
            if [ "$FORCE_MERGE" = "false" ]; then
                if aws s3 ls "s3://$S3_BUCKET/$session_path/audio.wav" &>/dev/null; then
                    SESSIONS_SKIPPED=$((SESSIONS_SKIPPED + 1))
                    continue
                fi
            fi

            sessions_to_process+=("$session_path")

            # Apply limit if set
            if [ "$LIMIT" -gt 0 ] && [ "${#sessions_to_process[@]}" -ge "$LIMIT" ]; then
                break
            fi

        done <<< "$sessions"
    fi

    log_info "Scanned $scan_count sessions" >&2
    log_info "Found ${#sessions_to_process[@]} sessions needing merge" >&2
    log_info "Skipped $SESSIONS_SKIPPED sessions (already have audio.wav)" >&2
    echo "" >&2

    # Output sessions (one per line) - only to stdout
    if [ ${#sessions_to_process[@]} -gt 0 ]; then
        printf '%s\n' "${sessions_to_process[@]}"
    fi
}

# ============================================================================
# Merge Session Chunks
# ============================================================================

merge_session_chunks() {
    local session_path="$1"
    local session_id=$(basename "$session_path")
    local session_dir="$TEMP_DIR/$session_id"

    log_info "Processing session: $session_id"

    # Create temp directory for this session
    mkdir -p "$session_dir"

    # 1. Download all chunks
    log_info "  Downloading audio chunks..."
    aws s3 sync "s3://$S3_BUCKET/$session_path/" "$session_dir/" \
        --exclude "*" --include "chunk-*.webm" \
        --quiet

    # Find and sort chunks
    local chunks=($(find "$session_dir" -name "chunk-*.webm" -type f | sort -V))
    local chunk_count=${#chunks[@]}

    if [ "$chunk_count" -eq 0 ]; then
        log_warn "  No audio chunks found, skipping"
        rm -rf "$session_dir"
        return 1
    fi

    log_info "  Found $chunk_count audio chunks"

    # Dry run - just report what would be done
    if [ "$DRY_RUN" = "true" ]; then
        log_info "  [DRY RUN] Would merge $chunk_count chunks into audio.wav"
        if [ "$DELETE_CHUNKS" = "true" ]; then
            log_info "  [DRY RUN] Would delete original chunks after merge"
        fi
        rm -rf "$session_dir"
        return 0
    fi

    # 2. Create ffmpeg concat file
    local concat_file="$session_dir/concat.txt"
    for chunk in "${chunks[@]}"; do
        echo "file '$chunk'" >> "$concat_file"
    done

    # 3. Merge with ffmpeg (16kHz mono WAV - optimal for transcription)
    local output_audio="$session_dir/audio.wav"
    log_info "  Merging chunks with ffmpeg..."

    local ffmpeg_start=$(date +%s)
    if ! ffmpeg -y -f concat -safe 0 -i "$concat_file" \
        -ar 16000 -ac 1 -c:a pcm_s16le \
        "$output_audio" \
        -loglevel warning 2>&1; then
        log_error "  ffmpeg merge failed"
        rm -rf "$session_dir"
        return 1
    fi
    local ffmpeg_end=$(date +%s)
    local ffmpeg_time=$((ffmpeg_end - ffmpeg_start))

    # Get merged file stats
    local file_size=$(stat -c%s "$output_audio" 2>/dev/null || stat -f%z "$output_audio" 2>/dev/null)
    local audio_duration=$((file_size / 32000))  # 16kHz * 2 bytes/sample

    log_info "  Merged: ${audio_duration}s audio, ${file_size} bytes (${ffmpeg_time}s)"

    # 4. Upload merged file to S3
    log_info "  Uploading audio.wav to S3..."
    if ! aws s3 cp "$output_audio" "s3://$S3_BUCKET/$session_path/audio.wav" --quiet; then
        log_error "  S3 upload failed"
        rm -rf "$session_dir"
        return 1
    fi

    log_success "  Uploaded audio.wav"

    # 5. Optionally delete original chunks
    if [ "$DELETE_CHUNKS" = "true" ]; then
        log_info "  Deleting original chunks from S3..."
        for i in $(seq -f "%03g" 1 $chunk_count); do
            aws s3 rm "s3://$S3_BUCKET/$session_path/chunk-$i.webm" --quiet 2>/dev/null || true
        done
        log_success "  Deleted $chunk_count chunks"
    fi

    # Update statistics
    SESSIONS_MERGED=$((SESSIONS_MERGED + 1))
    TOTAL_CHUNKS_PROCESSED=$((TOTAL_CHUNKS_PROCESSED + chunk_count))
    TOTAL_AUDIO_SECONDS=$((TOTAL_AUDIO_SECONDS + audio_duration))

    # Cleanup
    rm -rf "$session_dir"

    return 0
}

# ============================================================================
# Generate Report
# ============================================================================

generate_report() {
    local timestamp_end=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    cat > "$REPORT_FILE" <<EOF
{
    "type": "merge-chunks-worker",
    "timestamp_start": "$TIMESTAMP_START",
    "timestamp_end": "$timestamp_end",
    "dry_run": $DRY_RUN,
    "delete_chunks": $DELETE_CHUNKS,
    "force_merge": $FORCE_MERGE,
    "sessions_merged": $SESSIONS_MERGED,
    "sessions_skipped": $SESSIONS_SKIPPED,
    "sessions_failed": $SESSIONS_FAILED,
    "total_chunks_processed": $TOTAL_CHUNKS_PROCESSED,
    "total_audio_seconds": $TOTAL_AUDIO_SECONDS,
    "s3_bucket": "$S3_BUCKET"
}
EOF

    log_success "Report saved: $REPORT_FILE"
}

# ============================================================================
# Main
# ============================================================================

main() {
    log_info "Starting Merge Chunks Worker..."
    if [ "$DRY_RUN" = "true" ]; then
        log_warn "DRY RUN MODE - no changes will be made"
    fi
    if [ "$DELETE_CHUNKS" = "true" ]; then
        log_warn "DELETE_CHUNKS enabled - original chunks will be removed after merge"
    fi
    echo ""

    # Validate prerequisites
    validate_prerequisites

    # Find sessions needing merge
    local sessions
    sessions=$(find_sessions_needing_merge) || exit 1

    if [ -z "$sessions" ]; then
        log_success "No sessions need merging!"
        echo ""
        echo "All sessions either:"
        echo "  - Already have audio.wav (use --force to re-merge)"
        echo "  - Have no audio chunks"
        exit 0
    fi

    local session_count=$(echo "$sessions" | wc -l | tr -d ' ')
    log_info "Processing $session_count sessions..."
    echo ""

    # Process each session
    while IFS= read -r session_path; do
        if [ -z "$session_path" ]; then
            continue
        fi

        if merge_session_chunks "$session_path"; then
            if [ "$DRY_RUN" = "false" ]; then
                log_success "Session merged successfully"
            fi
        else
            SESSIONS_FAILED=$((SESSIONS_FAILED + 1))
            log_error "Session merge failed"
        fi
        echo ""
    done <<< "$sessions"

    # Generate report
    generate_report

    # Summary
    echo ""
    echo "============================================"
    echo "Merge Chunks Worker Complete"
    echo "============================================"
    echo ""
    if [ "$DRY_RUN" = "true" ]; then
        echo "  [DRY RUN - no changes made]"
        echo ""
    fi
    echo "  Sessions merged:     $SESSIONS_MERGED"
    echo "  Sessions skipped:    $SESSIONS_SKIPPED"
    echo "  Sessions failed:     $SESSIONS_FAILED"
    echo "  Total chunks:        $TOTAL_CHUNKS_PROCESSED"
    echo "  Total audio:         ~$((TOTAL_AUDIO_SECONDS / 60)) minutes"
    echo ""
    echo "  Report: $REPORT_FILE"
    echo ""

    if [ "$SESSIONS_FAILED" -gt 0 ]; then
        log_warn "Some sessions failed. Check logs for details."
        exit 1
    fi
}

main "$@"
