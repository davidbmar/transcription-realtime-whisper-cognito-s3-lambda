#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Script 520: Cleanup Corrupted Audio Sessions
# ============================================================================
# This script:
# 1. Scans S3 for corrupted audio chunks (< 1KB = header-only files)
# 2. Deletes ALL audio sessions (fresh start after implementing corruption fixes)
# 3. Preserves all other S3 content (CloudFront assets, user files, etc.)
#
# What gets deleted:
# - users/{userId}/audio/sessions/* (all recording sessions)
#
# What gets preserved:
# - CloudFront static assets (HTML, JS, CSS)
# - users/{userId}/[other files] (uploaded documents, etc.)
# - claude-memory/*
# - All other S3 content
#
# Requirements:
# - .env variables: COGNITO_S3_BUCKET
# - AWS CLI with S3 permissions
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
echo "520: Cleanup Corrupted Audio Sessions"
echo "============================================"
echo ""

log_warn "⚠️  WARNING: This script will DELETE ALL audio sessions!"
echo ""
log_info "What will be deleted:"
log_info "  - All files under users/{userId}/audio/sessions/"
log_info "  - All recording session data"
echo ""
log_info "What will be preserved:"
log_info "  - CloudFront static assets"
log_info "  - User-uploaded files (outside audio/sessions)"
log_info "  - Claude memory files"
log_info "  - All other S3 content"
echo ""

# Confirmation prompt
read -p "Are you sure you want to proceed? (yes/no): " -r
echo ""
if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    log_info "Cleanup cancelled by user"
    exit 0
fi

S3_BUCKET="${COGNITO_S3_BUCKET}"

# ============================================================================
# Step 1: Scan for Corrupted Chunks
# ============================================================================

log_info "Step 1: Scanning for corrupted audio chunks (< 1KB)..."
echo ""

CORRUPTED_FILE="/tmp/corrupted-chunks-$$.txt"
> "$CORRUPTED_FILE"

CORRUPTED_COUNT=0

# Find all .webm chunk files and check their size
aws s3 ls "s3://$S3_BUCKET/users/" --recursive | \
    grep -E 'chunk-[0-9]+\.webm$' | \
    while read -r date time size file; do
        # Check if file is smaller than 1KB (1000 bytes)
        if [ "$size" -lt 1000 ]; then
            echo "$file" >> "$CORRUPTED_FILE"
            CORRUPTED_COUNT=$((CORRUPTED_COUNT + 1))
            log_warn "  Found corrupted chunk (${size} bytes): $file"
        fi
    done

# Count corrupted files
if [ -f "$CORRUPTED_FILE" ]; then
    CORRUPTED_COUNT=$(wc -l < "$CORRUPTED_FILE")
fi

if [ "$CORRUPTED_COUNT" -eq 0 ]; then
    log_success "No corrupted chunks found!"
else
    log_warn "Found $CORRUPTED_COUNT corrupted chunks"
fi
echo ""

# ============================================================================
# Step 2: Count Sessions to Delete
# ============================================================================

log_info "Step 2: Counting audio sessions..."
echo ""

# Count session directories
SESSION_PATHS=$(aws s3 ls "s3://$S3_BUCKET/users/" --recursive | \
    grep -E '/audio/sessions/.*-session_' | \
    awk '{print $4}' | \
    sed 's|/.*||' | \
    sed 's|users/||' | \
    cut -d'/' -f1 | \
    sort -u)

USER_COUNT=$(echo "$SESSION_PATHS" | grep -c . || echo "0")

if [ "$USER_COUNT" -eq 0 ]; then
    log_info "No audio sessions found to delete"
    rm -f "$CORRUPTED_FILE"
    exit 0
fi

# Count total session files
TOTAL_FILES=$(aws s3 ls "s3://$S3_BUCKET/users/" --recursive | \
    grep -E '/audio/sessions/' | \
    wc -l)

log_info "Found:"
log_info "  - $USER_COUNT user(s) with audio sessions"
log_info "  - $TOTAL_FILES total files in audio/sessions/"
echo ""

