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
DOWNLOAD_DIR="$PROJECT_ROOT/clouddrive-downloads"

# Load environment
if [[ -f "$PROJECT_ROOT/.env" ]]; then
    source "$PROJECT_ROOT/.env"
fi

# Configuration
BUCKET="${COGNITO_S3_BUCKET}"
REGION="${AWS_REGION}"

# Validate environment
if [[ -z "$BUCKET" ]] || [[ -z "$REGION" ]]; then
    echo -e "${RED}ERROR: Missing COGNITO_S3_BUCKET or AWS_REGION in .env${NC}"
    exit 1
fi

# Create download directory
mkdir -p "$DOWNLOAD_DIR"

# Get user ID from bucket (assumes single user or uses first)
get_user_id() {
    local users=$(aws s3 ls "s3://$BUCKET/users/" 2>/dev/null | grep PRE | awk '{print $2}' | tr -d '/' | head -1)
    if [[ -z "$users" ]]; then
        echo -e "${RED}ERROR: No users found in bucket${NC}" >&2
        exit 1
    fi
    echo "$users"
}

# Find files matching pattern
find_files() {
    local pattern="$1"
    local user_id="$2"

    # Search recursively in user folder
    aws s3 ls "s3://$BUCKET/users/$user_id/" --recursive 2>/dev/null | \
        grep -v '\.folder$' | \
        grep -i "$pattern" | \
        awk '{for(i=4;i<=NF;i++) printf "%s%s", $i, (i<NF?" ":""); print ""}'
}

# Download file
download_file() {
    local s3_key="$1"
    local user_id="$2"

    # Clean path for local storage
    local clean_path="${s3_key#users/$user_id/}"
    local output_path="$DOWNLOAD_DIR/$clean_path"
    local filename=$(basename "$s3_key")

    # Create subdirectories
    mkdir -p "$(dirname "$output_path")"

    echo -e "${BLUE}Downloading: $filename${NC}"

    # Download with retries for S3 eventual consistency
    local max_attempts=3
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        if aws s3 cp "s3://$BUCKET/$s3_key" "$output_path" --region "$REGION" 2>/dev/null; then
            local size=$(du -h "$output_path" | cut -f1)
            echo -e "${GREEN}✓ Downloaded: $output_path ($size)${NC}"
            echo "$output_path"  # Return path for caller
            return 0
        else
            if [[ $attempt -lt $max_attempts ]]; then
                echo -e "${BLUE}  Retry $attempt/$max_attempts...${NC}"
                sleep 2
                ((attempt++))
            else
                echo -e "${RED}✗ Failed to download after $max_attempts attempts${NC}"
                return 1
            fi
        fi
    done
}

# List files in a directory
list_files() {
    local folder="${1:-}"
    local user_id=$(get_user_id)

    echo -e "${BLUE}CloudDrive File Listing${NC}"
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}User ID: $user_id${NC}"
    echo -e "${BLUE}Bucket: $BUCKET${NC}"
    echo ""

    local path="s3://$BUCKET/users/$user_id/"
    if [[ -n "$folder" ]]; then
        path="${path}${folder}/"
    fi

    echo -e "${BLUE}Listing: $path${NC}"
    echo ""

    aws s3 ls "$path" --recursive --region "$REGION" 2>/dev/null | \
        grep -v '\.folder$' | \
        awk '{printf "%s %s  %s", $1, $2, $4; for(i=5;i<=NF;i++) printf " %s", $i; print ""}'
}

# Main
main() {
    # Handle --list option
    if [[ "$1" == "--list" ]]; then
        list_files "${2:-}"
        exit 0
    fi

    if [[ $# -lt 1 ]]; then
        echo "Usage: $0 <search-pattern-or-filename>"
        echo "   or: $0 --list [folder]"
        echo ""
        echo "Examples:"
        echo "  $0 'Screenshot'                      # Search for screenshots"
        echo "  $0 '2025-11-16'                      # Files with date"
        echo "  $0 'images/Screenshot 2025-11-16'    # Download specific file"
        echo "  $0 --list                             # List all files"
        echo "  $0 --list images                      # List files in images folder"
        exit 1
    fi

    local pattern="$1"

    echo -e "${BLUE}CloudDrive File Downloader${NC}"
    echo -e "${BLUE}==========================================${NC}"

    # Get user ID
    local user_id=$(get_user_id)
    echo -e "${BLUE}User ID: $user_id${NC}"
    echo -e "${BLUE}Bucket: $BUCKET${NC}"
    echo ""

    # Find matching files
    echo -e "${BLUE}Searching for: $pattern${NC}"
    local files=$(find_files "$pattern" "$user_id")

    if [[ -z "$files" ]]; then
        echo -e "${RED}No files found matching: $pattern${NC}"
        exit 1
    fi

    local file_count=$(echo "$files" | wc -l)
    echo -e "${GREEN}Found $file_count file(s)${NC}"
    echo ""

    # Download files
    local success=0
    local downloaded_paths=()

    while IFS= read -r s3_key; do
        [[ -z "$s3_key" ]] && continue

        if local_path=$(download_file "$s3_key" "$user_id"); then
            downloaded_paths+=("$local_path")
            ((success++))
        fi
    done <<< "$files"

    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${GREEN}Downloaded: $success of $file_count file(s)${NC}"
    echo -e "${BLUE}Location: $DOWNLOAD_DIR${NC}"

    # If single image downloaded, show path for easy viewing
    if [[ $success -eq 1 ]] && [[ "${downloaded_paths[0]}" =~ \.(png|jpg|jpeg|gif)$ ]]; then
        echo ""
        echo -e "${BLUE}Image downloaded:${NC}"
        echo "  ${downloaded_paths[0]}"
    fi
}

main "$@"
