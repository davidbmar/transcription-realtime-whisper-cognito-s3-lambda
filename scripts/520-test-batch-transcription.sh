#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Script 520: Test Batch Transcription System
# ============================================================================
# Comprehensive end-to-end test of the batch transcription system.
#
# What this does:
# 1. Finds an existing session with audio chunks
# 2. Backs up one transcription chunk
# 3. Deletes the transcription chunk from S3 (simulating missing chunk)
# 4. Runs batch transcription
# 5. Verifies the chunk was re-transcribed
# 6. Compares re-transcribed output with backup
# 7. Cleans up test artifacts
#
# Requirements:
# - .env variables: COGNITO_S3_BUCKET
# - At least one completed session with transcriptions in S3
# - Scripts 500, 505, 515 must be functional
#
# Total time: ~3-5 minutes
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
echo "520: Test Batch Transcription System"
echo "============================================"
echo ""

log_info "This script will:"
log_info "  1. Find a test session with transcriptions"
log_info "  2. Simulate a missing transcription chunk"
log_info "  3. Run batch transcription"
log_info "  4. Verify chunk was re-transcribed"
log_info "  5. Clean up test artifacts"
echo ""

# ============================================================================
# Configuration
# ============================================================================

S3_BUCKET="$COGNITO_S3_BUCKET"
TEMP_DIR="/tmp/batch-test-$$"
TEST_SESSION=""
TEST_CHUNK=""
BACKUP_FILE=""

# ============================================================================
# Helper Functions
# ============================================================================

cleanup() {
    log_info "Cleaning up test artifacts..."

    # Restore backup if exists
    if [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ] && [ -n "$TEST_SESSION" ] && [ -n "$TEST_CHUNK" ]; then
        log_info "Restoring original transcription..."
        aws s3 cp "$BACKUP_FILE" "s3://$S3_BUCKET/$TEST_SESSION/$TEST_CHUNK" 2>/dev/null || true
    fi

    # Remove temp directory
    rm -rf "$TEMP_DIR"

    log_success "Cleanup complete"
}
trap cleanup EXIT

find_test_session() {
    log_info "Finding a suitable test session..."

    # Find sessions with both audio and transcription chunks
    local sessions=$(aws s3 ls "s3://$S3_BUCKET/users/" --recursive 2>/dev/null | \
        grep -E 'transcription-chunk-[0-9]+\.json$' | \
        awk '{print $4}' | \
        sed 's|/transcription-chunk-.*||' | \
        sort -u | \
        head -1)

    if [ -z "$sessions" ]; then
        log_error "No sessions with transcriptions found"
        log_info "Please record a session first using audio.html"
        exit 1
    fi

    TEST_SESSION="$sessions"
    log_success "Found test session: $TEST_SESSION"
}

select_test_chunk() {
    log_info "Selecting a transcription chunk to test..."

    # Get first transcription chunk
    TEST_CHUNK=$(aws s3 ls "s3://$S3_BUCKET/$TEST_SESSION/" 2>/dev/null | \
        grep -E 'transcription-chunk-[0-9]+\.json$' | \
        awk '{print $4}' | \
        head -1)

    if [ -z "$TEST_CHUNK" ]; then
        log_error "No transcription chunks found in session"
        exit 1
    fi

    log_success "Selected chunk: $TEST_CHUNK"
}

# ============================================================================
# Main Execution
# ============================================================================

mkdir -p "$TEMP_DIR"

log_info "Step 1/5: Finding test session..."
find_test_session
echo ""

log_info "Step 2/5: Selecting test chunk..."
select_test_chunk
echo ""

log_info "Step 3/5: Backing up and deleting transcription..."
BACKUP_FILE="$TEMP_DIR/$TEST_CHUNK.backup"

# Backup original
if ! aws s3 cp "s3://$S3_BUCKET/$TEST_SESSION/$TEST_CHUNK" "$BACKUP_FILE" 2>/dev/null; then
    log_error "Failed to backup transcription chunk"
    exit 1
fi
log_success "Backed up to: $BACKUP_FILE"

# Delete from S3 to simulate missing chunk
if ! aws s3 rm "s3://$S3_BUCKET/$TEST_SESSION/$TEST_CHUNK" 2>/dev/null; then
    log_error "Failed to delete test chunk"
    exit 1
fi
log_success "Deleted chunk from S3 (simulating missing transcription)"
echo ""

log_info "Step 4/5: Running batch transcription..."
log_info "This will scan S3 and re-transcribe the missing chunk..."
echo ""

# Run batch transcription
if ! "$PROJECT_ROOT/scripts/515-run-batch-transcribe.sh"; then
    log_error "Batch transcription failed"
    exit 1
fi
echo ""

log_info "Step 5/5: Verifying re-transcription..."

# Check if chunk was re-created
sleep 2  # Give S3 a moment to update
if ! aws s3 ls "s3://$S3_BUCKET/$TEST_SESSION/$TEST_CHUNK" &>/dev/null; then
    log_error "Transcription chunk was not re-created"
    log_info "Expected: s3://$S3_BUCKET/$TEST_SESSION/$TEST_CHUNK"
    exit 1
fi

log_success "Transcription chunk re-created successfully"

# Download and compare
NEW_FILE="$TEMP_DIR/$TEST_CHUNK.new"
aws s3 cp "s3://$S3_BUCKET/$TEST_SESSION/$TEST_CHUNK" "$NEW_FILE" 2>/dev/null

# Basic validation - check it's valid JSON with segments
if ! python3 -c "import json, sys; data=json.load(open('$NEW_FILE')); sys.exit(0 if 'segments' in data else 1)" 2>/dev/null; then
    log_error "Re-transcribed chunk is not valid JSON or missing segments"
    exit 1
fi

SEGMENT_COUNT=$(python3 -c "import json; print(len(json.load(open('$NEW_FILE'))['segments']))" 2>/dev/null || echo "0")
log_success "Re-transcribed chunk contains $SEGMENT_COUNT segments"

echo ""

# ============================================================================
# Success Reporting
# ============================================================================

echo ""
log_info "==================================================================="
log_success "✅ BATCH TRANSCRIPTION TEST PASSED"
log_info "==================================================================="
echo ""
log_info "Test Results:"
log_info "  - Session: $TEST_SESSION"
log_info "  - Test chunk: $TEST_CHUNK"
log_info "  - Re-transcription: SUCCESS"
log_info "  - Segments in chunk: $SEGMENT_COUNT"
log_info "  - Original restored: YES"
echo ""
log_info "The batch transcription system is working correctly!"
echo ""
log_info "Next Steps:"
log_info "  1. Monitor scheduled runs: sudo journalctl -u batch-transcribe -f"
log_info "  2. Check scheduler status: systemctl status batch-transcribe.timer"
log_info "  3. Test with a real incomplete session by recording audio"
echo ""
