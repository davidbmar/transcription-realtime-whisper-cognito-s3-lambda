#!/bin/bash
#
# Test script: View transcript editor in CloudDrive
# Usage: ./test-transcript-editor.sh [session-id]
#
# Example: ./test-transcript-editor.sh session_2025-11-16T00_41_57_868Z
#

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Ensure dependencies installed
if [ ! -d "node_modules" ]; then
    echo "Installing dependencies..."
    npm install
fi

# Run test with session ID argument
SESSION_ID="${1:-session_2025-11-16T00_41_57_868Z}"

echo "Opening transcript editor for session: $SESSION_ID"
node test-transcript-editor.js "$SESSION_ID"
