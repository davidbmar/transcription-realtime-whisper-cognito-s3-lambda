#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Script 830: Setup Crontab Entries
# ============================================================================
# Configures all scheduled tasks for the CloudDrive transcription system.
# This script is idempotent - safe to run multiple times.
#
# What this does:
# 1. Shows current crontab state
# 2. Removes any existing project cron entries (clean slate)
# 3. Adds all required cron jobs:
#    - Dashboard generator (every 2 min)
#    - GPU cost watchdog (every 15 min)
#    - Batch transcription scheduler (every hour)
# 4. Verifies the setup
#
# Cron Jobs Configured:
# ┌─────────────────────────────────────────────────────────────────────────┐
# │ Schedule      │ Script                              │ Purpose           │
# ├───────────────┼─────────────────────────────────────┼───────────────────┤
# │ */2 * * * *   │ 998-DASHBOARD--generate-gpu-status  │ Update dashboard  │
# │ */15 * * * *  │ 999-WATCHDOG--gpu-cost-guardian     │ Kill idle GPUs    │
# │ 0 * * * *     │ 535-smart-batch-scheduler           │ Process queue     │
# └─────────────────────────────────────────────────────────────────────────┘
#
# Requirements:
# - Running as user with crontab access
#
# Total time: ~5 seconds
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
echo "830: Setup Crontab Entries"
echo "============================================"
echo ""

log_info "This script will:"
log_info "  1. Show current crontab state"
log_info "  2. Remove existing project cron entries"
log_info "  3. Add all required cron jobs"
log_info "  4. Verify the setup"
echo ""

# ============================================================================
# Configuration
# ============================================================================

SCRIPTS_DIR="$PROJECT_ROOT/scripts"

# Define all cron jobs
# Format: "schedule|script|log_file|description"
CRON_JOBS=(
    "*/2 * * * *|998-DASHBOARD--generate-gpu-status.sh|/var/log/gpu-dashboard.log|GPU dashboard generator"
    "*/15 * * * *|999-WATCHDOG--gpu-cost-guardian.sh --kill --cron|/var/log/gpu-watchdog.log|GPU cost watchdog"
    "0 * * * *|535-smart-batch-scheduler.sh|/var/log/batch-scheduler.log|Batch transcription scheduler"
)

# Marker to identify our cron entries
CRON_MARKER="# CloudDrive-Transcription"

# ============================================================================
# Main Implementation
# ============================================================================

log_info "Step 1: Checking current crontab state"
echo ""
echo "Current crontab:"
echo "─────────────────────────────────────────"
crontab -l 2>/dev/null || echo "(empty)"
echo "─────────────────────────────────────────"
echo ""
log_success "Step 1 completed"
echo ""

log_info "Step 2: Removing existing project cron entries"

# Get current crontab, remove our entries, keep others
CURRENT_CRONTAB=$(crontab -l 2>/dev/null || true)

# Remove lines containing our scripts or marker
CLEANED_CRONTAB=$(echo "$CURRENT_CRONTAB" | grep -v -E "(998-DASHBOARD|999-WATCHDOG|535-smart-batch-scheduler|$CRON_MARKER)" || true)

log_success "Step 2 completed"
echo ""

log_info "Step 3: Adding cron jobs"

# Build new crontab
NEW_CRONTAB="$CLEANED_CRONTAB"

# Add header if we have existing entries
if [ -n "$NEW_CRONTAB" ]; then
    NEW_CRONTAB="${NEW_CRONTAB}

"
fi

# Add marker and our jobs
NEW_CRONTAB="${NEW_CRONTAB}${CRON_MARKER} - Managed by 830-setup-crontab.sh
"

for job in "${CRON_JOBS[@]}"; do
    IFS='|' read -r schedule script log_file description <<< "$job"

    # Verify script exists
    script_name=$(echo "$script" | awk '{print $1}')
    if [ ! -f "$SCRIPTS_DIR/$script_name" ]; then
        log_warn "Script not found: $script_name (skipping)"
        continue
    fi

    # Add cron entry
    cron_line="$schedule $SCRIPTS_DIR/$script >> $log_file 2>&1"
    NEW_CRONTAB="${NEW_CRONTAB}${cron_line}
"
    log_info "  Added: $description"
    log_info "         $schedule -> $script_name"
done

# Install new crontab
echo "$NEW_CRONTAB" | crontab -

log_success "Step 3 completed"
echo ""

log_info "Step 4: Verifying crontab setup"
echo ""
echo "New crontab:"
echo "─────────────────────────────────────────"
crontab -l
echo "─────────────────────────────────────────"
echo ""

# Count our entries
OUR_ENTRIES=$(crontab -l 2>/dev/null | grep -c "$CRON_MARKER" || echo "0")
TOTAL_JOBS=$(crontab -l 2>/dev/null | grep -cE "^\*/|^[0-9]" || echo "0")

log_success "Step 4 completed"
echo ""

# ============================================================================
# Success Reporting
# ============================================================================

echo ""
log_info "==================================================================="
log_success "CRONTAB SETUP COMPLETED"
log_info "==================================================================="
echo ""
log_info "Summary:"
log_info "  - Total cron jobs installed: $TOTAL_JOBS"
log_info "  - Project cron jobs: ${#CRON_JOBS[@]}"
echo ""
log_info "Scheduled Tasks:"
log_info "  ┌─────────────┬─────────────────────────────────┬─────────────────────┐"
log_info "  │ Schedule    │ Script                          │ Purpose             │"
log_info "  ├─────────────┼─────────────────────────────────┼─────────────────────┤"
log_info "  │ */2 * * * * │ 998-DASHBOARD                   │ Update GPU dashboard│"
log_info "  │ */15 * * * *│ 999-WATCHDOG                    │ Kill idle GPUs      │"
log_info "  │ 0 * * * *   │ 535-smart-batch-scheduler       │ Process batch queue │"
log_info "  └─────────────┴─────────────────────────────────┴─────────────────────┘"
echo ""
log_info "Log Files:"
log_info "  - Dashboard:  /var/log/gpu-dashboard.log"
log_info "  - Watchdog:   /var/log/gpu-watchdog.log"
log_info "  - Scheduler:  /var/log/batch-scheduler.log"
echo ""
log_info "To view crontab: crontab -l"
log_info "To edit crontab: crontab -e"
log_info "To remove all:   crontab -r"
echo ""
