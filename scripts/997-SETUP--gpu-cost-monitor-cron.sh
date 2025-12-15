#!/bin/bash
#===============================================================================
# 997-SETUP--gpu-cost-monitor-cron.sh
# Setup cron to monitor AWS & RunPod GPU costs (idempotent)
#===============================================================================
#
# WHAT THIS SCRIPT DOES:
#   Sets up automatic monitoring of GPU resources on AWS and RunPod.
#   Every 5 minutes it:
#   - Checks for running GPU pods/instances
#   - Tracks costs ($X.XX/hr)
#   - Updates dashboard with 24-hour activity timeline
#   - Uploads to S3 for CloudFront hosting
#
#   Safe to run multiple times - removes existing job first (idempotent).
#
# USAGE:
#   ./scripts/997-SETUP--gpu-cost-monitor-cron.sh           # Install & show config
#   ./scripts/997-SETUP--gpu-cost-monitor-cron.sh --config  # Show configuration
#   ./scripts/997-SETUP--gpu-cost-monitor-cron.sh --status  # Check cron status
#   ./scripts/997-SETUP--gpu-cost-monitor-cron.sh --remove  # Remove cron job
#
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASHBOARD_SCRIPT="$SCRIPT_DIR/998-DASHBOARD--generate-gpu-status.sh"
LOG_FILE="/var/log/gpu-dashboard.log"
CRON_SCHEDULE="*/5 * * * *"
CRON_JOB="$CRON_SCHEDULE $DASHBOARD_SCRIPT >> $LOG_FILE 2>&1"
CRON_MARKER="998-DASHBOARD--generate-gpu-status"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

show_status() {
    echo "=== GPU Dashboard Cron Status ==="
    if crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
        echo -e "${GREEN}[INSTALLED]${NC} Cron job is active"
        echo ""
        echo "Schedule: Every 5 minutes"
        echo "Script:   $DASHBOARD_SCRIPT"
        echo "Log:      $LOG_FILE"
        echo ""
        echo "Current cron entry:"
        crontab -l | grep "$CRON_MARKER"
    else
        echo -e "${YELLOW}[NOT INSTALLED]${NC} Cron job is not set up"
        echo ""
        echo "Run: ./scripts/997-SETUP--gpu-cost-monitor-cron.sh"
    fi
}

remove_cron() {
    echo "Removing GPU dashboard cron job..."
    # Remove any existing dashboard cron entries
    crontab -l 2>/dev/null | grep -v "$CRON_MARKER" | crontab - 2>/dev/null || true
    echo -e "${GREEN}Done.${NC} Cron job removed."
}

show_config() {
    echo ""
    echo "==============================================================================="
    echo " GPU Cost Guardian - Configuration"
    echo "==============================================================================="
    echo ""
    echo "SCRIPTS:"
    echo "  Cron Setup:      $SCRIPT_DIR/997-SETUP--gpu-cost-monitor-cron.sh"
    echo "  Dashboard Gen:   $DASHBOARD_SCRIPT"
    echo "  Watchdog:        $SCRIPT_DIR/999-WATCHDOG--gpu-cost-guardian.sh"
    echo "  Event Logger:    $SCRIPT_DIR/lib/gpu-event-logger.sh"
    echo ""
    echo "FILES:"
    echo "  Cron Log:        $LOG_FILE"
    echo "  Event Log:       $SCRIPT_DIR/../logs/gpu-events.jsonl"
    echo "  Local Dashboard: $SCRIPT_DIR/../artifacts/gpu-dashboard.html"
    echo ""

    # Load .env if exists
    ENV_FILE="$SCRIPT_DIR/../.env"
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
        echo "S3 CONFIG (from .env):"
        echo "  S3 Bucket:       ${GPU_DASHBOARD_S3_BUCKET:-not set}"
        echo ""
        echo "URLS:"
        if [ -n "${GPU_DASHBOARD_S3_BUCKET:-}" ]; then
            echo "  Dashboard:       https://d2l28rla2hk7np.cloudfront.net/gpu-dashboard/index.html"
            echo "  CloudDrive:      https://d2l28rla2hk7np.cloudfront.net/index.html"
        fi
    else
        echo "ENV FILE: $ENV_FILE (not found)"
    fi
    echo ""
    echo "CRON STATUS:"
    if crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
        echo -e "  Status:          ${GREEN}INSTALLED${NC}"
        echo "  Schedule:        Every 5 minutes (*/5 * * * *)"
    else
        echo -e "  Status:          ${YELLOW}NOT INSTALLED${NC}"
    fi
    echo ""
    echo "==============================================================================="
    echo ""
}

install_cron() {
    echo "Setting up GPU dashboard cron job..."

    # First, remove any existing entries (idempotent)
    crontab -l 2>/dev/null | grep -v "$CRON_MARKER" > /tmp/crontab.tmp 2>/dev/null || true

    # Add the new entry
    echo "$CRON_JOB" >> /tmp/crontab.tmp

    # Install the new crontab
    crontab /tmp/crontab.tmp
    rm -f /tmp/crontab.tmp

    # Ensure log file exists and is writable
    if [ ! -f "$LOG_FILE" ]; then
        sudo touch "$LOG_FILE" 2>/dev/null || touch "$LOG_FILE"
        sudo chown $USER:$USER "$LOG_FILE" 2>/dev/null || true
    fi

    echo -e "${GREEN}Done.${NC} Cron job installed."

    # Show full configuration
    show_config
}

# Parse arguments
case "${1:-}" in
    --remove|-r)
        remove_cron
        ;;
    --status|-s)
        show_status
        ;;
    --config|-c)
        show_config
        ;;
    --help|-h)
        echo "Usage: $0 [--status|--config|--remove|--help]"
        echo ""
        echo "  (no args)   Install cron job (idempotent) and show config"
        echo "  --status    Show current cron status"
        echo "  --config    Show full configuration"
        echo "  --remove    Remove cron job"
        echo "  --help      Show this help"
        ;;
    *)
        install_cron
        ;;
esac
