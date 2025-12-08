#!/bin/bash
#
# CloudDrive File Search Utility
# Search and list files in CloudDrive S3 storage
#
# Usage: ./file-search.sh [pattern]
#        ./file-search.sh --list (list all files for default user)
#        ./file-search.sh --all (search ALL users - faster for finding uploads)
#        ./file-search.sh --recent [N] (show N most recent files across all users, default 20)
#        ./file-search.sh --folders (list folders only)
#        ./file-search.sh "pattern" (search by pattern in default user)
#        ./file-search.sh --all "pattern" (search pattern across ALL users)

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

# Configuration - all from .env, no hardcoded defaults
BUCKET="${COGNITO_S3_BUCKET}"
REGION="${AWS_REGION}"

# Validate required environment variables
if [[ -z "$BUCKET" ]] || [[ -z "$REGION" ]]; then
    echo -e "${RED}[ERROR]${NC} Missing required environment variables in .env:"
    [[ -z "$BUCKET" ]] && echo "  - COGNITO_S3_BUCKET"
    [[ -z "$REGION" ]] && echo "  - AWS_REGION"
    echo ""
    echo "Copy .env.example to .env and fill in your deployment values"
    exit 1
fi

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

# Search ALL users for a pattern (faster for finding specific uploads)
search_all_users() {
    local search_pattern="${1:-}"

    if [[ -n "$search_pattern" ]]; then
        log_info "Searching ALL users for: $search_pattern"
    else
        log_info "Listing files from ALL users"
    fi
    log_info ""

    # Get all files across all users using s3api for more details
    local results=$(aws s3api list-objects-v2 \
        --bucket "$BUCKET" \
        --prefix "users/" \
        --query 'Contents[?!contains(Key, `.folder`)].{Key:Key,Size:Size,LastModified:LastModified}' \
        --output text 2>/dev/null | sort -k3 -r)

    if [[ -z "$results" || "$results" == "None" ]]; then
        log_warn "No files found"
        return
    fi

    local match_count=0

    echo -e "${CYAN}KEY                                                                    SIZE       MODIFIED${NC}"
    echo "=================================================================================================="

    while IFS=$'\t' read -r key modified size; do
        [[ -z "$key" ]] && continue
        [[ "$key" == *".folder"* ]] && continue

        # Extract filename for pattern matching
        local filename=$(basename "$key")

        # If pattern provided, filter
        if [[ -n "$search_pattern" ]]; then
            if ! echo "$key" | grep -qi "$search_pattern"; then
                continue
            fi
        fi

        # Format output
        local human_sz=$(human_size ${size:-0})
        local short_date=$(echo "$modified" | cut -d'T' -f1)

        printf "%-70s %10s  %s\n" "$key" "$human_sz" "$short_date"
        ((match_count++)) || true
    done <<< "$results"

    echo "=================================================================================================="

    if [[ $match_count -eq 0 && -n "$search_pattern" ]]; then
        log_warn "No matches found for: $search_pattern"
    else
        log_success "Found $match_count file(s)"
    fi
}

# Show N most recent files across all users
show_recent() {
    local limit="${1:-20}"

    log_info "Showing $limit most recent files across ALL users"
    log_info ""

    # Get recent files sorted by last modified
    local results=$(aws s3api list-objects-v2 \
        --bucket "$BUCKET" \
        --prefix "users/" \
        --query "sort_by(Contents, &LastModified)[-${limit}:].{Key:Key,Size:Size,LastModified:LastModified}" \
        --output text 2>/dev/null)

    if [[ -z "$results" || "$results" == "None" ]]; then
        log_warn "No files found"
        return
    fi

    local file_count=0

    echo -e "${CYAN}RECENT FILES (newest first):${NC}"
    echo "=================================================================================================="

    # Reverse to show newest first
    while IFS=$'\t' read -r key modified size; do
        [[ -z "$key" ]] && continue
        [[ "$key" == *".folder"* ]] && continue

        local human_sz=$(human_size ${size:-0})
        local short_date=$(echo "$modified" | cut -d'T' -f1,2 | tr 'T' ' ' | cut -c1-16)

        printf "%-16s  %10s  %s\n" "$short_date" "$human_sz" "$key"
        ((file_count++)) || true
    done <<< "$(echo "$results" | tac)"

    echo "=================================================================================================="
    log_success "Showing $file_count most recent file(s)"
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

    case "$command" in
        --all)
            # Search all users (with optional pattern as second arg)
            search_all_users "${2:-}"
            ;;
        --recent)
            # Show N most recent files (second arg is count, default 20)
            show_recent "${2:-20}"
            ;;
        --list)
            # Get user ID for single-user operations
            local user_id=$(get_user_id)
            log_info "User ID: $user_id"
            log_info ""
            list_files "$user_id"
            ;;
        --folders)
            local user_id=$(get_user_id)
            log_info "User ID: $user_id"
            log_info ""
            list_folders "$user_id"
            ;;
        --help|-h)
            echo "CloudDrive File Search Utility"
            echo ""
            echo "Usage:"
            echo "  $0                      List all files (default user)"
            echo "  $0 --list               List all files (default user)"
            echo "  $0 --all                List ALL files across ALL users"
            echo "  $0 --all <pattern>      Search ALL users for pattern"
            echo "  $0 --recent [N]         Show N most recent files (default: 20)"
            echo "  $0 --folders            List folders only (default user)"
            echo "  $0 <pattern>            Search files by pattern (default user)"
            echo ""
            echo "Examples:"
            echo "  $0 --all 'audible'      Find 'audible' in any user's files"
            echo "  $0 --all '.png'         Find all PNG files across all users"
            echo "  $0 --recent 10          Show 10 most recently uploaded files"
            echo "  $0 'screenshot'         Search in default user's files"
            echo ""
            echo "Tip: Use --all for faster searching when you don't know which user uploaded a file"
            ;;
        *)
            # Search mode (default user)
            local user_id=$(get_user_id)
            log_info "User ID: $user_id"
            log_info ""
            search_files "$user_id" "$command"
            ;;
    esac
}

# Run main
main "$@"
