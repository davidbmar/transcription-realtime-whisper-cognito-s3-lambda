#!/bin/bash
#
# CloudDrive File Downloader
# Downloads files from CloudDrive S3 storage
#
# Usage: ./download.sh <search-pattern> [options]
#        ./download.sh <user_id>:<filename>       # Download from specific user
#
# Options:
#   --all           Search ALL users (not just default user)
#   --folder <name> Search in specific folder (default: images)
#   --list          List recent files instead of downloading
#   --user <id>     Specify user ID to search
#
# Examples:
#   ./download.sh "Screenshot"                    # Download screenshots from default user
#   ./download.sh "Screenshot" --all              # Download screenshots from ALL users
#   ./download.sh "recording" --folder audio      # Download from audio folder
#   ./download.sh --list                          # List recent images
#   ./download.sh --list --all                    # List all files across all users
#   ./download.sh "512b3590...:Screenshot.png"    # Download from specific user (user:file format)

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DOWNLOAD_DIR="/tmp/clouddrive-downloads"

# Load environment
if [[ -f "$PROJECT_ROOT/.env" ]]; then
    source "$PROJECT_ROOT/.env"
fi

# Configuration from .env
BUCKET="${COGNITO_S3_BUCKET:-}"
REGION="${AWS_REGION:-}"

# Validate environment
if [[ -z "$BUCKET" ]] || [[ -z "$REGION" ]]; then
    echo -e "${RED}ERROR: Missing COGNITO_S3_BUCKET or AWS_REGION in .env${NC}"
    exit 1
fi

# Create download directory
mkdir -p "$DOWNLOAD_DIR"

# Get all user IDs
get_all_users() {
    aws s3 ls "s3://$BUCKET/users/" 2>/dev/null | grep PRE | awk '{print $2}' | tr -d '/'
}

# Get default (first) user ID
get_default_user() {
    get_all_users | head -1
}

# Download files using s3 sync (handles spaces better than s3 cp)
download_files() {
    local pattern="$1"
    local search_all="${2:-false}"
    local folder="${3:-}"

    echo -e "${BLUE}Downloading files matching: *$pattern*${NC}"

    local found=0

    if [[ "$search_all" == "true" ]]; then
        # Search across all users
        local users=$(get_all_users)
        for user_id in $users; do
            local prefix="users/$user_id/"
            [[ -n "$folder" ]] && prefix="${prefix}${folder}/"

            echo -e "${YELLOW}Searching user: $user_id${NC}"

            local result=$(aws s3 sync \
                "s3://$BUCKET/$prefix" \
                "$DOWNLOAD_DIR/$user_id/" \
                --exclude "*" \
                --include "*$pattern*" \
                --region "$REGION" 2>&1)

            if [[ "$result" == *"download:"* ]]; then
                echo "$result"
                found=1
            fi
        done
    else
        # Search default user only
        local user_id=$(get_default_user)
        local prefix="users/$user_id/"
        [[ -n "$folder" ]] && prefix="${prefix}${folder}/"

        echo -e "${YELLOW}Searching user: $user_id${NC}"

        local result=$(aws s3 sync \
            "s3://$BUCKET/$prefix" \
            "$DOWNLOAD_DIR/" \
            --exclude "*" \
            --include "*$pattern*" \
            --region "$REGION" 2>&1)

        if [[ "$result" == *"download:"* ]]; then
            echo "$result"
            found=1
        fi
    fi

    if [[ $found -eq 0 ]]; then
        echo -e "${RED}No files found matching: $pattern${NC}"
        return 1
    fi

    echo -e "${GREEN}Download complete!${NC}"
    echo -e "${BLUE}Files saved to: $DOWNLOAD_DIR${NC}"
}

# List files
list_files() {
    local search_all="${1:-false}"
    local folder="${2:-images}"

    if [[ "$search_all" == "true" ]]; then
        echo -e "${BLUE}Recent files across ALL users:${NC}"
        "$SCRIPT_DIR/file-search.sh" --recent 20
    else
        local user_id=$(get_default_user)
        echo -e "${BLUE}Recent files for user $user_id:${NC}"
        aws s3 ls "s3://$BUCKET/users/$user_id/$folder/" --region "$REGION" 2>/dev/null | \
            grep -v '\.folder$' | \
            tail -20
    fi
}

