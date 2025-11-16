#!/bin/bash
#
# Quick helper to download the most recent file from CloudDrive
#
# Usage: ./get-latest.sh [folder]
#
# Examples:
#   ./get-latest.sh           # Get latest file from anywhere
#   ./get-latest.sh images    # Get latest from images folder
#   ./get-latest.sh           # Get latest screenshot

set -euo pipefail

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DOWNLOAD_DIR="$PROJECT_ROOT/clouddrive-downloads"

# Load environment
if [[ -f "$PROJECT_ROOT/.env" ]]; then
    source "$PROJECT_ROOT/.env"
fi

# Configuration
BUCKET="${COGNITO_S3_BUCKET}"
REGION="${AWS_REGION}"
USER_ID="512b3590-30b1-707d-ed46-bf68df7b52d5"  # Hardcode for speed

# Folder filter (optional)
FOLDER="${1:-}"

# Build S3 path
if [[ -n "$FOLDER" ]]; then
    S3_PATH="s3://$BUCKET/users/$USER_ID/$FOLDER/"
else
    S3_PATH="s3://$BUCKET/users/$USER_ID/"
fi

echo "Finding latest file in: $S3_PATH"

# Get latest file (sorted by modification time, newest first)
LATEST=$(aws s3 ls "$S3_PATH" --recursive --region "$REGION" 2>/dev/null | \
    grep -v '\.folder$' | \
    sort -k1,2 -r | \
    head -1 | \
    awk '{for(i=4;i<=NF;i++) printf "%s%s", $i, (i<NF?" ":""); print ""}')

if [[ -z "$LATEST" ]]; then
    echo "No files found!"
    exit 1
fi

echo "Latest file: $LATEST"

# Download it
S3_KEY="$LATEST"
CLEAN_PATH="${S3_KEY#users/$USER_ID/}"
OUTPUT_PATH="$DOWNLOAD_DIR/$CLEAN_PATH"

mkdir -p "$(dirname "$OUTPUT_PATH")"

if aws s3 cp "s3://$BUCKET/$S3_KEY" "$OUTPUT_PATH" --region "$REGION" 2>&1; then
    SIZE=$(du -h "$OUTPUT_PATH" | cut -f1)
    echo "✓ Downloaded: $OUTPUT_PATH ($SIZE)"

    # Auto-display if it's an image
    if [[ "$OUTPUT_PATH" =~ \.(png|jpg|jpeg|gif)$ ]]; then
        echo ""
        echo "IMAGE READY TO VIEW:"
        echo "$OUTPUT_PATH"
    fi
else
    echo "✗ Download failed"
    exit 1
fi
