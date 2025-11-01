#!/bin/bash
#
# CloudDrive File Downloader - Development Tool
# Downloads files from CloudDrive S3 using AWS CLI
#
# Prerequisites: AWS CLI configured with S3 access permissions
#
# Usage: ./download.sh <filename-or-path> [user-id]
#
# Examples:
#   ./download.sh "Screenshot 2025-10-31 at 11.38.37 AM.png"
#   ./download.sh "test/myfile.pdf"
#   ./download.sh "*.png" (downloads all PNG files)

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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
DOWNLOAD_DIR="$PROJECT_ROOT/clouddrive-downloads"

# Validate required environment variables
if [[ -z "$BUCKET" ]] || [[ -z "$REGION" ]]; then
    echo -e "${RED}[ERROR]${NC} Missing required environment variables in .env:"
    [[ -z "$BUCKET" ]] && echo "  - COGNITO_S3_BUCKET"
    [[ -z "$REGION" ]] && echo "  - AWS_REGION"
    echo ""
    echo "Copy .env.example to .env and fill in your deployment values"
    exit 1
fi

# Create download directory
mkdir -p "$DOWNLOAD_DIR"

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

# Check if AWS CLI is configured and can access the bucket
check_aws_cli() {
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI is not installed"
        log_info "Install with: pip install awscli"
        return 1
    fi

    # Try to list bucket (suppress output)
    if aws s3 ls "s3://$BUCKET/" &> /dev/null; then
        return 0
    else
        log_error "Cannot access S3 bucket: $BUCKET"
        log_info "Check AWS credentials with: aws configure list"
        return 1
    fi
}

# Get user ID - either from parameter, AWS CLI, or detect from bucket
get_user_id() {
    local provided_user_id="$1"

    if [[ -n "$provided_user_id" ]]; then
        echo "$provided_user_id"
        return
    fi

    # Try to detect user ID from bucket
    log_info "Detecting user ID from S3 bucket..." >&2
    local users=$(aws s3 ls "s3://$BUCKET/users/" 2>/dev/null | grep PRE | awk '{print $2}' | tr -d '/')

    local user_count=$(echo "$users" | wc -l)

    if [[ $user_count -eq 1 ]]; then
        echo "$users"
        log_info "Found user ID: $users" >&2
    elif [[ $user_count -gt 1 ]]; then
        log_warn "Multiple users found, using first: $(echo "$users" | head -1)" >&2
        echo "$users" | head -1
    else
        log_error "No users found in bucket" >&2
        exit 1
    fi
}

# Find file in S3 bucket for user
find_file_in_s3() {
    local search_pattern="$1"
    local user_id="$2"
    local user_prefix="users/$user_id/"

    log_info "Searching for: $search_pattern in user folder..."

    # Search for files matching pattern
    local results=$(aws s3 ls "s3://$BUCKET/$user_prefix" --recursive 2>/dev/null | \
        grep -v '\.folder$' | \
        grep -i "$search_pattern" || true)

    if [[ -z "$results" ]]; then
        log_error "No files found matching: $search_pattern"
        return 1
    fi

    # Extract keys (4th column from ls output)
    echo "$results" | awk '{for(i=4;i<=NF;i++) printf $i" "; print ""}' | sed 's/ $//'
}

# Download file from S3
download_file() {
    local file_key="$1"
    local output_name="$2"

    log_info "Downloading from S3..."

    local s3_path="s3://$BUCKET/$file_key"
    local output_path="$DOWNLOAD_DIR/$output_name"

    # Create subdirectories if needed
    mkdir -p "$(dirname "$output_path")"

    if aws s3 cp "$s3_path" "$output_path" 2>/dev/null; then
        log_success "Downloaded: $output_path"

        # Show file info
        local file_size=$(du -h "$output_path" | cut -f1)
        log_info "File size: $file_size"

        return 0
    else
        log_error "Failed to download file"
        return 1
    fi
}

# Main execution
main() {
    if [[ $# -lt 1 ]]; then
        log_error "Usage: $0 <filename-or-path> [user-id]"
        exit 1
    fi

    local search_pattern="$1"
    local user_id="${2:-}"

    log_info "CloudDrive File Downloader"
    log_info "=========================================="

    # Check AWS CLI is available
    if ! check_aws_cli; then
        exit 1
    fi

    log_success "AWS CLI configured and ready"

    # Get user ID
    user_id=$(get_user_id "$user_id")

    log_info "Bucket: $BUCKET"
    log_info "User ID: $user_id"

    # Find files matching pattern
    local file_keys=$(find_file_in_s3 "$search_pattern" "$user_id")

    if [[ -z "$file_keys" ]]; then
        log_error "No files found"
        exit 1
    fi

    # Count files
    local file_count=$(echo "$file_keys" | wc -l)
    log_info "Found $file_count file(s) to download"

    # Download each file
    local success_count=0
    while IFS= read -r file_key; do
        [[ -z "$file_key" ]] && continue

        # Extract filename from key
        local filename=$(basename "$file_key")

        # Remove user prefix for cleaner output path
        local clean_path="${file_key#users/$user_id/}"

        log_info ""
        log_info "Processing: $filename"

        # Download file
        if download_file "$file_key" "$clean_path"; then
            ((success_count++))
        fi
    done <<< "$file_keys"

    # Summary
    log_info ""
    log_info "=========================================="
    log_success "Downloaded $success_count of $file_count file(s)"
    log_info "Location: $DOWNLOAD_DIR"

    # If single image file, offer to display
    if [[ $success_count -eq 1 ]] && [[ "$filename" =~ \.(png|jpg|jpeg|gif)$ ]]; then
        log_info ""
        log_info "Image file downloaded. You can view it with:"
        log_info "  open '$DOWNLOAD_DIR/$clean_path'  # macOS"
        log_info "  xdg-open '$DOWNLOAD_DIR/$clean_path'  # Linux"
    fi
}

# Run main
main "$@"