# Show help
show_help() {
    cat << 'EOF'
CloudDrive File Downloader
==========================

Downloads files from CloudDrive S3 storage to /tmp/clouddrive-downloads/

USAGE:
  ./download.sh <pattern>              Download files matching pattern
  ./download.sh <pattern> --all        Download from ALL users
  ./download.sh <pattern> --folder X   Download from specific folder
  ./download.sh --list                 List recent files
  ./download.sh --list --all           List files from all users
  ./download.sh --help                 Show this help

EXAMPLES:
  ./download.sh "Screenshot"           Download screenshots (default user)
  ./download.sh "2025-12-17" --all     Download Dec 17 files from any user
  ./download.sh "recording" --folder audio/sessions
  ./download.sh --list                 List recent images

NOTES:
  - Downloads go to /tmp/clouddrive-downloads/
  - Use file-search.sh for advanced searching
  - Pattern matching is case-sensitive

SEE ALSO:
  ./file-search.sh --help              Advanced file search options
EOF
}

# Download from specific user
download_from_user() {
    local user_id="$1"
    local pattern="$2"
    local folder="${3:-}"

    echo -e "${BLUE}Downloading from user: $user_id${NC}"
    echo -e "${BLUE}Pattern: *$pattern*${NC}"

    local prefix="users/$user_id/"
    [[ -n "$folder" ]] && prefix="${prefix}${folder}/"

    # Use s3 sync which handles filenames with spaces better
    local result=$(aws s3 sync \
        "s3://$BUCKET/$prefix" \
        "$DOWNLOAD_DIR/$user_id/" \
        --exclude "*" \
        --include "*$pattern*" \
        --region "$REGION" 2>&1)

    if [[ "$result" == *"download:"* ]]; then
        echo "$result"
        echo -e "${GREEN}Download complete!${NC}"
        echo -e "${BLUE}Files saved to: $DOWNLOAD_DIR/$user_id/${NC}"
        return 0
    else
        echo -e "${YELLOW}No files downloaded via sync. Trying direct download...${NC}"

        # Try listing and downloading individually
        local files=$(aws s3 ls "s3://$BUCKET/$prefix" --recursive 2>/dev/null | grep -i "$pattern" | awk '{$1=$2=$3=""; print substr($0,4)}')

        if [[ -z "$files" ]]; then
            echo -e "${RED}No files found matching: $pattern${NC}"
            return 1
        fi

        echo -e "${BLUE}Found files:${NC}"
        echo "$files"

        # Download each file
        while IFS= read -r key; do
            [[ -z "$key" ]] && continue
            local filename=$(basename "$key")
            local target_dir="$DOWNLOAD_DIR/$user_id/$(dirname "$key" | sed "s|users/$user_id/||")"
            mkdir -p "$target_dir"
            echo -e "${YELLOW}Downloading: $filename${NC}"
            aws s3 cp "s3://$BUCKET/$key" "$target_dir/" --region "$REGION" 2>&1 || true
        done <<< "$files"

        echo -e "${GREEN}Download complete!${NC}"
    fi
}

# Main
main() {
    local pattern=""
    local search_all="false"
    local folder=""
    local list_mode="false"
    local specific_user=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)
                search_all="true"
                shift
                ;;
            --folder)
                folder="$2"
                shift 2
                ;;
            --list)
                list_mode="true"
                shift
                ;;
            --user)
                specific_user="$2"
                shift 2
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                pattern="$1"
                shift
                ;;
        esac
    done

    # Handle list mode
    if [[ "$list_mode" == "true" ]]; then
        list_files "$search_all" "$folder"
        exit 0
    fi

    # Require pattern for download
    if [[ -z "$pattern" ]]; then
        show_help
        exit 1
    fi

    # Check for user:filename format
    if [[ "$pattern" == *":"* ]]; then
        specific_user="${pattern%%:*}"
        pattern="${pattern#*:}"
        echo -e "${BLUE}Parsed user:file format${NC}"
        echo -e "${BLUE}  User: $specific_user${NC}"
        echo -e "${BLUE}  Pattern: $pattern${NC}"
    fi

    # Use specific user if provided
    if [[ -n "$specific_user" ]]; then
        download_from_user "$specific_user" "$pattern" "$folder"
    else
        download_files "$pattern" "$search_all" "$folder"
    fi

    # Show downloaded files
    echo ""
    echo -e "${BLUE}Downloaded files:${NC}"
    find "$DOWNLOAD_DIR" -name "*$pattern*" -type f 2>/dev/null | head -20
}

main "$@"
