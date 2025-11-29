#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Script 524: Segment Transcripts by Topic
# ============================================================================
# Analyzes transcript segments using semantic embeddings to detect topic
# changes and inserts paragraph breaks at topic boundaries.
#
# What this does:
# 1. Load transcript from S3 (transcription-processed.json)
# 2. Generate embeddings for each paragraph using Amazon Bedrock
# 3. Cache embeddings in S3 Vectors for reuse
# 4. Calculate cosine similarity between consecutive paragraphs
# 5. Detect topic boundaries where similarity drops below threshold
# 6. Save topic-segmented transcript back to S3
#
# Usage:
#   ./scripts/524-segment-transcripts-by-topic.sh --session <path>
#   ./scripts/524-segment-transcripts-by-topic.sh --all
#   ./scripts/524-segment-transcripts-by-topic.sh --session <path> --dry-run
#
# Arguments:
#   --session <path>     Process a single session (S3 path)
#   --all                Process all sessions that have processed transcripts
#   --dry-run            Show what would be done without saving
#   --skip-cache         Force regenerate embeddings (skip S3 Vectors cache)
#   --threshold <0.0-1.0> Override TOPIC_SIMILARITY_THRESHOLD from .env
#
# Prerequisites:
#   - Amazon Bedrock access (for embeddings)
#   - S3 Vectors bucket created (run 523-setup-s3-vectors.sh first)
#   - .env with COGNITO_S3_BUCKET, TOPIC_SIMILARITY_THRESHOLD, etc.
#
# Performance:
#   - First run: ~2-5 seconds per 10 paragraphs (Bedrock API calls)
#   - Cached: <1 second per session (S3 Vectors lookup)
#   - Typical 50-paragraph transcript: 10-25 seconds first run
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

echo "============================================"
echo "524: Segment Transcripts by Topic"
echo "============================================"
echo ""

# Configuration
BUCKET="${COGNITO_S3_BUCKET}"
THRESHOLD="${TOPIC_SIMILARITY_THRESHOLD:-0.75}"
PYTHON_SCRIPT="$PROJECT_ROOT/scripts/524-segment-transcripts-by-topic.py"

# Parse arguments
SESSION_PATH=""
PROCESS_ALL=false
DRY_RUN=false
SKIP_CACHE=false
CUSTOM_THRESHOLD=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --session)
            SESSION_PATH="$2"
            shift 2
            ;;
        --all)
            PROCESS_ALL=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --skip-cache)
            SKIP_CACHE=true
            shift
            ;;
        --threshold)
            CUSTOM_THRESHOLD="$2"
            shift 2
            ;;
        *)
            log_error "Unknown argument: $1"
            echo "Usage: $0 --session <path> | --all [--dry-run] [--skip-cache] [--threshold <0.0-1.0>]"
            exit 1
            ;;
    esac
done

# Validate arguments
if [ -z "$SESSION_PATH" ] && [ "$PROCESS_ALL" = false ]; then
    log_error "Either --session <path> or --all is required"
    echo ""
    echo "Usage:"
    echo "  $0 --session users/123/audio/sessions/abc"
    echo "  $0 --all"
    echo "  $0 --session <path> --dry-run"
    echo "  $0 --all --threshold 0.6"
    exit 1
fi

# Check prerequisites
if ! command -v python3 &> /dev/null; then
    log_error "python3 not found"
    exit 1
fi

if [ ! -f "$PYTHON_SCRIPT" ]; then
    log_error "Python script not found: $PYTHON_SCRIPT"
    exit 1
fi

if [ -z "$BUCKET" ]; then
    log_error "COGNITO_S3_BUCKET not set in .env"
    exit 1
fi

# Check if threshold is set
if [ -z "${TOPIC_SIMILARITY_THRESHOLD:-}" ] && [ -z "$CUSTOM_THRESHOLD" ]; then
    log_warn "TOPIC_SIMILARITY_THRESHOLD not set in .env"
    log_info "Using default threshold: 0.75"
    log_info ""
    log_info "To set a custom threshold, either:"
    log_info "  1. Add TOPIC_SIMILARITY_THRESHOLD=0.75 to .env"
    log_info "  2. Use --threshold 0.75 argument"
    echo ""
fi

# Build Python command arguments
PYTHON_ARGS=()
if [ -n "$CUSTOM_THRESHOLD" ]; then
    PYTHON_ARGS+=("--topic-threshold" "$CUSTOM_THRESHOLD")
