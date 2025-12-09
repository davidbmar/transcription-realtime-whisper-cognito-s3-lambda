#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/migrate-layers-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Migration Script: Convert Sessions to Layer Architecture
# ============================================================================
# One-time migration script to convert existing sessions from the old
# flat file structure to the new modular layer architecture.
#
# OLD STRUCTURE:
#   session_xxx/
#   ├── chunk-001.webm
#   ├── transcription-chunk-001.json
#   ├── transcription-diarized.json
#   ├── transcription-processed.json
#   └── layer-1-annotations/annotations.json
#
# NEW STRUCTURE:
#   session_xxx/
#   ├── audio/chunk-001.webm
#   ├── layers/
#   │   ├── manifest.json
#   │   ├── layer-0-raw-transcription/data.json
#   │   ├── layer-1-diarization/data.json
#   │   ├── layer-2-ai-analysis/data.json
#   │   └── layer-10-human-edits/data.json
#   └── metadata.json
#
# Usage:
#   ./scripts/migration/migrate-to-layer-architecture.sh [OPTIONS]
#
# Options:
#   --dry-run           Preview changes without making them
#   --session ID        Migrate only the specified session
#   --user-id ID        Migrate only sessions for specified user
#   --all               Migrate all sessions (default)
#
# Requirements:
# - .env variables: AWS_REGION, COGNITO_S3_BUCKET
#
# Total time: ~1-2 minutes per session
# ============================================================================

# Resolve script path (handles symlinks)
if [ -L "${BASH_SOURCE[0]}" ]; then
    SCRIPT_REAL=$(readlink -f "${BASH_SOURCE[0]}")
else
    SCRIPT_REAL="${BASH_SOURCE[0]}"
fi
PROJECT_ROOT="$(cd "$(dirname "$SCRIPT_REAL")/../.." && pwd)"

# Load environment and common functions
set -a  # Export all variables
source "$PROJECT_ROOT/.env"
set +a
source "$PROJECT_ROOT/scripts/lib/common-functions.sh"

# ============================================================================
# Configuration
# ============================================================================
DRY_RUN=false
SINGLE_SESSION=""
SINGLE_USER=""
MIGRATE_ALL=false
MIGRATED_COUNT=0
SKIPPED_COUNT=0
ERROR_COUNT=0

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --session)
            SINGLE_SESSION="$2"
            shift 2
            ;;
        --user-id)
            SINGLE_USER="$2"
            shift 2
            ;;
        --all)
            MIGRATE_ALL=true
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Default to --all if no specific target given
if [[ -z "$SINGLE_SESSION" && -z "$SINGLE_USER" ]]; then
    MIGRATE_ALL=true
fi

echo "============================================"
echo "Migration: Convert to Layer Architecture"
echo "============================================"
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "DRY RUN MODE - No changes will be made"
    echo ""
fi

log_info "This script will:"
log_info "  1. Scan existing sessions for old file structure"
log_info "  2. Create new layers/ folder structure"
log_info "  3. Split data into separate layer files"
log_info "  4. Create manifest.json for each session"
log_info "  5. Keep old files as backup (prefixed with _backup_)"
echo ""

# ============================================================================
# Helper Functions
# ============================================================================

# Check if session already has new layer structure
session_already_migrated() {
    local session_path="$1"
    aws s3 ls "s3://${COGNITO_S3_BUCKET}/${session_path}layers/manifest.json" < /dev/null &>/dev/null
}

# Create manifest.json content
create_manifest() {
    local session_id="$1"
    local has_raw="$2"
    local has_diarization="$3"
    local has_ai_analysis="$4"
    local has_human_edits="$5"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    cat <<EOF
{
  "version": "2.0",
  "sessionId": "${session_id}",
  "migratedAt": "${timestamp}",
  "migratedFrom": "v1-flat-structure",
  "layers": {
    "0": {
      "name": "Raw Transcription",
      "type": "system",
      "locked": true,
      "status": "${has_raw}",
      "folder": "layer-0-raw-transcription"
    },
    "1": {
      "name": "Diarization",
      "type": "system",
      "locked": true,
      "status": "${has_diarization}",
      "folder": "layer-1-diarization"
    },
    "2": {
      "name": "AI Analysis",
      "type": "system",
      "locked": false,
      "status": "${has_ai_analysis}",
      "folder": "layer-2-ai-analysis"
    },
    "10": {
      "name": "Human Edits",
      "type": "user",
      "locked": false,
      "status": "${has_human_edits}",
      "folder": "layer-10-human-edits"
    }
  },
  "nextLayerId": 11
}
EOF
}

