#!/bin/bash
set -euo pipefail
mkdir -p "$(dirname "$0")/../logs"
exec > >(tee -a "$(dirname "$0")/../logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Script 400: Install Prerequisites
# ============================================================================
# Installs all required tools for deploying the CloudDrive stack.
#
# What this installs:
# - AWS CLI v2 (for AWS operations)
# - Node.js 20.x (for Serverless Framework)
# - unzip (required for AWS CLI installation)
#
# This script is idempotent - safe to run multiple times.
# ============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${CYAN}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }

echo "============================================"
echo -e "${CYAN}400: Install Prerequisites${NC}"
echo "============================================"
echo ""

# Detect architecture
ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    AWS_CLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip"
    log_info "Detected ARM64 architecture"
else
    AWS_CLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
    log_info "Detected x86_64 architecture"
fi
echo ""

# ============================================================================
# Install unzip (required for AWS CLI)
# ============================================================================
if ! command -v unzip &> /dev/null; then
    log_info "Installing unzip..."
    sudo apt-get update -qq
    sudo apt-get install -y unzip > /dev/null 2>&1
    log_success "unzip installed"
else
    log_info "unzip already installed"
fi

# ============================================================================
# Install AWS CLI
# ============================================================================
if ! command -v aws &> /dev/null; then
    log_info "Installing AWS CLI v2..."
    curl -s "$AWS_CLI_URL" -o "/tmp/awscliv2.zip"
    unzip -q -o /tmp/awscliv2.zip -d /tmp
    sudo /tmp/aws/install > /dev/null 2>&1
    rm -rf /tmp/awscliv2.zip /tmp/aws
    if command -v aws &> /dev/null; then
        log_success "AWS CLI $(aws --version | cut -d' ' -f1 | cut -d'/' -f2) installed"
    else
        log_error "Failed to install AWS CLI"
        exit 1
    fi
else
    log_info "AWS CLI $(aws --version | cut -d' ' -f1 | cut -d'/' -f2) already installed"
fi

# ============================================================================
# Install Node.js
# ============================================================================
if ! command -v node &> /dev/null || ! command -v npm &> /dev/null; then
    log_info "Installing Node.js 20.x..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - > /dev/null 2>&1
    sudo apt-get install -y nodejs > /dev/null 2>&1
    if command -v node &> /dev/null; then
        log_success "Node.js $(node --version) installed"
    else
        log_error "Failed to install Node.js"
        exit 1
    fi
else
    log_info "Node.js $(node --version) already installed"
fi

# ============================================================================
# Verify installations
# ============================================================================
echo ""
echo "============================================"
log_success "All prerequisites installed"
echo "============================================"
echo ""
log_info "Installed versions:"
echo "  - AWS CLI: $(aws --version | cut -d' ' -f1)"
echo "  - Node.js: $(node --version)"
echo "  - npm: $(npm --version)"
echo ""
log_info "Next steps:"
echo "  1. Attach IAM role to EC2 (if not done): See script 405"
echo "  2. Configure Cognito variables: ./scripts/410-configure-cognito-variables.sh"
echo "  3. Deploy the stack: ./scripts/420-deploy-cognito-stack.sh"
echo ""
