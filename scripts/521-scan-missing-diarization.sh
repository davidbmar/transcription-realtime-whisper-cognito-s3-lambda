#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Script 521: Scan S3 for Sessions Missing Diarization
# ============================================================================
# Fast S3 scan to identify sessions that have transcription but are missing
# speaker diarization. This is a read-only operation that doesn't require GPU.
#
# What this does:
# 1. Lists all user sessions with transcription-processed.json
# 2. Identifies sessions missing transcription-diarized.json
# 3. Reports count for use by cron jobs
#
# Requirements:
# - .env variables: COGNITO_S3_BUCKET
# - AWS CLI configured with S3 read access
#
# Usage:
#   ./521-scan-missing-diarization.sh         # Report missing diarization
#   ./521-scan-missing-diarization.sh --list  # List session paths
#
# Total time: ~5-10 seconds for 100 sessions
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

# Parse arguments
LIST_SESSIONS=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --list)
            LIST_SESSIONS=true
            shift
            ;;
        --help|-h)
            head -35 "$0" | tail -30
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--list] [--help]"
            exit 1
            ;;
    esac
done

echo "============================================"
echo "521: Scan S3 for Missing Diarization"
echo "============================================"
echo ""

# ============================================================================
# Configuration
# ============================================================================

S3_BUCKET="${COGNITO_S3_BUCKET}"

if [ -z "$S3_BUCKET" ]; then
    log_error "COGNITO_S3_BUCKET not set in .env"
    exit 1
fi

# ============================================================================
# Main Implementation
# ============================================================================

log_info "Scanning S3 bucket: $S3_BUCKET"
SCAN_START=$(date +%s)

# Get all session paths in one efficient call
log_info "Step 1: Listing all files in users/..."
ALL_FILES=$(aws s3 ls "s3://$S3_BUCKET/users/" --recursive 2>/dev/null || echo "")

if [ -z "$ALL_FILES" ]; then
    log_warn "No files found in S3 bucket"
    echo "0"
    exit 0
fi

# Find sessions with transcription-processed.json
SESSIONS_WITH_TRANSCRIPTION=$(echo "$ALL_FILES" | \
    grep "transcription-processed.json" | \
    awk '{print $4}' | \
    sed 's|/transcription-processed.json||' | \
    sort -u)

# Find sessions with transcription-diarized.json
SESSIONS_WITH_DIARIZATION=$(echo "$ALL_FILES" | \
    grep "transcription-diarized.json" | \
    awk '{print $4}' | \
    sed 's|/transcription-diarized.json||' | \
    sort -u)

# Create temp files for set difference
TEMP_TRANS=$(mktemp)
TEMP_DIAR=$(mktemp)
echo "$SESSIONS_WITH_TRANSCRIPTION" > "$TEMP_TRANS"
echo "$SESSIONS_WITH_DIARIZATION" > "$TEMP_DIAR"

# Find sessions with transcription but no diarization
MISSING_DIARIZATION=$(comm -23 <(sort "$TEMP_TRANS") <(sort "$TEMP_DIAR") | grep -v "^$" || true)

# Cleanup temp files
rm -f "$TEMP_TRANS" "$TEMP_DIAR"

# Count results
TRANS_COUNT=$(echo "$SESSIONS_WITH_TRANSCRIPTION" | grep -c "users/" || echo "0")
DIAR_COUNT=$(echo "$SESSIONS_WITH_DIARIZATION" | grep -c "users/" || echo "0")
MISSING_COUNT=$(echo "$MISSING_DIARIZATION" | grep -c "users/" || echo "0")

SCAN_END=$(date +%s)
SCAN_DURATION=$((SCAN_END - SCAN_START))

# ============================================================================
# Report Results
# ============================================================================

log_info "==================================================================="
if [ "$MISSING_COUNT" -eq 0 ]; then
    log_success "SCAN COMPLETE - NO MISSING DIARIZATION"
else
    log_success "SCAN COMPLETE - FOUND $MISSING_COUNT SESSIONS NEEDING DIARIZATION"
fi
log_info "==================================================================="
echo ""
log_info "Scan Summary:"
log_info "  - Sessions with transcription: $TRANS_COUNT"
log_info "  - Sessions with diarization: $DIAR_COUNT"
log_info "  - Sessions needing diarization: $MISSING_COUNT"
log_info "  - Scan duration: ${SCAN_DURATION}s"
echo ""

if [ "$LIST_SESSIONS" = true ] && [ "$MISSING_COUNT" -gt 0 ]; then
    log_info "Sessions needing diarization:"
    echo "$MISSING_DIARIZATION" | while read -r session; do
        if [ -n "$session" ]; then
            echo "  - $session"
        fi
    done
    echo ""
fi

if [ "$MISSING_COUNT" -gt 0 ]; then
    log_info "Next Steps:"
    log_info "  1. Run diarization: python3 scripts/520-diarize-transcripts.py"
    log_info "  2. Or wait for automatic cron job"
    log_info "  3. Dry-run: python3 scripts/520-diarize-transcripts.py --dry-run"
fi
echo ""

# Output count for script chaining
echo "$MISSING_COUNT"
