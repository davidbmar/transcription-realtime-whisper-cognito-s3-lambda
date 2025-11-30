#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# 010: Setup Build Box Prerequisites
# ============================================================================
# Installs all prerequisites on the build box (where WebSocket bridge runs).
# Run this FIRST on a fresh Ubuntu 20.04/22.04 instance.
#
# What this does:
# 1. Installs Python 3.10+, pip, venv
# 2. Installs AWS CLI
# 3. Creates Python virtual environment
# 4. Installs Python dependencies (riva-client, websockets, etc.)
# 5. Creates SSL certificates for HTTPS
# 6. Creates project directory structure
# ============================================================================

echo "============================================"
echo "010: Setup Build Box Prerequisites"
echo "============================================"
echo ""

# Check if running as root
if [ "$EUID" -eq 0 ]; then
  echo "❌ Do not run this script as root"
  echo "Run as: ./scripts/010-setup-build-box.sh"
  exit 1
fi

# ============================================================================
# Step 1: Install System Dependencies
# ============================================================================
echo "Step 1/7: Installing system dependencies..."
sudo apt-get update
sudo apt-get install -y \
  python3 \
  python3-pip \
  python3-venv \
  python3-dev \
  build-essential \
  git \
  curl \
  wget \
  unzip \
  jq \
  netcat-openbsd \
  openssl

echo "Checking AWS CLI installation..."
if command -v aws &> /dev/null; then
  echo "✅ AWS CLI already installed: $(aws --version)"
else
  echo "Installing AWS CLI via apt..."
  sudo apt-get install -y awscli
  if ! command -v aws &> /dev/null; then
    echo "⚠️  apt installation didn't work, trying pip with --break-system-packages..."
    python3 -m pip install --user awscli --upgrade --break-system-packages
  fi
fi

echo "✅ System dependencies installed"
echo ""

# ============================================================================
# Step 2: Verify Python Version
# ============================================================================
echo "Step 2/7: Verifying Python version..."
PYTHON_VERSION=$(python3 --version | awk '{print $2}')
PYTHON_MAJOR=$(echo $PYTHON_VERSION | cut -d. -f1)
PYTHON_MINOR=$(echo $PYTHON_VERSION | cut -d. -f2)

if [ "$PYTHON_MAJOR" -lt 3 ] || ([ "$PYTHON_MAJOR" -eq 3 ] && [ "$PYTHON_MINOR" -lt 8 ]); then
  echo "❌ Python 3.8+ required, found $PYTHON_VERSION"
  exit 1
fi

echo "✅ Python $PYTHON_VERSION (OK)"
echo ""

# ============================================================================
# Step 3: Create Project Directory Structure
# ============================================================================
echo "Step 3/7: Creating project directory structure..."
sudo mkdir -p /opt/whisperlive/{certs,logs}
sudo chown -R $USER:$USER /opt/whisperlive

# Copy project files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

sudo mkdir -p /opt/whisperlive/nvidia-riva-conformer-streaming
sudo cp -r "$PROJECT_DIR"/* /opt/whisperlive/nvidia-riva-conformer-streaming/
sudo chown -R $USER:$USER /opt/whisperlive/nvidia-riva-conformer-streaming

echo "✅ Project directory created at /opt/whisperlive/nvidia-riva-conformer-streaming"
echo ""

# ============================================================================
# Step 4: Create Python Virtual Environment
# ============================================================================
echo "Step 4/7: Creating Python virtual environment..."
cd /opt/whisperlive/nvidia-riva-conformer-streaming

if [ -d "venv" ]; then
  echo "⚠️  Virtual environment already exists, recreating..."
  rm -rf venv
fi

python3 -m venv venv
source venv/bin/activate

echo "✅ Virtual environment created"
echo ""

# ============================================================================
# Step 5: Install Python Dependencies
# ============================================================================
echo "Step 5/7: Installing Python dependencies..."
pip install --upgrade pip setuptools wheel

# Core dependencies
# Note: nvidia-riva-client 2.19.0 requires grpcio==1.67.1
pip install \
  nvidia-riva-client==2.19.0 \
  grpcio==1.67.1 \
  grpcio-tools==1.67.1 \
  websockets==12.0 \
  python-dotenv==1.0.0 \
  boto3==1.34.0 \
  requests==2.31.0

echo "✅ Python dependencies installed"
echo ""

# ============================================================================
# Step 6: Generate SSL Certificates
# ============================================================================
echo "Step 6/7: Generating self-signed SSL certificates..."

if [ -f "/opt/whisperlive/certs/server.crt" ]; then
  echo "⚠️  SSL certificates already exist, skipping..."
else
  openssl req -x509 -newkey rsa:4096 -nodes \
    -keyout /opt/whisperlive/certs/server.key \
    -out /opt/whisperlive/certs/server.crt \
    -days 365 \
    -subj "/C=US/ST=State/L=City/O=Organization/CN=localhost"

  chmod 600 /opt/whisperlive/certs/server.key
  chmod 644 /opt/whisperlive/certs/server.crt

  echo "✅ SSL certificates generated"
fi
echo ""

# ============================================================================
# Step 7: Verify AWS CLI Configuration
# ============================================================================
echo "Step 7/7: Verifying AWS CLI configuration..."

if aws sts get-caller-identity &>/dev/null; then
  echo "✅ AWS CLI configured"
  AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
  echo "   Account: $AWS_ACCOUNT"
else
  echo "⚠️  AWS CLI not configured"
  echo ""
  echo "Run: aws configure"
  echo "Then enter your AWS credentials:"
  echo "  - AWS Access Key ID"
  echo "  - AWS Secret Access Key"
  echo "  - Default region: us-east-2"
  echo "  - Default output: json"
fi
echo ""

# ============================================================================
# Success Summary
# ============================================================================
echo "========================================="
echo "✅ BUILD BOX SETUP COMPLETE"
echo "========================================="
echo ""
echo "📁 Project location: /opt/whisperlive/nvidia-riva-conformer-streaming"
echo "🐍 Virtual environment: source /opt/whisperlive/nvidia-riva-conformer-streaming/venv/bin/activate"
echo "🔐 SSL certificates: /opt/whisperlive/certs/"
echo ""
echo "Next steps:"
echo "  1. Configure AWS CLI (if not done): aws configure"
echo "  2. Copy .env.example to .env: cp .env.example .env"
echo "  3. Edit .env with your NGC API key and AWS settings"
echo "  4. Run: ./scripts/020-create-gpu-instance.sh"
echo ""
