#!/bin/bash
# Google Docs Edit Skill Runner
#
# This script loads credentials from .env and never hardcodes secrets.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

cd "$SCRIPT_DIR"

# Load .env if it exists (makes GOOGLE_CREDENTIALS_PATH and GOOGLE_DOC_ID available)
if [ -f "$REPO_ROOT/.env" ]; then
    # Export variables from .env
    set -a
    source "$REPO_ROOT/.env"
    set +a
fi

# Check credentials path from env or use default
CREDS_PATH="${GOOGLE_CREDENTIALS_PATH:-$REPO_ROOT/google-docs-test/credentials.json}"

if [ ! -f "$CREDS_PATH" ]; then
    echo "❌ ERROR: Google Cloud credentials not found"
    echo ""
    echo "Checked: $CREDS_PATH"
    echo ""
    echo "Setup required:"
    echo "  1. Create credentials.json (see google-docs-test/README.md)"
    echo "  2. Save to: $REPO_ROOT/google-docs-test/credentials.json"
    echo "  OR set GOOGLE_CREDENTIALS_PATH in .env"
    exit 1
fi

# Export for Python script
export GOOGLE_CREDENTIALS_PATH="$CREDS_PATH"

# Run the Python script (doc ID can come from args or GOOGLE_DOC_ID env var)
python3 edit-doc.py "$@"