fi
if [ "$DRY_RUN" = true ]; then
    PYTHON_ARGS+=("--dry-run")
fi
if [ "$SKIP_CACHE" = true ]; then
    PYTHON_ARGS+=("--skip-cache")
fi

# ============================================================================
# Process Functions
# ============================================================================

process_session() {
    local session_folder="$1"
    local session_name=$(basename "$session_folder")

    log_info "Processing session: $session_name"

    # Check if processed transcript exists
    if ! aws s3 ls "s3://$BUCKET/${session_folder}/transcription-processed.json" &>/dev/null; then
        log_warn "  No processed transcript found - skipping"
        log_warn "  Run 518-postprocess-transcripts.sh first"
        return 1
    fi

    # Check if already topic-segmented (and not forcing regeneration)
    if [ "$SKIP_CACHE" = false ] && aws s3 ls "s3://$BUCKET/${session_folder}/transcription-topic-segmented.json" &>/dev/null; then
        log_info "  Already topic-segmented - skipping"
        return 0
    fi

    # Run Python script
    if python3 "$PYTHON_SCRIPT" --session "$session_folder" "${PYTHON_ARGS[@]}"; then
        log_success "  ✅ Topic segmentation complete"
        return 0
    else
        log_error "  ❌ Topic segmentation failed"
        return 1
    fi
}

# ============================================================================
# Main Logic
# ============================================================================

PROCESSED_COUNT=0
SKIPPED_COUNT=0
FAILED_COUNT=0

if [ -n "$SESSION_PATH" ]; then
    # Process single session
    log_info "Processing single session..."
    log_info "  Path: $SESSION_PATH"
    log_info "  Threshold: ${CUSTOM_THRESHOLD:-$THRESHOLD}"
    echo ""

    if process_session "$SESSION_PATH"; then
        PROCESSED_COUNT=1
    else
        FAILED_COUNT=1
    fi

elif [ "$PROCESS_ALL" = true ]; then
    # Process all sessions
    log_info "Scanning all audio sessions in s3://$BUCKET/users/"
    log_info "  Threshold: ${CUSTOM_THRESHOLD:-$THRESHOLD}"
    echo ""

    # Find all sessions with processed transcripts
    SESSION_FOLDERS=$(aws s3 ls "s3://$BUCKET/users/" --recursive | \
        grep "transcription-processed.json" | \
        awk '{print $4}' | \
        sed 's|/transcription-processed.json||' | \
        sort -u)

    SESSION_COUNT=$(echo "$SESSION_FOLDERS" | grep -c "users/" 2>/dev/null || echo "0")

    if [ "$SESSION_COUNT" -eq 0 ]; then
        log_warn "No sessions with processed transcripts found"
        log_info "Run 518-postprocess-transcripts.sh first"
        exit 0
    fi

    log_info "Found $SESSION_COUNT sessions with processed transcripts"
    echo ""

    # Process each session
    while IFS= read -r session_folder; do
        if [ -n "$session_folder" ]; then
            if process_session "$session_folder"; then
                if aws s3 ls "s3://$BUCKET/${session_folder}/transcription-topic-segmented.json" &>/dev/null; then
                    PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
                else
                    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
                fi
            else
                FAILED_COUNT=$((FAILED_COUNT + 1))
            fi
            echo ""
        fi
    done <<< "$SESSION_FOLDERS"
fi

# ============================================================================
# Summary
# ============================================================================

echo ""
log_info "============================================"
log_success "✅ TOPIC SEGMENTATION COMPLETE"
log_info "============================================"
echo ""
log_info "Summary:"
log_info "  Processed: $PROCESSED_COUNT"
log_info "  Skipped (already done): $SKIPPED_COUNT"
log_info "  Failed: $FAILED_COUNT"
echo ""

if [ "$DRY_RUN" = true ]; then
    log_warn "DRY RUN - No files were modified"
    echo ""
fi

log_info "Next steps:"
log_info "  1. View in transcript editor (topic breaks will be visible)"
log_info "  2. Run AI analysis: ./scripts/525-generate-ai-analysis.sh"
log_info "  3. Adjust threshold if needed: --threshold 0.6 (more breaks) or 0.85 (fewer breaks)"
echo ""

# Exit with error if any failed
if [ "$FAILED_COUNT" -gt 0 ]; then
    exit 1
fi
