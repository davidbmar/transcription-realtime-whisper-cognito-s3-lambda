#!/bin/bash
#
# Test CloudDrive login via browser automation
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Testing CloudDrive login..."
echo ""

node "$SCRIPT_DIR/browser-test.js" login
