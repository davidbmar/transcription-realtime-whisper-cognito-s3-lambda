#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Script 565: Post-process Batch Transcripts (No GPU Required)
# ============================================================================
# Runs LLM-based post-processing on batch-transcribed sessions.
# This script does NOT require GPU - it uses Claude API and Bedrock API.
#
# What this does:
# 1. Find sessions with transcription-diarized.json but no transcription-processed.json
# 2. Run speaker identification (561) - Claude API identifies real names
# 3. Run merge speaker turns (562) - Consolidate consecutive same-speaker segments
# 4. Run topic segmentation (524) - Bedrock embeddings detect topic boundaries
#
# Use cases:
# - Process existing transcriptions that missed post-processing
# - Re-run post-processing after fixing bugs in scripts
# - Scheduled cron job to process new transcriptions
#
# Note: This is separate from 518-postprocess-transcripts.sh which handles
# real-time transcription chunks (deduplication, formatting).
#
# Usage:
#   ./scripts/565-postprocess-batch-transcripts.sh           # Process all sessions
#   ./scripts/565-postprocess-batch-transcripts.sh --all     # Same as above
#   ./scripts/565-postprocess-batch-transcripts.sh --session <session-path>  # Specific session
#   ./scripts/565-postprocess-batch-transcripts.sh --dry-run # Show what would be processed
#
# Requirements:
# - .env variables: ANTHROPIC_API_KEY (for speaker ID), AWS credentials (for Bedrock)
# - Python 3 with boto3, anthropic packages
# - NO GPU required!
#
# Total time: ~30 seconds per session
# ============================================================================

# Resolve script path
if [ -L "${BASH_SOURCE[0]}" ]; then
    SCRIPT_REAL=$(readlink -f "${BASH_SOURCE[0]}")
else
    SCRIPT_REAL="${BASH_SOURCE[0]}"
fi
PROJECT_ROOT="$(cd "$(dirname "$SCRIPT_REAL")/.." && pwd)"

# Load environment with auto-export (for Python subprocess)
set -a
source "$PROJECT_ROOT/.env"
set +a
source "$PROJECT_ROOT/scripts/lib/common-functions.sh"

# Script locations
SPEAKER_ID_SCRIPT="$PROJECT_ROOT/scripts/561-identify-speakers-llm.py"
MERGE_TURNS_SCRIPT="$PROJECT_ROOT/scripts/562-merge-speaker-turns.py"
TOPIC_SEGMENT_SCRIPT="$PROJECT_ROOT/scripts/524-segment-transcripts-by-topic.py"

# Configuration
BUCKET="${COGNITO_S3_BUCKET}"
ENABLE_SPEAKER_ID="${ENABLE_SPEAKER_ID:-true}"
ENABLE_MERGE_TURNS="${ENABLE_MERGE_TURNS:-true}"
ENABLE_TOPIC_SEGMENTATION="${ENABLE_TOPIC_SEGMENTATION:-true}"

# Parse arguments
DRY_RUN=false
SESSION_PATH=""
PROCESS_ALL=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --session)
            SESSION_PATH="$2"
            shift 2
            ;;
        --all)
            PROCESS_ALL=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--all] [--session <path>] [--dry-run]"
            exit 1
            ;;
    esac
done

echo "============================================"
echo "565: Post-process Batch Transcripts"
echo "============================================"
echo ""
echo "This script runs LLM-based post-processing:"
echo "  1. Speaker identification (Claude API)"
echo "  2. Merge speaker turns (JSON manipulation)"
echo "  3. Topic segmentation (Bedrock embeddings)"
echo ""
echo "NO GPU REQUIRED - uses cloud APIs only"
echo ""

if [ "$DRY_RUN" = true ]; then
    echo "MODE: DRY RUN - will show what would be processed"
    echo ""
fi

# Counters
PROCESSED=0
SKIPPED=0
FAILED=0
NEEDS_PROCESSING=0

# ============================================================================
# Functions
# ============================================================================

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

    log_info "  Running speaker identification..."
    if python3 "$SPEAKER_ID_SCRIPT" "$transcript_s3_path" --update 2>&1 | sed 's/^/    /'; then
        log_success "  Speaker identification complete"
        return 0
    else
        log_warn "  Speaker identification failed (continuing anyway)"
        return 0
    fi
}

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
    if python3 "$MERGE_TURNS_SCRIPT" "$transcript_s3_path" --update 2>&1 | sed 's/^/    /'; then
        log_success "  Speaker turns merged"
        return 0
    else
        log_warn "  Merge turns failed (continuing anyway)"
        return 0
    fi
}

