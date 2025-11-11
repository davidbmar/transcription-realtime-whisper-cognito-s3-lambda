#!/bin/bash
#
# CloudDrive Authenticated File Downloader
# Downloads files via CloudDrive API using Cognito authentication
#
# Usage: ./download-authenticated.sh <filename>
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Load environment
if [[ -f "$PROJECT_ROOT/.env" ]]; then
    source "$PROJECT_ROOT/.env"
fi

DOWNLOAD_DIR="$PROJECT_ROOT/clouddrive-downloads"
mkdir -p "$DOWNLOAD_DIR"

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check for required credentials
if [[ -z "${CLOUDDRIVE_TEST_EMAIL:-}" ]] || [[ -z "${CLOUDDRIVE_TEST_PASSWORD:-}" ]]; then
    log_error "CloudDrive credentials not found in .env"
    log_info "Please add to .env file:"
    echo ""
    echo "CLOUDDRIVE_TEST_EMAIL=your-email@example.com"
    echo "CLOUDDRIVE_TEST_PASSWORD=your-password"
    echo ""

    read -p "Email: " email
    read -sp "Password: " password
    echo ""

    # Save to .env
    echo "" >> "$PROJECT_ROOT/.env"
    echo "# CloudDrive Browser Testing Credentials" >> "$PROJECT_ROOT/.env"
    echo "CLOUDDRIVE_TEST_EMAIL=$email" >> "$PROJECT_ROOT/.env"
    echo "CLOUDDRIVE_TEST_PASSWORD=$password" >> "$PROJECT_ROOT/.env"

    export CLOUDDRIVE_TEST_EMAIL="$email"
    export CLOUDDRIVE_TEST_PASSWORD="$password"

    log_success "Credentials saved to .env"
fi

# Use Node.js script to authenticate and download
node "$SCRIPT_DIR/download-via-api.js" "$@"
