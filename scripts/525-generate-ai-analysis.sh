#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Script 525: Generate AI Analysis for Transcripts
# ============================================================================
# Analyzes CloudDrive transcripts using Claude API to extract structured
# insights including action items, key terms, themes, topic changes, and
# highlights for intelligent video navigation.
#
# What this does:
# 1. Validates ANTHROPIC_API_KEY is configured in .env
# 2. Activates Python virtual environment
# 3. Calls Python script to analyze transcript via Claude API
# 4. Saves analysis to S3 (both standalone and merged with transcript)
# 5. Reports token usage and estimated cost
#
# Requirements:
# - .env variables: ANTHROPIC_API_KEY, AWS_REGION, COGNITO_S3_BUCKET
# - Virtual environment: venv-ai-analysis (created automatically if needed)
# - Session path argument
#
# Total time: ~10-30 seconds per transcript (depends on length)
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
echo "525: Generate AI Analysis for Transcripts"
echo "============================================"
echo ""

# ============================================================================
# Configuration Validation
# ============================================================================

log_info "Validating configuration..."

# Check for ANTHROPIC_API_KEY
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    log_error "ANTHROPIC_API_KEY not set in .env"
    log_error ""
    log_error "To get your API key:"
    log_error "  1. Visit https://console.anthropic.com/settings/keys"
    log_error "  2. Create a new API key"
    log_error "  3. Add to .env: ANTHROPIC_API_KEY=your-key-here"
    log_error ""
    exit 1
fi

# Check AWS configuration
if [ -z "${AWS_REGION:-}" ]; then
    log_error "AWS_REGION not set in .env"
    exit 1
fi

if [ -z "${COGNITO_S3_BUCKET:-}" ]; then
    log_error "COGNITO_S3_BUCKET not set in .env"
    exit 1
fi

log_success "Configuration validated"
echo ""

# ============================================================================
# Virtual Environment Setup
# ============================================================================

VENV_DIR="$PROJECT_ROOT/venv-ai-analysis"

if [ ! -d "$VENV_DIR" ]; then
    log_info "Virtual environment not found, creating..."
    python3 -m venv "$VENV_DIR"

    log_info "Installing required packages..."
    source "$VENV_DIR/bin/activate"
    pip install --quiet anthropic python-dotenv boto3
    deactivate

    log_success "Virtual environment created and configured"
    echo ""
else
    log_info "Using existing virtual environment: $VENV_DIR"
fi

# ============================================================================
# Usage Instructions
# ============================================================================

if [ $# -eq 0 ]; then
    log_error "No session path provided"
    echo ""
    echo "Usage:"
    echo "  $0 --session-path <S3_PATH>"
    echo ""
    echo "Example:"
    echo "  $0 --session-path users/abc123/audio/sessions/session_2025-11-24T10_30_00_000Z"
    echo ""
    echo "Optional flags:"
    echo "  --force    Re-analyze even if analysis already exists"
    echo ""
    echo "To analyze all sessions, use a loop:"
    echo "  for session in \$(aws s3 ls s3://\$COGNITO_S3_BUCKET/users/USER_ID/audio/sessions/ | awk '{print \$2}' | sed 's|/||'); do"
    echo "    $0 --session-path users/USER_ID/audio/sessions/\$session"
    echo "  done"
    echo ""
    exit 1
fi

# ============================================================================
# Main Execution
# ============================================================================

log_info "This script will:"
log_info "  1. Load transcript from S3"
log_info "  2. Send to Claude API for analysis"
log_info "  3. Extract action items, key terms, themes, topic changes, highlights"
log_info "  4. Save analysis back to S3"
log_info "  5. Create enhanced transcript (original + AI analysis)"
echo ""

# Update status
update_env_status "AI_ANALYSIS_STATUS" "running"

# Activate virtual environment and run Python script
log_info "Running AI analysis..."
source "$VENV_DIR/bin/activate"

# Run the Python script with all arguments passed through
python3 "$PROJECT_ROOT/scripts/lib/ai-analysis.py" "$@"
RESULT=$?

deactivate

# ============================================================================
# Success Reporting
# ============================================================================

echo ""
if [ $RESULT -eq 0 ]; then
    update_env_status "AI_ANALYSIS_STATUS" "completed"

    log_info "==================================================================="
    log_success "✅ AI ANALYSIS COMPLETED"
    log_info "==================================================================="
    echo ""
    log_info "Generated files in S3:"
    log_info "  - transcription-ai-analysis.json    (standalone analysis)"
    log_info "  - transcription-enhanced.json       (original + AI analysis)"
    echo ""
    log_info "Next Steps:"
    log_info "  1. View analysis in transcript editor (opens automatically with timeline)"
    log_info "  2. Or analyze more sessions with this script"
    log_info "  3. Or batch process all: ./scripts/521-batch-analyze-all.sh"
    echo ""
else
    update_env_status "AI_ANALYSIS_STATUS" "failed"

    log_error "==================================================================="
    log_error "❌ AI ANALYSIS FAILED"
    log_error "==================================================================="
    echo ""
    log_error "Check the error messages above for details"
    echo ""
    exit 1
fi
