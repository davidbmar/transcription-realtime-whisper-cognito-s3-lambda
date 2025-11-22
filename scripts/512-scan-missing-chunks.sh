#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Script 512: Scan S3 for Missing Transcription Chunks
# ============================================================================
# Scans all user sessions in S3 to identify audio chunks that are missing
# their corresponding transcription files. This is a fast, read-only operation
# that does NOT require GPU access.
#
# What this does:
# 1. Lists all user sessions in S3
# 2. For each session, compares audio chunks vs transcription chunks
# 3. Identifies missing transcription chunks
# 4. Generates pending-jobs.json with full details
# 5. Outputs missing chunk count (used by 515 to decide if GPU is needed)
#
# Requirements:
# - .env variables: COGNITO_S3_BUCKET
# - AWS CLI configured with S3 read access
# - jq installed (for JSON generation)
#
# Output:
# - /tmp/pending-jobs.json - Detailed list of missing chunks
# - stdout: Missing chunk count (for script chaining)
#
# Total time: ~5-15 seconds for 100 sessions
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
echo "512: Scan S3 for Missing Transcription Chunks"
echo "============================================"
echo ""

log_info "This script will:"
log_info "  1. Scan all user sessions in S3"
log_info "  2. Compare audio chunks vs transcription chunks"
log_info "  3. Generate pending-jobs.json"
log_info "  4. Report missing chunk count"
echo ""

# ============================================================================
# Configuration
# ============================================================================

S3_BUCKET="${COGNITO_S3_BUCKET}"
OUTPUT_FILE="/tmp/pending-jobs.json"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Validate required tools
if ! command -v jq &>/dev/null; then
    log_error "jq is required but not installed"
    log_info "Install with: sudo apt-get install -y jq"
    exit 1
fi

if ! command -v aws &>/dev/null; then
    log_error "AWS CLI is required but not installed"
    exit 1
fi

# ============================================================================
# Main Implementation
# ============================================================================

log_info "Step 1: Finding all user sessions in S3..."
SCAN_START=$(date +%s)

# Find all sessions with audio chunks (support multiple formats)
SESSIONS=$(aws s3 ls "s3://$S3_BUCKET/users/" --recursive 2>/dev/null | \
    grep -E 'chunk-[0-9]+\.(webm|aac|m4a|mp3|wav|ogg|flac)$' | \
    awk '{print $4}' | \
    sed 's|/chunk-.*||' | \
    sort -u)

SESSION_COUNT=$(echo "$SESSIONS" | grep -c . || echo "0")

if [ "$SESSION_COUNT" -eq 0 ]; then
    log_warn "No sessions with audio chunks found in S3"
    log_info "Creating empty pending-jobs.json"

    # Create empty report
    cat > "$OUTPUT_FILE" <<EOF
{
  "timestamp": "$TIMESTAMP",
  "totalMissingChunks": 0,
  "sessionsScanned": 0,
  "sessions": []
}
EOF

    log_success "Scan completed: 0 missing chunks"
    echo "0"
    exit 0
fi

log_success "Found $SESSION_COUNT sessions with audio chunks"
echo ""

log_info "Step 2: Analyzing each session for missing transcriptions..."

# Arrays to store results
declare -a MISSING_SESSIONS=()
TOTAL_MISSING=0
SKIPPED_SESSIONS=0

# Temporarily disable pipefail for this section to handle errors gracefully
set +e

