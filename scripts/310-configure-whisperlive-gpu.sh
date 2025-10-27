#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# 310: Configure WhisperLive on GPU Instance
# ============================================================================
# Installs and configures WhisperLive on the GPU EC2 instance.
# This script can be run FROM BUILD BOX (via SSH) or directly ON GPU.
#
# What this does:
# 1. Install WhisperLive from Collabora GitHub
# 2. Install faster-whisper and dependencies
# 3. Download Whisper models
# 4. Create WhisperLive systemd service
# 5. Start WhisperLive server on port 9090
# 6. Verify WhisperLive is responding
# ============================================================================

# Find repository root (works from symlink or direct execution)
if [ -L "${BASH_SOURCE[0]}" ]; then
    SCRIPT_REAL=$(readlink -f "${BASH_SOURCE[0]}")
else
    SCRIPT_REAL="${BASH_SOURCE[0]}"
fi
REPO_ROOT="$(cd "$(dirname "$SCRIPT_REAL")/.." && pwd)"
PROJECT_ROOT="$REPO_ROOT"

# Source common functions if available
if [ -f "$REPO_ROOT/scripts/lib/common-functions.sh" ]; then
    source "$REPO_ROOT/scripts/lib/common-functions.sh"
else
    log_info() { echo "[INFO] $*"; }
    log_success() { echo "[SUCCESS] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_warn() { echo "[WARN] $*"; }
fi

echo "============================================"
echo "310: Configure WhisperLive on GPU"
echo "============================================"
echo ""

# ============================================================================
# Determine Execution Mode
# ============================================================================
log_info "Determining execution mode..."

# Load .env if available
if [ -f "$PROJECT_ROOT/.env" ]; then
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
fi

# Check if we're on the GPU instance or build box
if [ -n "${GPU_INSTANCE_IP:-}" ] && [ "$(hostname -I | awk '{print $1}')" != "$GPU_INSTANCE_IP" ]; then
    REMOTE_MODE=true
    log_info "Running in REMOTE mode - will SSH to GPU instance"
    log_info "GPU IP: $GPU_INSTANCE_IP"

    if [ -z "${SSH_KEY:-}" ]; then
        if [ -n "${SSH_KEY_NAME:-}" ]; then
            SSH_KEY="$HOME/.ssh/${SSH_KEY_NAME}.pem"
        else
            log_error "SSH_KEY_NAME not set in .env"
            exit 1
        fi
    fi

    if [ ! -f "$SSH_KEY" ]; then
        log_error "SSH key not found: $SSH_KEY"
        log_error "Expected: $HOME/.ssh/${SSH_KEY_NAME}.pem"
        exit 1
    fi
else
    REMOTE_MODE=false
    log_info "Running in LOCAL mode - executing on GPU instance"
fi

echo ""

# ============================================================================
# Installation Script (to be executed ON GPU)
# ============================================================================
read -r -d '' INSTALL_SCRIPT << 'EOFSCRIPT' || true
#!/bin/bash
set -euo pipefail

echo "============================================"
echo "Installing WhisperLive on GPU Instance"
echo "============================================"
echo ""

# Step 1: Install system dependencies
echo "[1/7] Installing system dependencies..."

# Check if dependencies are already installed
if command -v python3.9 >/dev/null 2>&1 && dpkg -l | grep -q python3.9-venv && dpkg -l | grep -q ffmpeg; then
    echo "✅ System dependencies already installed (skipping apt-get)"
else
    echo "Installing missing dependencies..."

    # Remove broken NVIDIA repositories (common on older GPU instances)
    echo "Cleaning up any broken NVIDIA repositories..."
    sudo rm -f /etc/apt/sources.list.d/nvidia-*.list 2>/dev/null || true

    sudo apt-get update

    # Install Python 3.9 (WhisperLive requires numpy 1.26.4 which needs Python 3.9+)
    # Python 3.9 is the most stable version available in deadsnakes PPA for Ubuntu 20.04
    echo "Installing Python 3.9 from deadsnakes PPA..."
    sudo apt-get install -y software-properties-common
    sudo add-apt-repository -y ppa:deadsnakes/ppa
    sudo apt-get update
    sudo apt-get install -y \
        python3.9 \
        python3.9-venv \
        python3.9-dev \
        git \
        ffmpeg \
        portaudio19-dev

    echo "✅ System dependencies installed"
fi

echo "✅ Python 3.9 ready (required for WhisperLive)"
echo ""

# Step 2: Create WhisperLive directory
echo "[2/7] Creating WhisperLive directory..."
WHISPER_DIR="$HOME/whisperlive"
mkdir -p "$WHISPER_DIR"
cd "$WHISPER_DIR"

echo "✅ Directory created: $WHISPER_DIR"
echo ""

# Step 3: Clone WhisperLive repository
echo "[3/7] Cloning WhisperLive repository..."
if [ -d "WhisperLive" ]; then
    echo "WhisperLive already cloned, updating..."
    cd WhisperLive
    git pull
else
    git clone https://github.com/collabora/WhisperLive.git
    cd WhisperLive
fi

echo "✅ WhisperLive repository ready"
echo ""

# Step 4: Create Python virtual environment
echo "[4/7] Creating Python virtual environment with Python 3.9..."

# Check if venv exists and is functional
if [ -d "venv" ] && [ -f "venv/bin/python3" ]; then
    echo "Virtual environment exists, checking health..."
    if venv/bin/python3 -c "import sys; sys.exit(0)" 2>/dev/null; then
        echo "✅ Existing virtual environment is healthy (preserving)"
        source venv/bin/activate
        SKIP_PIP_INSTALL=true
    else
        echo "Virtual environment corrupted, recreating..."
        rm -rf venv
        python3.9 -m venv venv
        source venv/bin/activate
        SKIP_PIP_INSTALL=false
    fi
else
    echo "Creating new virtual environment..."
    python3.9 -m venv venv
    source venv/bin/activate
    SKIP_PIP_INSTALL=false
fi

echo "✅ Virtual environment ready with Python 3.9"
python --version
echo ""

# Step 5: Install WhisperLive and dependencies
echo "[5/7] Installing WhisperLive and dependencies..."

if [ "${SKIP_PIP_INSTALL:-false}" = "true" ]; then
    echo "✅ Dependencies already installed (skipping pip install)"
    # Quick verification
    if python -c "import whisper_live, faster_whisper" 2>/dev/null; then
        echo "✅ Package verification passed"
    else
        echo "⚠️  Verification failed, reinstalling..."
        SKIP_PIP_INSTALL=false
    fi
fi

if [ "${SKIP_PIP_INSTALL:-false}" = "false" ]; then
    pip install --upgrade pip setuptools wheel

    # Install WhisperLive and faster-whisper
    pip install -e .
    pip install faster-whisper

    # Install cuDNN for GPU inference (required for faster-whisper on CUDA)
    # This provides libcudnn_ops.so.* libraries needed by faster-whisper
    echo "Installing cuDNN for GPU inference..."
    pip install nvidia-cudnn-cu11

    echo "✅ WhisperLive and dependencies installed"
fi

echo ""

# Step 6: Download Whisper model
echo "[6/7] Downloading Whisper model (this may take a few minutes)..."

# Check if model is already cached
MODEL_CACHE="$HOME/.cache/huggingface/hub"
if [ -d "$MODEL_CACHE" ] && find "$MODEL_CACHE" -name "*faster-whisper-small.en*" -type d 2>/dev/null | grep -q .; then
    echo "✅ Whisper model already cached (skipping download)"
else
    echo "Downloading model..."
    python3 << 'PYEOF'
from faster_whisper import WhisperModel

# Download small.en model (fast for testing)
print("Downloading faster-whisper-small.en...")
model = WhisperModel("small.en", device="cuda", compute_type="float16")
print("✅ Model downloaded and cached")
PYEOF
    echo "✅ Whisper model downloaded"
fi

echo "✅ Whisper model ready"
echo ""

# Step 7: Create systemd service
echo "[7/7] Creating systemd service..."

# Set library paths for cuDNN and cuBLAS (installed via pip)
CUDNN_LIB_PATH="$HOME/whisperlive/WhisperLive/venv/lib/python3.9/site-packages/nvidia/cudnn/lib"
CUBLAS_LIB_PATH="$HOME/whisperlive/WhisperLive/venv/lib/python3.9/site-packages/nvidia/cublas/lib"

sudo tee /etc/systemd/system/whisperlive.service > /dev/null << EOF
[Unit]
Description=WhisperLive WebSocket Server
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$HOME/whisperlive/WhisperLive
Environment="PATH=$HOME/whisperlive/WhisperLive/venv/bin"
Environment="LD_LIBRARY_PATH=$CUDNN_LIB_PATH:$CUBLAS_LIB_PATH"
ExecStart=$HOME/whisperlive/WhisperLive/venv/bin/python3 run_server.py \\
    --port 9090 \\
    --backend faster_whisper

Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable whisperlive
sudo systemctl restart whisperlive

echo "✅ WhisperLive service created and started"
echo ""

# Wait for service to be ready
echo "Waiting for WhisperLive to start..."
sleep 5

# Check service status
if sudo systemctl is-active --quiet whisperlive; then
    echo "✅ WhisperLive service is running"

    # Test if port 9090 is listening
    if netstat -tuln 2>/dev/null | grep -q ":9090 " || ss -tuln 2>/dev/null | grep -q ":9090 "; then
        echo "✅ WhisperLive listening on port 9090"
    else
        echo "⚠️  Port 9090 not listening yet, may need more time"
    fi
else
    echo "❌ WhisperLive service failed to start"
    sudo systemctl status whisperlive --no-pager
    exit 1
fi

echo ""
echo "============================================"
echo "✅ WhisperLive Installation Complete"
echo "============================================"
echo ""
echo "Service Management:"
echo "  - Status: sudo systemctl status whisperlive"
echo "  - Logs: sudo journalctl -u whisperlive -f"
echo "  - Restart: sudo systemctl restart whisperlive"
echo "  - Stop: sudo systemctl stop whisperlive"
echo ""
echo "WhisperLive is now listening on port 9090"
echo "Protocol: WebSocket (ws://)"
echo "Expects: Float32 PCM audio @ 16kHz mono"
echo ""
EOFSCRIPT

# ============================================================================
# Execute Installation
# ============================================================================
if [ "$REMOTE_MODE" = true ]; then
    log_info "Executing installation on GPU instance via SSH..."
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "bash -s" << EOF
$INSTALL_SCRIPT
EOF

    if [ $? -eq 0 ]; then
        log_success "✅ Remote installation completed successfully"
    else
        log_error "❌ Remote installation failed"
        exit 1
    fi
else
    log_info "Executing installation locally..."
    bash -c "$INSTALL_SCRIPT"
fi

echo ""
log_info "==================================================================="
log_success "✅ WHISPERLIVE GPU CONFIGURATION COMPLETE"
log_info "==================================================================="
echo ""
log_info "WhisperLive Details:"
log_info "  - Location: ~/whisperlive/WhisperLive"
log_info "  - Service: whisperlive.service"
log_info "  - Port: 9090 (WebSocket)"
log_info "  - Backend: faster_whisper"
log_info "  - Model: small.en (cached)"
echo ""
log_info "Management (on GPU instance):"
log_info "  - Check status: sudo systemctl status whisperlive"
log_info "  - View logs: sudo journalctl -u whisperlive -f"
log_info "  - Restart: sudo systemctl restart whisperlive"
echo ""
log_info "Next Steps:"
log_info "  1. Run 030-configure-gpu-security.sh to allow edge→GPU access (port 9090)"
log_info "  2. Run 325-test-whisperlive-connection.sh to test connectivity"
log_info "  3. Run 320-update-edge-clients.sh to deploy browser clients"
echo ""
log_warn "IMPORTANT: Ensure security groups allow edge IP to access GPU port 9090"
echo ""
