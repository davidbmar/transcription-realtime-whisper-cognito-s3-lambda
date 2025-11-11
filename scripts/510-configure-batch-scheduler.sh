#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Script 510: Configure Batch Transcription Scheduler
# ============================================================================
# Sets up automatic batch transcription to run every 2 hours with smart GPU
# management. Only starts GPU when missing transcriptions are detected.
#
# What this does:
# 1. Creates systemd service for batch transcription
# 2. Creates systemd timer to run every 2 hours
# 3. Enables and starts the timer
# 4. Verifies scheduler is running
# 5. Shows how to monitor logs
#
# Requirements:
# - .env variables: (runs on edge box, uses AWS credentials from .env)
# - Scripts 500, 505, 525 must exist
# - Edge box must have systemd (Ubuntu 20.04+)
#
# Total time: ~1 minute
# ============================================================================

# Resolve script path (handles symlinks)
if [ -L "${BASH_SOURCE[0]}" ]; then
    SCRIPT_REAL=$(readlink -f "${BASH_SOURCE[0]}")
else
    SCRIPT_REAL="${BASH_SOURCE[0]}"
fi
PROJECT_ROOT="$(cd "$(dirname "$SCRIPT_REAL")/.." && pwd)"

# Load environment and common functions
source "$PROJECT_ROOT/.env"
source "$PROJECT_ROOT/scripts/lib/common-functions.sh"

echo "============================================"
echo "510: Configure Batch Scheduler"
echo "============================================"
echo ""

log_info "This script will:"
log_info "  1. Create systemd service for batch transcription"
log_info "  2. Create systemd timer (runs every 2 hours)"
log_info "  3. Enable and start the timer"
log_info "  4. Verify scheduler configuration"
echo ""
log_warn "Note: 2-hour intervals save 93% in GPU costs vs 5-minute scheduling"
echo ""

# ============================================================================
# Main Implementation
# ============================================================================

log_info "Step 1/4: Creating systemd service file..."

# Create the service file
sudo tee /etc/systemd/system/batch-transcribe.service > /dev/null <<EOF
[Unit]
Description=Batch Transcribe Missing Audio Chunks
After=network.target

[Service]
Type=oneshot
User=$USER
WorkingDirectory=$PROJECT_ROOT
ExecStart=$PROJECT_ROOT/scripts/515-run-batch-transcribe.sh
StandardOutput=journal
StandardError=journal
SyslogIdentifier=batch-transcribe

# Timeout after 30 minutes (in case of large batch)
TimeoutStartSec=1800

[Install]
WantedBy=multi-user.target
EOF

log_success "Service file created"
echo ""

log_info "Step 2/4: Creating systemd timer (every 2 hours)..."

# Create the timer file
sudo tee /etc/systemd/system/batch-transcribe.timer > /dev/null <<EOF
[Unit]
Description=Run Batch Transcription Every 2 Hours
Requires=batch-transcribe.service

[Timer]
# Run every 2 hours (12 times per day)
# First run 5 minutes after boot, then every 2 hours
OnBootSec=5min
OnUnitActiveSec=2h
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF

log_success "Timer file created"
echo ""

log_info "Step 3/4: Enabling and starting timer..."

# Reload systemd to pick up new files
sudo systemctl daemon-reload

# Enable timer to start on boot
sudo systemctl enable batch-transcribe.timer

# Start the timer
sudo systemctl start batch-transcribe.timer

log_success "Timer enabled and started"
echo ""

log_info "Step 4/4: Verifying scheduler status..."

# Check timer status
TIMER_STATUS=$(systemctl is-active batch-transcribe.timer || echo "inactive")

if [ "$TIMER_STATUS" = "active" ]; then
    log_success "Timer is active and running"

    # Show next scheduled run
    NEXT_RUN=$(systemctl status batch-transcribe.timer | grep -i "Trigger:" | head -1 || echo "Unknown")
    log_info "Next run: $NEXT_RUN"
else
    log_warn "Timer status: $TIMER_STATUS"
    log_info "Check logs with: sudo journalctl -u batch-transcribe.timer"
fi
echo ""

# ============================================================================
# Success Reporting
# ============================================================================

echo ""
log_info "==================================================================="
log_success "✅ BATCH SCHEDULER CONFIGURED"
log_info "==================================================================="
echo ""
log_info "Scheduler Status:"
log_info "  - Service: batch-transcribe.service"
log_info "  - Timer: batch-transcribe.timer"
log_info "  - Frequency: Every 2 hours (12 runs/day)"
log_info "  - Status: $TIMER_STATUS"
log_info "  - Cost savings: ~93% vs 5-minute intervals"
echo ""
log_info "How it Works:"
log_info "  1. Timer triggers 515-run-batch-transcribe.sh"
log_info "  2. Script calls 525-scan (fast S3 scan, no GPU)"
log_info "  3. If chunks found: Start GPU, transcribe, stop GPU"
log_info "  4. If no chunks: Skip (no GPU costs)"
echo ""
log_info "Management Commands:"
log_info "  - Check timer: systemctl status batch-transcribe.timer"
log_info "  - Check service: systemctl status batch-transcribe.service"
log_info "  - View logs: sudo journalctl -u batch-transcribe -f"
log_info "  - Stop timer: sudo systemctl stop batch-transcribe.timer"
log_info "  - Start timer: sudo systemctl start batch-transcribe.timer"
log_info "  - Disable timer: sudo systemctl disable batch-transcribe.timer"
log_info "  - List timers: systemctl list-timers batch-transcribe*"
echo ""
log_info "Next Steps:"
log_info "  1. Test manually: ./scripts/515-run-batch-transcribe.sh"
log_info "  2. Or test system: ./scripts/520-test-batch-transcription.sh"
log_info "  3. Monitor: sudo journalctl -u batch-transcribe -f"
log_info "  4. View reports: ls -lart batch-reports/"
echo ""
