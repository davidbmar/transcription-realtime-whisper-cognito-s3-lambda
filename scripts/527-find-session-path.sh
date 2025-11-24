#!/bin/bash
set -euo pipefail

# ============================================================================
# Script 527: Find and Analyze Sessions (Interactive)
# ============================================================================
# Interactive helper to list sessions, find paths, and optionally run AI analysis
#
# Usage:
#   ./scripts/527-find-session-path.sh                    # Interactive mode - list all
#   ./scripts/527-find-session-path.sh <search>           # Search and select
#   ./scripts/527-find-session-path.sh --all-analyze      # Analyze ALL sessions
#
# Examples:
#   ./scripts/527-find-session-path.sh                    # Show all sessions, pick one
#   ./scripts/527-find-session-path.sh upload             # Filter by "upload"
#   ./scripts/527-find-session-path.sh 20251122           # Filter by date
#   ./scripts/527-find-session-path.sh --all-analyze      # Batch analyze all
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

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

SEARCH_TERM="${1:-}"
BATCH_MODE=false

if [ "$SEARCH_TERM" = "--all-analyze" ]; then
    BATCH_MODE=true
    SEARCH_TERM=""
fi

echo ""
log_info "==================================================================="
log_info "Session Finder & AI Analyzer"
log_info "==================================================================="
echo ""

# Collect all sessions with metadata
declare -a SESSION_PATHS=()
declare -a SESSION_NAMES=()
declare -a SESSION_STATUSES=()
declare -a SESSION_AI_STATUSES=()

log_info "Scanning for sessions..."
echo ""