segment_by_topic() {
    local session_path="$1"

    if [ "$ENABLE_TOPIC_SEGMENTATION" != "true" ]; then
        log_info "  Topic segmentation disabled"
        return 0
    fi

    if [ ! -f "$TOPIC_SEGMENT_SCRIPT" ]; then
        log_warn "  Topic segment script not found: $TOPIC_SEGMENT_SCRIPT"
        return 0
    fi

    log_info "  Running topic segmentation..."
    if python3 "$TOPIC_SEGMENT_SCRIPT" --session "$session_path" 2>&1 | sed 's/^/    /'; then
        log_success "  Topic segmentation complete"
        return 0
    else
        log_warn "  Topic segmentation failed (continuing anyway)"
        return 0
    fi
}

process_session() {
    local session_path="$1"
    local session_name=$(basename "$session_path")

    log_info "Processing: $session_name"

    # Check if diarized file exists
    local diarized_path="s3://${BUCKET}/${session_path}/transcription-diarized.json"
    if ! aws s3 ls "$diarized_path" &>/dev/null; then
        log_info "  No transcription-diarized.json found - skipping"
        SKIPPED=$((SKIPPED + 1))
        return 0
    fi

    # Check if already processed
    local processed_path="s3://${BUCKET}/${session_path}/transcription-processed.json"
    if aws s3 ls "$processed_path" &>/dev/null; then
        log_info "  Already has transcription-processed.json - skipping"
        SKIPPED=$((SKIPPED + 1))
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        log_info "  Would process: $diarized_path"
        NEEDS_PROCESSING=$((NEEDS_PROCESSING + 1))
        return 0
    fi

    # Step 1: Speaker identification
    identify_speakers "$diarized_path"

    # Step 2: Merge speaker turns (reads diarized, writes processed)
    merge_speaker_turns "$diarized_path"

    # Step 3: Topic segmentation
    segment_by_topic "$session_path"

    log_success "Session processed: $session_name"
    PROCESSED=$((PROCESSED + 1))
}

# ============================================================================
# Main Logic
# ============================================================================

# Check prerequisites
if [ -z "$BUCKET" ]; then
    log_error "COGNITO_S3_BUCKET not set in .env"
    exit 1
fi

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    log_warn "ANTHROPIC_API_KEY not set - speaker identification will be skipped"
    ENABLE_SPEAKER_ID=false
fi

# Process specific session if provided
if [ -n "$SESSION_PATH" ]; then
    log_info "Processing specific session: $SESSION_PATH"
    echo ""
    process_session "$SESSION_PATH"
else
    # Find all sessions with diarized transcripts
    log_info "Scanning for batch-transcribed sessions in s3://$BUCKET/users/"
    echo ""

    # List all diarized files
    DIARIZED_FILES=$(aws s3 ls "s3://$BUCKET/users/" --recursive | \
        grep "transcription-diarized.json" | \
        awk '{print $4}' | \
        sed 's|/transcription-diarized.json||' || echo "")

    if [ -z "$DIARIZED_FILES" ]; then
        log_warn "No batch-transcribed sessions found"
        exit 0
    fi

    SESSION_COUNT=$(echo "$DIARIZED_FILES" | wc -l | tr -d ' ')
    log_info "Found $SESSION_COUNT sessions with diarized transcripts"
    echo ""

    # Process each session
    while IFS= read -r session_path; do
        if [ -n "$session_path" ]; then
            process_session "$session_path"
            echo ""
        fi
    done <<< "$DIARIZED_FILES"
fi

# ============================================================================
# Summary
# ============================================================================

echo ""
log_info "==================================================================="
log_success "POST-PROCESSING COMPLETE"
log_info "==================================================================="
echo ""
log_info "Summary:"

if [ "$DRY_RUN" = true ]; then
    log_info "  Sessions that need processing: $NEEDS_PROCESSING"
    log_info "  Sessions already processed: $SKIPPED"
    echo ""
    log_info "Run without --dry-run to process these sessions"
else
    log_info "  Processed: $PROCESSED"
    log_info "  Skipped (already done or no diarized file): $SKIPPED"
    log_info "  Failed: $FAILED"
fi

echo ""
log_info "Configuration:"
log_info "  Speaker identification: $ENABLE_SPEAKER_ID"
log_info "  Merge speaker turns: $ENABLE_MERGE_TURNS"
log_info "  Topic segmentation: $ENABLE_TOPIC_SEGMENTATION"
echo ""

if [ $PROCESSED -gt 0 ]; then
    log_success "Processed $PROCESSED sessions successfully"
fi

log_info "Next steps:"
log_info "  - View transcripts in editor: ${COGNITO_CLOUDFRONT_URL}/transcript-editor-v2.html"
log_info "  - Schedule with cron: 0 */2 * * * /path/to/scripts/565-postprocess-batch-transcripts.sh"