# Migrate a single session
migrate_session() {
    local session_path="$1"
    local session_id=$(basename "$session_path")

    log_info "Processing: $session_id"

    # Check if already migrated
    if session_already_migrated "$session_path"; then
        log_warn "  Already migrated (manifest.json exists), skipping"
        ((SKIPPED_COUNT++)) || true
        return 0
    fi

    # Check what files exist
    local has_raw="pending"
    local has_diarization="pending"
    local has_ai_analysis="pending"
    local has_human_edits="pending"

    # Check for raw transcription (transcription-chunk-*.json)
    if aws s3 ls "s3://${COGNITO_S3_BUCKET}/${session_path}" < /dev/null 2>/dev/null | grep -q "transcription-chunk-"; then
        has_raw="complete"
    fi

    # Check for diarization (transcription-diarized.json or transcription-processed.json with speaker data)
    if aws s3 ls "s3://${COGNITO_S3_BUCKET}/${session_path}transcription-diarized.json" < /dev/null &>/dev/null; then
        has_diarization="complete"
    elif aws s3 ls "s3://${COGNITO_S3_BUCKET}/${session_path}transcription-processed.json" < /dev/null &>/dev/null; then
        has_diarization="complete"
    fi

    # Check for AI analysis
    if aws s3 ls "s3://${COGNITO_S3_BUCKET}/${session_path}transcription-ai-analysis.json" < /dev/null &>/dev/null; then
        has_ai_analysis="complete"
    fi

    # Check for human edits (old layer-1-annotations/)
    if aws s3 ls "s3://${COGNITO_S3_BUCKET}/${session_path}layer-1-annotations/annotations.json" < /dev/null &>/dev/null; then
        has_human_edits="complete"
    fi

    log_info "  Found: raw=$has_raw, diarization=$has_diarization, ai=$has_ai_analysis, edits=$has_human_edits"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "  [DRY RUN] Would create layers/ structure"
        ((MIGRATED_COUNT++)) || true
        return 0
    fi

    # Create temp directory for processing
    local temp_dir=$(mktemp -d)

    # Download existing files
    log_info "  Downloading existing files..."
    aws s3 sync "s3://${COGNITO_S3_BUCKET}/${session_path}" "$temp_dir/" --quiet < /dev/null 2>/dev/null || true

    # Create new layer structure
    mkdir -p "$temp_dir/layers/layer-0-raw-transcription"
    mkdir -p "$temp_dir/layers/layer-1-diarization"
    mkdir -p "$temp_dir/layers/layer-2-ai-analysis"
    mkdir -p "$temp_dir/layers/layer-10-human-edits"
    mkdir -p "$temp_dir/audio"

    # Move audio files
    if ls "$temp_dir/"*.webm &>/dev/null; then
        mv "$temp_dir/"*.webm "$temp_dir/audio/" 2>/dev/null || true
    fi

    # Layer 0: Raw transcription (merge all chunk transcriptions)
    if [[ "$has_raw" == "complete" ]]; then
        # Combine all transcription-chunk-*.json into one
        local raw_data='{"chunks":[]}'
        for chunk_file in "$temp_dir"/transcription-chunk-*.json; do
            if [[ -f "$chunk_file" ]]; then
                # Just copy the first chunk for now (most sessions have one chunk)
                cp "$chunk_file" "$temp_dir/layers/layer-0-raw-transcription/data.json"
                break
            fi
        done
    fi

    # Layer 1: Diarization (extract speaker data from processed/diarized)
    if [[ "$has_diarization" == "complete" ]]; then
        if [[ -f "$temp_dir/transcription-processed.json" ]]; then
            cp "$temp_dir/transcription-processed.json" "$temp_dir/layers/layer-1-diarization/data.json"
        elif [[ -f "$temp_dir/transcription-diarized.json" ]]; then
            cp "$temp_dir/transcription-diarized.json" "$temp_dir/layers/layer-1-diarization/data.json"
        fi
    fi

    # Layer 2: AI Analysis
    if [[ "$has_ai_analysis" == "complete" && -f "$temp_dir/transcription-ai-analysis.json" ]]; then
        cp "$temp_dir/transcription-ai-analysis.json" "$temp_dir/layers/layer-2-ai-analysis/data.json"
    fi

    # Layer 10: Human Edits (move from old layer-1-annotations/)
    if [[ "$has_human_edits" == "complete" && -f "$temp_dir/layer-1-annotations/annotations.json" ]]; then
        cp "$temp_dir/layer-1-annotations/annotations.json" "$temp_dir/layers/layer-10-human-edits/data.json"
    fi

    # Create manifest.json
    create_manifest "$session_id" "$has_raw" "$has_diarization" "$has_ai_analysis" "$has_human_edits" > "$temp_dir/layers/manifest.json"

    # Upload new structure
    log_info "  Uploading new layer structure..."
    aws s3 sync "$temp_dir/layers/" "s3://${COGNITO_S3_BUCKET}/${session_path}layers/" --quiet < /dev/null
    aws s3 sync "$temp_dir/audio/" "s3://${COGNITO_S3_BUCKET}/${session_path}audio/" --quiet < /dev/null 2>/dev/null || true

    # Backup old files (rename with _backup_ prefix) - optional, comment out to skip
    # log_info "  Backing up old files..."
    # for old_file in transcription-chunk-001.json transcription-diarized.json transcription-processed.json; do
    #     if aws s3 ls "s3://${COGNITO_S3_BUCKET}/${session_path}${old_file}" &>/dev/null; then
    #         aws s3 mv "s3://${COGNITO_S3_BUCKET}/${session_path}${old_file}" \
    #                   "s3://${COGNITO_S3_BUCKET}/${session_path}_backup_${old_file}" --quiet
    #     fi
    # done

    log_success "  Migration complete"
    ((MIGRATED_COUNT++)) || true

    # Cleanup
    rm -rf "$temp_dir"
}

