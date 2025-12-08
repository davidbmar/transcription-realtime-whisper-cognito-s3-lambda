#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Script 518: Postprocess Transcripts - Generate Pre-processed Files for Editor
# ============================================================================
# Scans all audio sessions and generates pre-processed transcripts for any
# sessions that are complete but don't have a processed file yet.
#
# What this does:
# 1. List all audio sessions in S3
# 2. For each session:
#    a. Check if transcription-processed.json already exists
#    b. If not, check if all transcription chunks are present
#    c. If complete, run the postprocessing pipeline:
#       - Deduplicate chunk boundaries (lib/deduplicate-transcript-boundaries.js)
#       - Apply rule-based formatting (lib/format-transcript-rules.js)
#       - Update session metadata (lib/update-session-metadata.js)
#    d. If incomplete, skip (transcription still in progress)
# 3. Report summary of processed sessions
#
# When to run:
# - Automatically after batch transcription completes (called by 515)
# - Manually via cron to catch any missed sessions
# - On-demand when loading editor is slow
# - With --force to regenerate all files (after fixing timestamp bugs)
#
# Usage:
#   ./518-postprocess-transcripts.sh                      # Process all sessions
#   ./518-postprocess-transcripts.sh --session <folder>   # Process specific session
#   ./518-postprocess-transcripts.sh --force              # Force regenerate ALL files
#   ./518-postprocess-transcripts.sh --force --session <folder>  # Force specific session
#
# Performance:
#   - Scans ~100 sessions in ~5 seconds
#   - Processes each complete session in ~2-5 seconds
#
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

# Parse command line arguments
FORCE_REGENERATE=false
SESSION_PATH=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --force)
            FORCE_REGENERATE=true
            shift
            ;;
        --session)
            SESSION_PATH="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--force] [--session <folder>]"
            exit 1
            ;;
    esac
done

echo "============================================"
echo "518: Postprocess Transcripts"
echo "============================================"
echo ""
echo "What this script does:"
echo "  1. Scans all audio sessions in S3"
echo "  2. For sessions with all transcription chunks:"
echo "     - Deduplicate overlapping words at chunk boundaries"
echo "     - Convert word timestamps to absolute session time"
echo "     - Apply rule-based formatting"
echo "     - Run topic segmentation (if enabled)"
echo "  3. Upload transcription-processed.json for fast editor loading"
echo ""
if [ "$FORCE_REGENERATE" = true ]; then
    echo "MODE: FORCE REGENERATE - Will delete and recreate ALL processed files"
    echo ""
fi

BUCKET="${COGNITO_S3_BUCKET}"
PROCESSED_COUNT=0
SKIPPED_COUNT=0
ALREADY_PROCESSED_COUNT=0
INCOMPLETE_COUNT=0
INVALIDATED_COUNT=0
FORCE_DELETED_COUNT=0

# Check prerequisites
if ! command -v node &> /dev/null; then
    log_error "Node.js not found - required for preprocessing"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    log_error "jq not found - required for JSON processing"
    exit 1
fi

if [ -z "$BUCKET" ]; then
    log_error "COGNITO_S3_BUCKET not set in .env"
    exit 1
fi

# ============================================================================
# Functions
# ============================================================================

# Check if session has pre-processed file
has_processed_file() {
    local session_folder="$1"
    aws s3 ls "s3://$BUCKET/${session_folder}/transcription-processed.json" &>/dev/null
}

# Count transcription chunks in session
count_chunks() {
    local session_folder="$1"
    local count=$(aws s3 ls "s3://$BUCKET/${session_folder}/" 2>/dev/null | grep -c "transcription-chunk-.*\.json" || echo "0")
    echo "$count" | tr -d '\n'
}

# Count audio chunks in session
count_audio_chunks() {
    local session_folder="$1"
    local count=$(aws s3 ls "s3://$BUCKET/${session_folder}/" 2>/dev/null | grep -c "chunk-.*\.webm" || echo "0")
    echo "$count" | tr -d '\n'
}

# Get metadata from processed file (chunk count)
get_processed_chunk_count() {
    local session_folder="$1"
    local metadata=$(aws s3api head-object \
        --bucket "$BUCKET" \
        --key "${session_folder}/transcription-processed.json" \
        2>/dev/null || echo "{}")

    # Try to extract paragraph-count from metadata
    echo "$metadata" | jq -r '.Metadata["paragraph-count"] // "0"' 2>/dev/null || echo "0"
}

