#!/bin/bash
#
# CloudDrive File Search Utility
# Search and list files in CloudDrive S3 storage
#
# Usage: ./file-search.sh [pattern]
#        ./file-search.sh --list (list all files)
#        ./file-search.sh --folders (list folders only)
#        ./file-search.sh "*.png" (search by pattern)

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Load environment variables
if [[ -f "$PROJECT_ROOT/.env" ]]; then
    source "$PROJECT_ROOT/.env"
fi

# Configuration
BUCKET="${COGNITO_S3_BUCKET:-dbm-ts-cog-oct-28-2025}"
REGION="${AWS_REGION:-us-east-2}"

# Functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Format file size in human readable format
human_size() {
    local size=$1
    if [[ $size -lt 1024 ]]; then
        echo "${size}B"
    elif [[ $size -lt $((1024 * 1024)) ]]; then
        echo "$((size / 1024))KB"
    elif [[ $size -lt $((1024 * 1024 * 1024)) ]]; then
        echo "$((size / 1024 / 1024))MB"
    else
        echo "$((size / 1024 / 1024 / 1024))GB"
    fi
}

# Get user ID
get_user_id() {
    log_info "Detecting user ID from S3 bucket..." >&2
    local users=$(aws s3 ls "s3://$BUCKET/users/" 2>/dev/null | grep PRE | awk '{print $2}' | tr -d '/')

    local user_count=$(echo "$users" | wc -l)

    if [[ $user_count -eq 1 ]]; then
        echo "$users"
    elif [[ $user_count -gt 1 ]]; then
        log_warn "Multiple users found, using first one" >&2
        echo "$users" | head -1
    else
        log_error "No users found in bucket" >&2
        exit 1
    fi
}

# List all files
list_files() {
    local user_id="$1"
    local pattern="${2:-}"
    local user_prefix="users/$user_id/"

    log_info "Listing files for user: $user_id"
    log_info ""

    # Get all files
    local results=$(aws s3 ls "s3://$BUCKET/$user_prefix" --recursive 2>/dev/null)

    if [[ -z "$results" ]]; then
        log_warn "No files found"
        return
    fi

    # Filter and display
    local file_count=0
    local total_size=0

    echo -e "${CYAN}DATE       TIME     SIZE       FILE${NC}"
    echo "=================================================="

    while IFS= read -r line; do
        # Skip .folder markers
        if [[ "$line" == *".folder"* ]]; then
            continue
        fi

        # Parse S3 ls output: DATE TIME SIZE KEY
        local date=$(echo "$line" | awk '{print $1}')
        local time=$(echo "$line" | awk '{print $2}')
        local size=$(echo "$line" | awk '{print $3}')
        local key=$(echo "$line" | awk '{for(i=4;i<=NF;i++) printf $i" "; print ""}' | sed 's/ $//')

        # Remove user prefix for display
        local display_path="${key#$user_prefix}"

        # Apply pattern filter if provided
        if [[ -n "$pattern" ]]; then
            if [[ ! "$display_path" =~ $pattern ]]; then
                continue
            fi
        fi

        # Format size
        local human_sz=$(human_size $size)

        # Print file info
        printf "%-10s %-8s %-10s %s\n" "$date" "$time" "$human_sz" "$display_path"

        ((file_count++))
        total_size=$((total_size + size))
    done <<< "$results"

    echo "=================================================="
    local total_human=$(human_size $total_size)
    log_success "Total: $file_count files ($total_human)"
}

# List folders only
list_folders() {
    local user_id="$1"
    local user_prefix="users/$user_id/"

    log_info "Listing folders for user: $user_id"
    log_info ""

    # Get all files and extract unique folder paths
    local results=$(aws s3 ls "s3://$BUCKET/$user_prefix" --recursive 2>/dev/null | \
        awk '{for(i=4;i<=NF;i++) printf $i" "; print ""}' | \
        sed 's/ $//')

    if [[ -z "$results" ]]; then
        log_warn "No files found"
        return
    fi

    # Extract unique folders
    local folders=$(echo "$results" | \
        sed "s|^$user_prefix||" | \
        grep '/' | \
        sed 's|/[^/]*$||' | \
        sort -u)

    if [[ -z "$folders" ]]; then
        log_info "No folders found (all files in root)"
        return
    fi

    echo -e "${CYAN}FOLDERS:${NC}"
    echo "=================================================="

    local folder_count=0
    while IFS= read -r folder; do
        [[ -z "$folder" ]] && continue
        echo "  📁 $folder/"
        ((folder_count++))
    done <<< "$folders"

    echo "=================================================="
    log_success "Total: $folder_count folders"
}

# Search files by pattern
search_files() {
    local user_id="$1"
    local search_pattern="$2"
    local user_prefix="users/$user_id/"

    log_info "Searching for: $search_pattern"
    log_info ""

    # Get all files
    local results=$(aws s3 ls "s3://$BUCKET/$user_prefix" --recursive 2>/dev/null)

    if [[ -z "$results" ]]; then
        log_warn "No files found"
        return
    fi

    # Search and display matches
    local match_count=0

    echo -e "${CYAN}MATCHES:${NC}"
    echo "=================================================="

    while IFS= read -r line; do
        # Skip .folder markers
        if [[ "$line" == *".folder"* ]]; then
            continue
        fi

        # Extract key
        local key=$(echo "$line" | awk '{for(i=4;i<=NF;i++) printf $i" "; print ""}' | sed 's/ $//')
        local display_path="${key#$user_prefix}"

        # Check if matches pattern (case insensitive)
        if echo "$display_path" | grep -qi "$search_pattern"; then
            local size=$(echo "$line" | awk '{print $3}')
            local date=$(echo "$line" | awk '{print $1}')
            local human_sz=$(human_size $size)

            printf "  ✓ %-50s %10s  %s\n" "$display_path" "$human_sz" "$date"
            ((match_count++))
        fi
    done <<< "$results"

    echo "=================================================="

    if [[ $match_count -eq 0 ]]; then
        log_warn "No matches found for: $search_pattern"
    else
        log_success "Found $match_count match(es)"
    fi
}

# Main execution
main() {
    local command="${1:---list}"

    log_info "CloudDrive File Search"
    log_info "======================"
    log_info ""

    # Check if AWS CLI is available
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI is not installed"
        exit 1
    fi

    # Check bucket access
    if ! aws s3 ls "s3://$BUCKET/" &> /dev/null; then
        log_error "Cannot access bucket: $BUCKET"
        log_info "Make sure AWS credentials are configured"
        exit 1
    fi

    # Get user ID
    local user_id=$(get_user_id)
    log_info "User ID: $user_id"
    log_info ""

    case "$command" in
        --list)
            list_files "$user_id"
            ;;
        --folders)
            list_folders "$user_id"
            ;;
        --help)
            echo "CloudDrive File Search Utility"
            echo ""
            echo "Usage:"
            echo "  $0                    List all files"
            echo "  $0 --list             List all files"
            echo "  $0 --folders          List folders only"
            echo "  $0 <pattern>          Search files by pattern"
            echo "  $0 '*.png'            Find all PNG files"
            echo "  $0 'screenshot'       Find files with 'screenshot' in name"
            echo "  $0 --help             Show this help"
            ;;
        *)
            # Search mode
            search_files "$user_id" "$command"
            ;;
    esac
}

# Run main
main "$@"