# ============================================================================
# Step 3: Delete All Audio Sessions
# ============================================================================

log_info "Step 3: Deleting all audio sessions..."
echo ""

DELETED_COUNT=0

# Get all unique user IDs with audio sessions
for USER_ID in $SESSION_PATHS; do
    USER_SESSION_PATH="users/$USER_ID/audio/sessions/"

    log_info "  Deleting sessions for user: $USER_ID"

    # Delete entire audio/sessions/ directory for this user
    aws s3 rm "s3://$S3_BUCKET/$USER_SESSION_PATH" --recursive 2>&1 | grep -v "^delete:" || true

    DELETED_COUNT=$((DELETED_COUNT + 1))

    log_success "  ✓ Deleted sessions for user $USER_ID"
done

echo ""
log_success "Deleted audio sessions for $DELETED_COUNT user(s)"
echo ""

# ============================================================================
# Step 4: Verify Cleanup
# ============================================================================

log_info "Step 4: Verifying cleanup..."
echo ""

# Check that audio/sessions/ directories are gone
REMAINING_FILES=$(aws s3 ls "s3://$S3_BUCKET/users/" --recursive | \
    grep -E '/audio/sessions/' | \
    wc -l || echo "0")

if [ "$REMAINING_FILES" -eq 0 ]; then
    log_success "✓ All audio session files deleted"
else
    log_warn "⚠️  $REMAINING_FILES files still remain under audio/sessions/"
fi

# Verify other content is preserved
OTHER_FILES=$(aws s3 ls "s3://$S3_BUCKET/users/" --recursive | \
    grep -v '/audio/sessions/' | \
    wc -l || echo "0")

log_info "✓ Preserved $OTHER_FILES other user files"

# Check static assets
STATIC_FILES=$(aws s3 ls "s3://$S3_BUCKET/" | \
    grep -E '\.(html|js|css)$' | \
    wc -l || echo "0")

log_info "✓ Preserved $STATIC_FILES static assets"
echo ""

# ============================================================================
# Step 5: Generate Cleanup Report
# ============================================================================

REPORT_DIR="$PROJECT_ROOT/cleanup-reports"
mkdir -p "$REPORT_DIR"
REPORT_FILE="$REPORT_DIR/cleanup-$(date +%Y-%m-%d-%H%M).json"

cat > "$REPORT_FILE" <<EOF
{
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "bucket": "$S3_BUCKET",
  "corruptedChunks": {
    "found": $CORRUPTED_COUNT,
    "deleted": $CORRUPTED_COUNT
  },
  "sessions": {
    "usersAffected": $USER_COUNT,
    "totalFilesDeleted": $TOTAL_FILES,
    "remainingFiles": $REMAINING_FILES
  },
  "preserved": {
    "userFiles": $OTHER_FILES,
    "staticAssets": $STATIC_FILES
  }
}
EOF

log_success "Cleanup report saved: $REPORT_FILE"
echo ""

# ============================================================================
# Success Summary
# ============================================================================

log_info "==================================================================="
log_success "✅ CLEANUP COMPLETE"
log_info "==================================================================="
echo ""
log_info "Summary:"
log_info "  - Corrupted chunks found: $CORRUPTED_COUNT"
log_info "  - Users cleaned: $USER_COUNT"
log_info "  - Files deleted: $TOTAL_FILES"
log_info "  - Files preserved: $((OTHER_FILES + STATIC_FILES))"
echo ""
log_info "S3 Bucket Status:"
log_info "  - Audio sessions: DELETED (fresh start)"
log_info "  - User files: PRESERVED"
log_info "  - Static assets: PRESERVED"
echo ""
log_info "Next Steps:"
log_info "  1. Test new recording with wake lock protection"
log_info "  2. Verify no more corrupted chunks are created"
log_info "  3. Run batch transcription on new recordings"
echo ""
log_info "Report: $REPORT_FILE"
echo ""

# Cleanup temp file
rm -f "$CORRUPTED_FILE"
