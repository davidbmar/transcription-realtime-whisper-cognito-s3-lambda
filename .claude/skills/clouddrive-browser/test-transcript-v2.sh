#!/bin/bash
# Test Transcript Editor V2

cd "$(dirname "$0")"

# Load environment
if [ -f "../../../.env" ]; then
    export $(grep -v '^#' ../../../.env | xargs)
fi

# Create screenshots directory
mkdir -p ../../../browser-screenshots

# Run test
node test-transcript-v2.js
