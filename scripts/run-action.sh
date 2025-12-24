#!/bin/bash
# ============================================================================
# run-action.sh - Universal CloudDrive Action Runner
# ============================================================================
#
# Runs actions from the actions/ directory using the standard interface.
#
# Usage:
#   ./scripts/run-action.sh --list                              # List available actions
#   ./scripts/run-action.sh ai-analysis --session <path>        # Run AI analysis
#   ./scripts/run-action.sh topics --session <path>             # Run topic detection
#   ./scripts/run-action.sh <action> --session <path> -p key=value
#
# Examples:
#   ./scripts/run-action.sh --list
#   ./scripts/run-action.sh ai-analysis -s users/123/audio/sessions/abc
#   ./scripts/run-action.sh topics -s users/123/audio/sessions/abc -p threshold=0.25
#   ./scripts/run-action.sh ai-analysis -s users/123/audio/sessions/abc -p force=true
#
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load environment
source "$PROJECT_ROOT/.env"

# Activate virtual environment if exists (for anthropic, boto3, etc.)
if [ -d "$PROJECT_ROOT/venv-ai-analysis" ]; then
    source "$PROJECT_ROOT/venv-ai-analysis/bin/activate"
fi

# Run action
cd "$PROJECT_ROOT"
python3 -m actions.run_action "$@"
