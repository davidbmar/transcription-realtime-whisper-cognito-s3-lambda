#!/bin/bash
#
# CloudDrive File Downloader - Simple Version
# Downloads files from CloudDrive S3
#
# Usage: ./download-file.sh "filename"
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Load .env
if [[ -f "$PROJECT_ROOT/.env" ]]; then
    source "$PROJECT_ROOT/.env"
fi

BUCKET="${COGNITO_S3_BUCKET}"
REGION="${AWS_REGION}"
DOWNLOAD_DIR="$SCRIPT_DIR/downloads"

# Get filename from argument
SEARCH_NAME="${1:-}"

if [[ -z "$SEARCH_NAME" ]]; then
    echo -e "${RED}Error:${NC} Please provide a filename to search for"
    echo "Usage: $0 'filename.png'"
    exit 1
fi

echo -e "${BLUE}Searching for:${NC} $SEARCH_NAME"
echo ""

# Create download directory
mkdir -p "$DOWNLOAD_DIR"

# Detect user ID
echo -e "${BLUE}Detecting user ID...${NC}"
USER_ID=$(aws s3 ls "s3://$BUCKET/users/" --region "$REGION" 2>/dev/null | grep PRE | awk '{print $2}' | tr -d '/' | head -1)

if [[ -z "$USER_ID" ]]; then
    echo -e "${RED}Error:${NC} Could not find user ID in bucket"
    exit 1
fi

echo -e "${GREEN}Found user ID:${NC} $USER_ID"
echo ""

# Search for file in user's directory
echo -e "${BLUE}Searching in S3...${NC}"
MATCHING_FILES=$(aws s3 ls "s3://$BUCKET/users/$USER_ID/" --recursive --region "$REGION" 2>/dev/null | grep -i "$SEARCH_NAME" || true)

if [[ -z "$MATCHING_FILES" ]]; then
    echo -e "${RED}No files found matching:${NC} $SEARCH_NAME"
    echo ""
    echo "Recent files in your S3 bucket:"
    aws s3 ls "s3://$BUCKET/users/$USER_ID/" --recursive --region "$REGION" 2>/dev/null | tail -10
    exit 1
fi

# Show matching files
echo -e "${GREEN}Found matching files:${NC}"
echo "$MATCHING_FILES" | while read -r line; do
    # Extract just the filename
    FILE_KEY=$(echo "$line" | awk '{for(i=4;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ $//')
    echo "  - $FILE_KEY"
done
echo ""

# Download each matching file
echo "$MATCHING_FILES" | while read -r line; do
    FILE_KEY=$(echo "$line" | awk '{for(i=4;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ $//')
    FILENAME=$(basename "$FILE_KEY")

    echo -e "${BLUE}Downloading:${NC} $FILENAME"

    if aws s3 cp "s3://$BUCKET/$FILE_KEY" "$DOWNLOAD_DIR/$FILENAME" --region "$REGION" 2>/dev/null; then
        echo -e "${GREEN}✓ Downloaded:${NC} $DOWNLOAD_DIR/$FILENAME"
    else
        echo -e "${RED}✗ Failed:${NC} $FILENAME"
    fi
done

echo ""
echo -e "${GREEN}Done!${NC} Files saved to: $DOWNLOAD_DIR"
ls -lh "$DOWNLOAD_DIR"
