#!/bin/bash
#
# Run full CloudDrive workflow test
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Running CloudDrive workflow test..."
echo "This will: login -> upload test file -> verify in list"
echo ""

# Allow running in headed mode
if [[ "$1" == "--headed" ]]; then
    export HEADLESS=false
    echo "Running in headed mode (browser visible)"
    echo ""
fi

node "$SCRIPT_DIR/browser-test.js" test-workflow
