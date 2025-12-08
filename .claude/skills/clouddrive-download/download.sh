#!/bin/bash
#
# CloudDrive File Downloader - Efficient Direct S3 Access
# Downloads files from CloudDrive S3 using AWS CLI with IAM credentials
#
# Usage: ./download.sh <search-pattern>
#
# Examples:
#   ./download.sh "Screenshot"           # Find and download screenshots
#   ./download.sh "2025-11-16"           # Files with date in name
#   ./download.sh "*.png"                # All PNG files

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DOWNLOAD_DIR="/tmp/clouddrive-images"

# Load environment
if [[ -f "$PROJECT_ROOT/.env" ]]; then
    source "$PROJECT_ROOT/.env"
fi

# Configuration
BUCKET="${COGNITO_S3_BUCKET}"
REGION="${AWS_REGION}"
USER_ID="017bf540-7071-7065-c0ac-6f0a40f4c031"

# Validate environment
if [[ -z "$BUCKET" ]] || [[ -z "$REGION" ]]; then
    echo -e "${RED}ERROR: Missing COGNITO_S3_BUCKET or AWS_REGION in .env${NC}"
    exit 1
fi

# Create download directory
mkdir -p "$DOWNLOAD_DIR"

# Download file using --include pattern (handles spaces better)
download_with_pattern() {
    local pattern="$1"
    local folder="${2:-images}"

    echo -e "${BLUE}Downloading files matching: *$pattern*${NC}"

    local result=$(aws s3 cp \
        "s3://$BUCKET/users/$USER_ID/$folder/" \
        "$DOWNLOAD_DIR/" \
        --recursive \
        --exclude "*" \
        --include "*$pattern*" \
        --region "$REGION" 2>&1)

    if [[ -z "$result" ]] || [[ "$result" == *"warning: Skipping"* && ! "$result" == *"download:"* ]]; then
        echo -e "${RED}No files found matching: $pattern${NC}"
        return 1
    fi

    echo "$result"
    echo -e "${GREEN}Download complete!${NC}"
    echo -e "${BLUE}Files saved to: $DOWNLOAD_DIR${NC}"
}

# List recent files in images folder
list_recent_images() {
    echo -e "${BLUE}Recent images in CloudDrive:${NC}"
    aws s3 ls "s3://$BUCKET/users/$USER_ID/images/" --region "$REGION" 2>/dev/null | \
        grep -v '\.folder$' | \
        tail -20 | \
        awk '{print $1, $2, $4}'
}

# Main
main() {
    # Handle --list option
    if [[ "${1:-}" == "--list" ]]; then
        list_recent_images
        exit 0
    fi

    if [[ $# -lt 1 ]]; then
        echo "Usage: $0 <search-pattern>"
        echo "   or: $0 --list"
        echo ""
        echo "Examples:"
        echo "  $0 '10.49'                    # Download screenshot with 10.49 in name"
        echo "  $0 'Screenshot 2025-12-07'    # Download specific screenshot"
        echo "  $0 --list                      # List recent images"
        exit 1
    fi

    local pattern="$1"
    download_with_pattern "$pattern"

    # Show downloaded files
    echo ""
    echo -e "${BLUE}Downloaded files:${NC}"
    ls -la "$DOWNLOAD_DIR"/*"$pattern"* 2>/dev/null || true
}

main "$@"
