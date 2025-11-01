#!/bin/bash
#
# Test file upload to CloudDrive
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <file-path>"
    exit 1
fi

FILE_PATH="$1"

if [[ ! -f "$FILE_PATH" ]]; then
    echo "Error: File not found: $FILE_PATH"
    exit 1
fi

echo "Testing file upload..."
echo "File: $FILE_PATH"
echo ""

node "$SCRIPT_DIR/browser-test.js" upload "$FILE_PATH"
