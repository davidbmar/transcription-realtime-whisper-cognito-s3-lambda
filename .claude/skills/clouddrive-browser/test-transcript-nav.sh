#!/bin/bash
#
# Test CloudDrive Transcript Editor navigation flow
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Testing CloudDrive Transcript Editor navigation..."
echo ""

node "$SCRIPT_DIR/test-transcript-nav.js"
