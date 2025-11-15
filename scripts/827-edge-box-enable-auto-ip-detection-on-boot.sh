#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# 827: Setup Edge Box IP Auto-Detection
# ============================================================================
# Configures automatic IP change detection on edge box boot.
# This creates a systemd service that runs on every boot to:
# 1. Detect current edge box IP
# 2. Compare with stored IP in .env
# 3. Update configuration if changed
# 4. Regenerate SSL certificates
# 5. Restart Caddy container
#
# This eliminates manual intervention after EC2 stop/start cycles.
#
# Installation:
#   ./scripts/827-setup-edge-ip-autodetect.sh
#
# Verification:
#   sudo systemctl status edge-box-ip-check
#   sudo journalctl -u edge-box-ip-check -f
# ============================================================================

# Find repository root
if [ -L "${BASH_SOURCE[0]}" ]; then
    SCRIPT_REAL=$(readlink -f "${BASH_SOURCE[0]}")
else
    SCRIPT_REAL="${BASH_SOURCE[0]}"
fi
REPO_ROOT="$(cd "$(dirname "$SCRIPT_REAL")/.." && pwd)"

source "$REPO_ROOT/scripts/lib/common-functions.sh"
load_environment

echo "============================================"
echo "827: Setup Edge Box IP Auto-Detection"
echo "============================================"
echo ""

# ============================================================================
# Step 1: Verify We're on the Edge Box
# ============================================================================
log_info "Step 1/5: Verifying edge box environment..."

# Check if Caddy is installed/configured
if [ ! -d "$HOME/event-b/whisper-live-test" ] && [ ! -d "$HOME/event-b/whisper-live-edge" ]; then
    log_error "This doesn't appear to be an edge box"
    log_info "Caddy directories not found. Run script 305 first."
    exit 1
fi

log_success "✅ Edge box environment detected"
echo ""

# ============================================================================
# Step 2: Create Systemd Service File
# ============================================================================
log_info "Step 2/5: Creating systemd service..."

SCRIPT_PATH="$REPO_ROOT/scripts/825-update-edge-box-ip.sh"

# Create service file
sudo tee /etc/systemd/system/edge-box-ip-check.service > /dev/null << EOF
[Unit]
Description=Edge Box IP Change Detection and Update
After=network-online.target docker.service
Wants=network-online.target
# Wait for Docker to be ready (Caddy needs it)
Requires=docker.service

[Service]
Type=oneshot
User=$USER
WorkingDirectory=$REPO_ROOT
ExecStart=$SCRIPT_PATH
StandardOutput=journal
StandardError=journal
RemainAfterExit=yes
# Give Docker time to fully start
ExecStartPre=/bin/sleep 10

[Install]
WantedBy=multi-user.target
EOF

log_success "✅ Systemd service created: /etc/systemd/system/edge-box-ip-check.service"
echo ""

# ============================================================================
# Step 3: Enable and Start Service
# ============================================================================
log_info "Step 3/5: Enabling service to run on boot..."

sudo systemctl daemon-reload
sudo systemctl enable edge-box-ip-check.service

log_success "✅ Service enabled (will run on every boot)"
echo ""

# ============================================================================
# Step 4: Test the Service
# ============================================================================
log_info "Step 4/5: Testing service..."

log_info "Running service now to verify it works..."
if sudo systemctl start edge-box-ip-check.service; then
    log_success "✅ Service started successfully"

    # Wait a moment for it to complete
    sleep 3

    # Check status
    if sudo systemctl is-active --quiet edge-box-ip-check.service; then
        log_success "✅ Service is active"
    else
        log_warn "⚠️  Service completed (oneshot services don't stay running)"
    fi
else
    log_error "❌ Service failed to start"
    log_info "Check logs with: sudo journalctl -u edge-box-ip-check -n 50"
    exit 1
fi
echo ""

# ============================================================================
# Step 5: Show Service Status and Logs
# ============================================================================
log_info "Step 5/5: Verification..."
echo ""

log_info "Service Status:"
sudo systemctl status edge-box-ip-check.service --no-pager -l || true
echo ""

log_info "Recent Logs:"
sudo journalctl -u edge-box-ip-check -n 20 --no-pager || true
echo ""

# ============================================================================
# Success Summary
# ============================================================================
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                                                            ║"
echo "║    ✅ EDGE BOX IP AUTO-DETECTION CONFIGURED               ║"
echo "║                                                            ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
log_info "What happens now:"
echo ""
echo "  📍 Every time the edge box boots:"
echo "    1. Service detects current public IP"
echo "    2. Compares with IP stored in .env"
echo "    3. If changed:"
echo "       - Updates .env configuration"
echo "       - Regenerates SSL certificate"
echo "       - Restarts Caddy container"
echo "       - Redeploys UI with new WebSocket URL"
echo "    4. Logs everything to systemd journal"
echo ""
log_info "Useful Commands:"
echo "  • Check service status:  sudo systemctl status edge-box-ip-check"
echo "  • View logs:             sudo journalctl -u edge-box-ip-check -f"
echo "  • Run manually:          sudo systemctl start edge-box-ip-check"
echo "  • Disable:               sudo systemctl disable edge-box-ip-check"
echo ""
log_info "Manual Trigger:"
echo "  • You can also run:      ./scripts/825-update-edge-box-ip.sh"
echo "  • Or diagnose issues:    ./scripts/826-diagnose-edge-connection.sh"
echo ""
log_success "🎉 Edge box will now automatically handle IP changes!"
echo ""
log_warn "⚠️  Remember: You still need to accept the new SSL certificate"
echo "    in your browser after IP changes by visiting https://NEW_IP/healthz"
echo ""