# Process each session
SESSION_NUM=0
for SESSION_PATH in $SESSIONS; do
    SESSION_NUM=$((SESSION_NUM + 1))
    SESSION_ID=$(basename "$SESSION_PATH")

    if [ $((SESSION_NUM % 10)) -eq 0 ]; then
        log_info "  Processed $SESSION_NUM/$SESSION_COUNT sessions ($SKIPPED_SESSIONS skipped)..."
    fi

    # OPTIMIZATION: Skip sessions with completion markers
    if has_completion_marker "$SESSION_PATH"; then
        SKIPPED_SESSIONS=$((SKIPPED_SESSIONS + 1))
        continue
    fi

    # Get all audio chunks for this session (support multiple formats)
    AUDIO_CHUNKS=$(aws s3 ls "s3://$S3_BUCKET/$SESSION_PATH/" 2>/dev/null | \
        grep -E 'chunk-[0-9]+\.(webm|aac|m4a|mp3|wav|ogg|flac)$' | \
        awk '{print $4}' | \
        sed 's/chunk-//' | \
        sed -E 's/\.(webm|aac|m4a|mp3|wav|ogg|flac)$//' | \
        sort -n)

    if [ -z "$AUDIO_CHUNKS" ]; then
        continue
    fi

    # Get all transcription chunks for this session
    TRANSCRIPTION_CHUNKS=$(aws s3 ls "s3://$S3_BUCKET/$SESSION_PATH/" 2>/dev/null | \
        grep -E 'transcription-chunk-[0-9]+\.json$' | \
        awk '{print $4}' | \
        sed 's/transcription-chunk-//' | \
        sed 's/\.json$//' | \
        sort -n)

    # Find missing transcriptions (audio chunks without corresponding transcription)
    MISSING_CHUNKS=""
    for CHUNK_NUM in $AUDIO_CHUNKS; do
        # Check if this chunk number exists in transcription list
        # Use grep -w for word boundary matching (exact match without regex anchors)
        if [ -z "$TRANSCRIPTION_CHUNKS" ] || ! echo "$TRANSCRIPTION_CHUNKS" | grep -qw "^${CHUNK_NUM}$" 2>/dev/null; then
            if [ -z "$MISSING_CHUNKS" ]; then
                MISSING_CHUNKS="$CHUNK_NUM"
            else
                MISSING_CHUNKS="$MISSING_CHUNKS $CHUNK_NUM"
            fi
        fi
    done

    # If this session has missing chunks, add to results
    if [ -n "$MISSING_CHUNKS" ]; then
        MISSING_COUNT=$(echo "$MISSING_CHUNKS" | wc -w)
        TOTAL_MISSING=$((TOTAL_MISSING + MISSING_COUNT))

        # Skip slow file size calculation (not needed for transcription)
        TOTAL_SIZE=0

        # Build JSON array of missing chunk numbers
        CHUNK_ARRAY="["
        FIRST=true
        for CHUNK_NUM in $MISSING_CHUNKS; do
            if [ "$FIRST" = true ]; then
                CHUNK_ARRAY="${CHUNK_ARRAY}\"${CHUNK_NUM}\""
                FIRST=false
            else
                CHUNK_ARRAY="${CHUNK_ARRAY}, \"${CHUNK_NUM}\""
            fi
        done
        CHUNK_ARRAY="${CHUNK_ARRAY}]"

        # Store session info as JSON
        SESSION_JSON=$(cat <<EOF
{
  "sessionPath": "$SESSION_PATH",
  "sessionId": "$SESSION_ID",
  "missingChunks": $CHUNK_ARRAY,
  "missingCount": $MISSING_COUNT,
  "totalAudioSize": $TOTAL_SIZE
}
EOF
)
        MISSING_SESSIONS+=("$SESSION_JSON")
    fi
done

# Re-enable error checking
set -e

SCAN_END=$(date +%s)
SCAN_DURATION=$((SCAN_END - SCAN_START))

log_success "Analysis completed in ${SCAN_DURATION}s"
echo ""

log_info "Step 3: Generating pending-jobs.json..."

# Build sessions array
SESSIONS_JSON="["
if [ ${#MISSING_SESSIONS[@]} -gt 0 ]; then
    FIRST=true
    for SESSION_JSON in "${MISSING_SESSIONS[@]}"; do
        if [ "$FIRST" = true ]; then
            SESSIONS_JSON="${SESSIONS_JSON}${SESSION_JSON}"
            FIRST=false
        else
            SESSIONS_JSON="${SESSIONS_JSON}, ${SESSION_JSON}"
        fi
    done
fi
SESSIONS_JSON="${SESSIONS_JSON}]"

# Generate final JSON report
cat > "$OUTPUT_FILE" <<EOF
{
  "timestamp": "$TIMESTAMP",
  "scanDurationSeconds": $SCAN_DURATION,
  "sessionsScanned": $SESSION_COUNT,
  "sessionsWithMissingChunks": ${#MISSING_SESSIONS[@]},
  "totalMissingChunks": $TOTAL_MISSING,
  "sessions": $SESSIONS_JSON
}
EOF

log_success "Report saved to: $OUTPUT_FILE"
echo ""

# ============================================================================
# Success Reporting
# ============================================================================

log_info "==================================================================="
if [ "$TOTAL_MISSING" -eq 0 ]; then
    log_success "✅ SCAN COMPLETE - NO MISSING CHUNKS"
else
    log_success "✅ SCAN COMPLETE - FOUND $TOTAL_MISSING MISSING CHUNKS"
fi
log_info "==================================================================="
echo ""
log_info "Scan Summary:"
log_info "  - Sessions scanned: $SESSION_COUNT"
log_info "  - Sessions skipped (already complete): $SKIPPED_SESSIONS"
log_info "  - Sessions analyzed: $((SESSION_COUNT - SKIPPED_SESSIONS))"
log_info "  - Sessions with missing chunks: ${#MISSING_SESSIONS[@]}"
log_info "  - Total missing chunks: $TOTAL_MISSING"
log_info "  - Scan duration: ${SCAN_DURATION}s"
log_info "  - Report: $OUTPUT_FILE"
echo ""

if [ "$TOTAL_MISSING" -gt 0 ]; then
    log_info "Next Steps:"
    log_info "  1. View detailed report: cat $OUTPUT_FILE | jq ."
    log_info "  2. Run batch transcription: ./scripts/515-run-batch-transcribe.sh"
    log_info "  3. Or wait for automatic 2-hour cron"
else
    log_info "No action needed - all audio chunks have transcriptions!"
fi
echo ""

# Output count for script chaining (515 uses this)
echo "$TOTAL_MISSING"
