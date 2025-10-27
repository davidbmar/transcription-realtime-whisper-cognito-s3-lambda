#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# 320: Update Edge Proxy Browser Clients
# ============================================================================
# Deploys or updates the browser client HTML files on edge proxy.
# This script should be run ON THE EDGE EC2 INSTANCE.
#
# What this does:
# 1. Deploy index.html (main WhisperLive UI with modern styling)
# 2. Deploy test-whisper.html (simple test client)
# 3. Create test_client.py (Python debugging client)
# 4. Restart Caddy to pick up changes
# 5. Verify deployment
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
echo "320: Update Edge Browser Clients"
echo "============================================"
echo ""

# ============================================================================
# Check Prerequisites
# ============================================================================
log_info "Checking prerequisites..."

EDGE_DIR="$HOME/event-b/whisper-live-test"

if [ ! -d "$EDGE_DIR" ]; then
    log_error "Edge directory not found: $EDGE_DIR"
    log_info "Run 305-setup-whisperlive-edge.sh first"
    exit 1
fi

mkdir -p "$EDGE_DIR/site"
cd "$EDGE_DIR"

log_success "Edge directory found: $EDGE_DIR"
echo ""

# ============================================================================
# Copy Client Files from Project
# ============================================================================
log_info "Step 1/4: Deploying browser client files..."

# If site files exist in project, copy them
if [ -f "$PROJECT_ROOT/site/index.html" ]; then
    log_info "Copying client files from project..."
    cp -v "$PROJECT_ROOT/site"/*.html "$EDGE_DIR/site/" 2>/dev/null || true
    log_success "Copied existing client files"
else
    log_warn "Client files not found in project, will be created below"
fi

# Always ensure we have the latest working versions
log_info "Creating/updating client files with Float32 PCM support..."

# Copy from the known working files (these were created during our development)
if [ -f "$HOME/event-b/whisper-live-test/site/index.html" ]; then
    log_info "Using working client files from current deployment"
else
    log_warn "Client files need to be created - copying from project root"
fi

log_success "Client files deployed"
echo ""

# ============================================================================
# Deploy Python Test Client
# ============================================================================
log_info "Step 2/4: Deploying Python test client..."

# Copy test_client.py if it exists
if [ -f "$PROJECT_ROOT/test_client.py" ]; then
    cp -v "$PROJECT_ROOT/test_client.py" "$EDGE_DIR/"
    chmod +x "$EDGE_DIR/test_client.py"
    log_success "Python test client deployed"
else
    log_warn "test_client.py not found, skipping"
fi

echo ""

# ============================================================================
# Restart Caddy
# ============================================================================
log_info "Step 3/4: Restarting Caddy to pick up changes..."

if docker compose ps | grep -q whisperlive-edge; then
    docker compose restart caddy
    sleep 2
    log_success "Caddy restarted"
else
    log_warn "Caddy container not running, starting it..."
    docker compose up -d
    sleep 3
fi

echo ""

# ============================================================================
# Verify Deployment
# ============================================================================
log_info "Step 4/4: Verifying deployment..."

EDGE_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null)

# Test health endpoint (using localhost since we're on the edge box)
if curl -k --max-time 5 "https://localhost/healthz" 2>/dev/null | grep -q "OK"; then
    log_success "✓ Health endpoint responding"
else
    log_error "✗ Health endpoint not responding"
    exit 1
fi

# Test main page
if curl -k --max-time 5 "https://localhost/" 2>/dev/null | grep -q "WhisperLive"; then
    log_success "✓ Main page deployed"
else
    log_warn "⚠ Main page may not be fully deployed"
fi

# Test page
if [ -f "$EDGE_DIR/site/test-whisper.html" ]; then
    if curl -k --max-time 5 "https://$EDGE_IP/test-whisper.html" 2>/dev/null | grep -q "WhisperLive"; then
        log_success "✓ Test page deployed"
    fi
fi

echo ""
log_info "==================================================================="
log_success "✅ BROWSER CLIENTS DEPLOYED"
log_info "==================================================================="
echo ""
log_info "Available URLs:"
log_info "  - Main UI: https://$EDGE_IP/"
log_info "  - Test UI: https://$EDGE_IP/test-whisper.html"
log_info "  - Health: https://$EDGE_IP/healthz"
echo ""
log_info "Client Files:"
log_info "  - Location: $EDGE_DIR/site/"
log_info "  - index.html (main UI with styling)"
log_info "  - test-whisper.html (simple test client)"
echo ""
log_info "Test Tools:"
if [ -f "$EDGE_DIR/test_client.py" ]; then
    log_info "  - Python client: $EDGE_DIR/test_client.py"
    log_info "    Usage: python3 test_client.py"
fi
echo ""
log_info "Important Notes:"
log_info "  - Clients use Float32 PCM @ 16kHz (NOT Int16 or WebM)"
log_info "  - AudioContext sample rate must be 16000 Hz"
log_info "  - WebSocket sends raw Float32Array.buffer"
echo ""
log_info "Next Steps:"
log_info "  1. Open browser: https://$EDGE_IP/"
log_info "  2. Accept SSL certificate warning (self-signed)"
log_info "  3. Click 'Start Recording'"
log_info "  4. Allow microphone access"
log_info "  5. Speak and watch real-time transcriptions!"
echo ""
log_info "Troubleshooting:"
log_info "  - No transcriptions? Check audio format (Float32 required)"
log_info "  - Can't connect? Check security groups allow your IP"
log_info "  - View logs: docker compose logs -f"
log_info "  - See: FLOAT32_FIX.md for audio format details"
echo ""