# Check if processed file is stale (more chunks exist than when it was generated)
is_processed_stale() {
    local session_folder="$1"
    local trans_count="$2"

    # Download the processed file and check how many chunks it represents
    local temp_file=$(mktemp)
    if aws s3 cp "s3://$BUCKET/${session_folder}/transcription-processed.json" "$temp_file" &>/dev/null; then
        # Count unique chunkIds in the processed file
        local processed_chunks=$(jq -r '[.paragraphs[].chunkIds[]] | unique | length' "$temp_file" 2>/dev/null || echo "0")
        rm -f "$temp_file"

        if [ "$trans_count" -gt "$processed_chunks" ]; then
            return 0  # Stale (more chunks now than when processed)
        fi
    fi

    return 1  # Not stale
}

# Process a single session
process_session() {
    local session_folder="$1"
    local session_name=$(basename "$session_folder")

    log_info "Checking session: $session_name"

    # Count chunks
    local trans_count=$(count_chunks "$session_folder")
    local audio_count=$(count_audio_chunks "$session_folder")

    log_info "  Audio chunks: $audio_count"
    log_info "  Transcription chunks: $trans_count"

    # CASE 1: No transcription chunks at all (not transcribed yet)
    if [ "$trans_count" -eq 0 ]; then
        log_warn "  ⚠️  No transcription chunks found - skipping"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return 0
    fi

    # CASE 2: Transcription in progress (audio > transcription)
    if [ "$audio_count" -gt "$trans_count" ]; then
        local missing=$((audio_count - trans_count))

        # Check if processed file exists
        if has_processed_file "$session_folder"; then
            log_warn "  ⚠️  STALE: Processed file exists but $missing new chunks transcribed since then"
            log_warn "  🗑️  Deleting old transcription-processed.json to trigger regeneration"

            # Delete the stale processed file
            aws s3 rm "s3://$BUCKET/${session_folder}/transcription-processed.json" 2>&1 | sed 's/^/    /'

            log_warn "  ⏳ Waiting for remaining $missing chunks to be transcribed"
            INVALIDATED_COUNT=$((INVALIDATED_COUNT + 1))
        else
            log_warn "  ⏳ Incomplete: $missing chunks still need transcription - skipping"
            INCOMPLETE_COUNT=$((INCOMPLETE_COUNT + 1))
        fi
        return 0
    fi

    # CASE 3: Transcription complete, processed file exists
    if has_processed_file "$session_folder"; then
        # If --force flag, always regenerate
        if [ "$FORCE_REGENERATE" = true ]; then
            log_warn "  🔄 FORCE: Deleting existing transcription-processed.json"
            aws s3 rm "s3://$BUCKET/${session_folder}/transcription-processed.json" 2>&1 | sed 's/^/    /'

            # Also delete topic-segmented file to force regeneration
            aws s3 rm "s3://$BUCKET/${session_folder}/transcription-topic-segmented.json" 2>&1 | sed 's/^/    /' || true

            FORCE_DELETED_COUNT=$((FORCE_DELETED_COUNT + 1))
            log_info "  🔄 Regenerating with all $trans_count chunks..."
            # Fall through to regeneration below
        # Check if the processed file is stale (new chunks added after it was created)
        elif is_processed_stale "$session_folder" "$trans_count"; then
            log_warn "  ⚠️  STALE: Processed file exists but new chunks were added"
            log_warn "  🗑️  Deleting old transcription-processed.json"

            # Delete the stale processed file
            aws s3 rm "s3://$BUCKET/${session_folder}/transcription-processed.json" 2>&1 | sed 's/^/    /'

            log_info "  🔄 Regenerating with all $trans_count chunks..."
            INVALIDATED_COUNT=$((INVALIDATED_COUNT + 1))

            # Fall through to regeneration below
        else
            log_info "  ✅ Already has up-to-date transcription-processed.json"
            ALREADY_PROCESSED_COUNT=$((ALREADY_PROCESSED_COUNT + 1))
            return 0
        fi
    fi

    # CASE 4: Transcription complete, no processed file (or stale file was deleted above)
    log_info "  ✅ Complete! Generating pre-processed file with $trans_count chunks..."

    # Step 1: Run boundary deduplication
    if node "$PROJECT_ROOT/scripts/lib/deduplicate-transcript-boundaries.js" "$session_folder" 2>&1 | sed 's/^/    /'; then
        log_success "  ✅ Pre-processed successfully"
    else
        log_error "  ❌ Failed to preprocess"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return 1
    fi

    # Step 2: Run rule-based formatting
    log_info "  ✨ Applying rule-based formatting..."
    if node "$PROJECT_ROOT/scripts/lib/format-transcript-rules.js" "$session_folder" 2>&1 | sed 's/^/    /'; then
        log_success "  ✅ Formatted successfully"
    else
        log_warn "  ⚠️  Formatting failed, but preprocessing succeeded"
    fi

    # Step 3: Update metadata to mark transcription as complete
    log_info "  📝 Updating session metadata..."
    if node "$PROJECT_ROOT/scripts/lib/update-session-metadata.js" "$session_folder" complete 2>&1 | sed 's/^/    /'; then
        log_success "  ✅ Metadata updated - session marked as complete"
    else
        log_warn "  ⚠️  Metadata update failed"
    fi

    # NOTE: Diarization (520) and topic segmentation (524) are now handled by
    # 515-run-batch-transcribe.sh in Phase 3 and Phase 5 respectively.
    # This keeps 518 focused on: dedupe → format → metadata only.

    PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
    return 0
}