# Get all users
USERS=$(aws s3 ls s3://$COGNITO_S3_BUCKET/users/ 2>/dev/null | grep "PRE" | awk '{print $2}' | sed 's|/$||' || true)

if [ -z "$USERS" ]; then
    log_error "No users found in S3 bucket"
    exit 1
fi

for USER_ID in $USERS; do
    # List sessions for this user
    SESSIONS=$(aws s3 ls s3://$COGNITO_S3_BUCKET/users/$USER_ID/audio/sessions/ 2>/dev/null | grep "PRE" | awk '{print $2}' | sed 's|/$||' || true)

    if [ -z "$SESSIONS" ]; then
        continue
    fi

    while IFS= read -r SESSION_FOLDER; do
        # Apply search filter if provided
        if [ -n "$SEARCH_TERM" ]; then
            if ! echo "$SESSION_FOLDER" | grep -qi "$SEARCH_TERM"; then
                continue
            fi
        fi

        FULL_PATH="users/$USER_ID/audio/sessions/$SESSION_FOLDER"

        # Check if it has transcription
        HAS_TRANSCRIPT=$(aws s3 ls s3://$COGNITO_S3_BUCKET/$FULL_PATH/ 2>/dev/null | grep -E "(transcription-chunk|transcription-processed)" | wc -l)

        # Check if it has AI analysis
        HAS_ANALYSIS=$(aws s3 ls s3://$COGNITO_S3_BUCKET/$FULL_PATH/ 2>/dev/null | grep "transcription-ai-analysis.json" | wc -l)

        # Only include sessions with transcripts
        if [ "$HAS_TRANSCRIPT" -gt 0 ]; then
            SESSION_PATHS+=("$FULL_PATH")
            SESSION_NAMES+=("$SESSION_FOLDER")

            if [ "$HAS_ANALYSIS" -gt 0 ]; then
                SESSION_AI_STATUSES+=("yes")
                SESSION_STATUSES+=("✓ Transcribed + AI")
            else
                SESSION_AI_STATUSES+=("no")
                SESSION_STATUSES+=("✓ Transcribed")
            fi
        fi
    done <<< "$SESSIONS"
done

# Check if we found any sessions
if [ ${#SESSION_PATHS[@]} -eq 0 ]; then
    log_error "No sessions found"
    if [ -n "$SEARCH_TERM" ]; then
        echo ""
        log_info "Try searching without a filter:"
        log_info "  ./scripts/527-find-session-path.sh"
    fi
    exit 1
fi

log_success "Found ${#SESSION_PATHS[@]} session(s) with transcripts"
echo ""

# ============================================================================
# BATCH MODE: Analyze all sessions
# ============================================================================

if [ "$BATCH_MODE" = true ]; then
    log_info "==================================================================="
    log_info "BATCH MODE: Analyzing ALL sessions"
    log_info "==================================================================="
    echo ""

    ANALYZED=0
    SKIPPED=0
    FAILED=0

    for i in "${!SESSION_PATHS[@]}"; do
        SESSION_PATH="${SESSION_PATHS[$i]}"
        SESSION_NAME="${SESSION_NAMES[$i]}"
        HAS_AI="${SESSION_AI_STATUSES[$i]}"

        if [ "$HAS_AI" = "yes" ]; then
            echo -e "${YELLOW}⊘${NC} Skipping (already analyzed): ${SESSION_NAME}"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi

        echo ""
        log_info "Analyzing [$((i + 1))/${#SESSION_PATHS[@]}]: $SESSION_NAME"

        if ./scripts/525-generate-ai-analysis.sh --session-path "$SESSION_PATH"; then
            ANALYZED=$((ANALYZED + 1))
        else
            log_error "Failed to analyze: $SESSION_NAME"
            FAILED=$((FAILED + 1))
        fi
    done

    echo ""
    log_info "==================================================================="
    log_success "Batch Analysis Complete"
    log_info "==================================================================="
    echo ""
    log_info "Summary:"
    log_info "  Analyzed: $ANALYZED"
    log_info "  Skipped (already had AI): $SKIPPED"
    log_info "  Failed: $FAILED"
    echo ""

    exit 0
fi

# ============================================================================
# INTERACTIVE MODE: Let user select a session
# ============================================================================

echo -e "${CYAN}${BOLD}Available Sessions:${NC}"
echo ""

for i in "${!SESSION_PATHS[@]}"; do
    NUM=$((i + 1))
    SESSION_NAME="${SESSION_NAMES[$i]}"
    STATUS="${SESSION_STATUSES[$i]}"

    # Color code the status
    if [[ "$STATUS" == *"AI"* ]]; then
        STATUS_COLOR="${GREEN}✓ Has AI Analysis${NC}"
    else
        STATUS_COLOR="${YELLOW}○ No AI Analysis${NC}"
    fi

    echo -e "  ${BOLD}[$NUM]${NC} $SESSION_NAME"
    echo -e "      Status: $STATUS_COLOR"
done

echo ""
echo -e "${CYAN}Options:${NC}"
echo "  Enter a number (1-${#SESSION_PATHS[@]}) to select a session"
echo "  Enter 'a' to analyze ALL sessions without AI analysis"
echo "  Enter 'q' to quit"
echo ""
read -p "Your choice: " CHOICE

if [ "$CHOICE" = "q" ] || [ "$CHOICE" = "Q" ]; then
    echo "Cancelled."
    exit 0
fi

if [ "$CHOICE" = "a" ] || [ "$CHOICE" = "A" ]; then
    # Analyze all that don't have AI
    log_info "Analyzing all sessions without AI analysis..."
    echo ""

    ANALYZED=0
    for i in "${!SESSION_PATHS[@]}"; do
        HAS_AI="${SESSION_AI_STATUSES[$i]}"
        if [ "$HAS_AI" = "no" ]; then
            SESSION_PATH="${SESSION_PATHS[$i]}"
            SESSION_NAME="${SESSION_NAMES[$i]}"

            log_info "Analyzing: $SESSION_NAME"
            if ./scripts/525-generate-ai-analysis.sh --session-path "$SESSION_PATH"; then
                ANALYZED=$((ANALYZED + 1))
            fi
        fi
    done

    echo ""
    log_success "Analyzed $ANALYZED session(s)"
    exit 0
fi

# Validate numeric input
if ! [[ "$CHOICE" =~ ^[0-9]+$ ]]; then
    log_error "Invalid choice. Please enter a number."
    exit 1
fi

if [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt ${#SESSION_PATHS[@]} ]; then
    log_error "Invalid choice. Please enter a number between 1 and ${#SESSION_PATHS[@]}."
    exit 1
fi

# Get selected session (array is 0-indexed)
INDEX=$((CHOICE - 1))
SELECTED_PATH="${SESSION_PATHS[$INDEX]}"
SELECTED_NAME="${SESSION_NAMES[$INDEX]}"
SELECTED_HAS_AI="${SESSION_AI_STATUSES[$INDEX]}"

echo ""
log_info "==================================================================="
log_info "Selected Session"
log_info "==================================================================="
echo ""
echo -e "${BOLD}Name:${NC} $SELECTED_NAME"
echo -e "${BOLD}Path:${NC} $SELECTED_PATH"
echo ""

if [ "$SELECTED_HAS_AI" = "yes" ]; then
    echo -e "${GREEN}✓ This session already has AI analysis${NC}"
    echo ""
    read -p "Re-analyze anyway? (y/N): " REANALYZE

    if [ "$REANALYZE" != "y" ] && [ "$REANALYZE" != "Y" ]; then
        echo "Cancelled."
        exit 0
    fi

    FORCE_FLAG="--force"
else
    echo -e "${YELLOW}○ This session needs AI analysis${NC}"
    FORCE_FLAG=""
fi

echo ""
read -p "Run AI analysis now? (Y/n): " RUN_ANALYSIS

if [ "$RUN_ANALYSIS" = "n" ] || [ "$RUN_ANALYSIS" = "N" ]; then
    echo ""
    log_info "To analyze later, run:"
    echo ""
    echo -e "  ${BLUE}./scripts/525-generate-ai-analysis.sh --session-path $SELECTED_PATH${NC}"
    echo ""
    exit 0
fi

# Run the analysis
echo ""
log_info "Running AI analysis..."
echo ""

./scripts/525-generate-ai-analysis.sh --session-path "$SELECTED_PATH" $FORCE_FLAG