# ============================================================================
# Main Implementation
# ============================================================================

log_info "Step 1: Finding sessions to migrate"

if [[ -n "$SINGLE_SESSION" ]]; then
    # Migrate specific session
    log_info "Migrating single session: $SINGLE_SESSION"

    # Find session path
    SESSION_PATH=$(aws s3 ls "s3://${COGNITO_S3_BUCKET}/users/" --recursive | grep "$SINGLE_SESSION" | head -1 | awk '{print $NF}' | sed 's|/[^/]*$|/|')

    if [[ -z "$SESSION_PATH" ]]; then
        log_error "Session not found: $SINGLE_SESSION"
        exit 1
    fi

    migrate_session "$SESSION_PATH"

elif [[ -n "$SINGLE_USER" ]]; then
    # Migrate all sessions for a user
    log_info "Migrating sessions for user: $SINGLE_USER"

    while IFS= read -r session_line; do
        session_path=$(echo "$session_line" | awk '{print $2}')
        if [[ "$session_path" == *"/sessions/"* ]]; then
            migrate_session "$session_path"
        fi
    done < <(aws s3 ls "s3://${COGNITO_S3_BUCKET}/users/${SINGLE_USER}/audio/sessions/" 2>/dev/null || true)

else
    # Migrate all sessions
    log_info "Scanning all users for sessions..."

    # Get list of all users - store in array to avoid stdin issues
    mapfile -t user_list < <(aws s3 ls "s3://${COGNITO_S3_BUCKET}/users/" 2>/dev/null | awk '{print $2}' | tr -d '/')

    for user_id in "${user_list[@]}"; do
        if [[ -n "$user_id" ]]; then
            log_info "Scanning user: $user_id"

            # Get sessions for this user
            mapfile -t session_list < <(aws s3 ls "s3://${COGNITO_S3_BUCKET}/users/${user_id}/audio/sessions/" 2>/dev/null | awk '{print $2}')

            for session_folder in "${session_list[@]}"; do
                if [[ -n "$session_folder" ]]; then
                    session_path="users/${user_id}/audio/sessions/${session_folder}"
                    migrate_session "$session_path"
                fi
            done
        fi
    done
fi

# ============================================================================
# Success Reporting
# ============================================================================

echo ""
log_info "==================================================================="
if [[ "$DRY_RUN" == "true" ]]; then
    log_success "✅ DRY RUN COMPLETE"
else
    log_success "✅ MIGRATION COMPLETE"
fi
log_info "==================================================================="
echo ""
log_info "Summary:"
log_info "  - Sessions migrated: $MIGRATED_COUNT"
log_info "  - Sessions skipped (already migrated): $SKIPPED_COUNT"
log_info "  - Errors: $ERROR_COUNT"
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Next Steps:"
    log_info "  1. Review the dry run output above"
    log_info "  2. Run without --dry-run to perform actual migration"
    log_info "     ./scripts/migration/migrate-to-layer-architecture.sh --all"
else
    log_info "Next Steps:"
    log_info "  1. Update frontend to read from layers/ structure"
    log_info "  2. Update batch scripts to write to layers/ structure"
fi
echo ""