# ============================================================================
# Main Logic
# ============================================================================

# Check if specific session provided via --session argument
if [ -n "$SESSION_PATH" ]; then
    log_info "Processing specific session: $SESSION_PATH"
    process_session "$SESSION_PATH"
    exit $?
fi

# Scan all sessions
log_info "Scanning all audio sessions in s3://$BUCKET/users/"
echo ""

# List all session folders (format: users/{userId}/audio/sessions/{sessionId}/)
SESSION_FOLDERS=$(aws s3 ls "s3://$BUCKET/users/" --recursive | \
    grep "chunk-.*\.webm" | \
    awk '{print $4}' | \
    sed 's|/chunk-.*||' | \
    sort -u)

SESSION_COUNT=$(echo "$SESSION_FOLDERS" | grep -c "users/" || echo "0")

if [ "$SESSION_COUNT" -eq 0 ]; then
    log_warn "No audio sessions found"
    exit 0
fi

log_info "Found $SESSION_COUNT sessions to check"
echo ""

# Process each session
while IFS= read -r session_folder; do
    if [ -n "$session_folder" ]; then
        process_session "$session_folder"
        echo ""
    fi
done <<< "$SESSION_FOLDERS"

# ============================================================================
# Summary
# ============================================================================

log_info "==================================================================="
log_success "✅ PREPROCESSING SCAN COMPLETE"
log_info "==================================================================="
echo ""
log_info "Summary:"
log_info "  Total sessions scanned: $SESSION_COUNT"
log_info "  Already processed (up-to-date): $ALREADY_PROCESSED_COUNT"
log_info "  Newly processed: $PROCESSED_COUNT"
if [ $FORCE_DELETED_COUNT -gt 0 ]; then
    log_info "  Force regenerated: $FORCE_DELETED_COUNT"
fi
log_info "  Invalidated (stale, deleted): $INVALIDATED_COUNT"
log_info "  Incomplete (in progress): $INCOMPLETE_COUNT"
log_info "  Skipped (no transcriptions): $SKIPPED_COUNT"
echo ""

if [ $PROCESSED_COUNT -gt 0 ]; then
    log_success "Generated $PROCESSED_COUNT new pre-processed transcripts"
    log_info "   These sessions will now load in ~500ms instead of ~5 seconds"
fi

if [ $FORCE_DELETED_COUNT -gt 0 ]; then
    log_success "Force regenerated $FORCE_DELETED_COUNT transcripts with fixed timestamps"
fi

if [ $INVALIDATED_COUNT -gt 0 ]; then
    log_warn "Invalidated $INVALIDATED_COUNT stale pre-processed files"
    log_info "   Run this script again after batch transcription completes to regenerate"
fi

if [ $INCOMPLETE_COUNT -gt 0 ]; then
    log_info "$INCOMPLETE_COUNT sessions are still being transcribed"
    log_info "   Run this script again after batch transcription completes"
fi

echo ""
log_info "Next steps:"
log_info "  - View sessions: aws s3 ls s3://$BUCKET/users/ --recursive | grep transcription-processed.json"
log_info "  - Test editor: Open transcript-editor-v2.html and verify fast loading"
log_info "  - Schedule: Add to cron to run after batch transcription"
