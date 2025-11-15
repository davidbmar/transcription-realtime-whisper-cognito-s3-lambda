#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Script 530: GPU Cost Tracker
# ============================================================================
# Tracks GPU instance start/stop events and calculates costs. This script
# provides commands for logging GPU usage and querying cost history.
#
# What this does:
# 1. Log GPU start/stop events with timestamps
# 2. Calculate runtime and costs for sessions
# 3. Query usage history for any time period
# 4. Generate cost reports (24hr, 7d, 30d)
#
# Commands:
#   start <reason>           - Log GPU start event
#   stop <reason> [chunks]   - Log GPU stop event with optional chunk count
#   status                   - Show current GPU status and runtime
#   report [hours]           - Generate cost report (default: 24 hours)
#   query <hours>            - Query usage stats as JSON
#
# Requirements:
# - .env variables: GPU_INSTANCE_ID, GPU_HOURLY_COST
# - lib/gpu-cost-functions.sh library
# - AWS CLI configured with EC2 read access
# - bc installed (for cost calculations)
#
# Log file: /var/log/gpu-cost.log (requires sudo for writes)
#
# Examples:
#   ./530-gpu-cost-tracker.sh start "batch-transcription"
#   ./530-gpu-cost-tracker.sh stop "batch-complete" 150
#   ./530-gpu-cost-tracker.sh status
#   ./530-gpu-cost-tracker.sh report 24
# ============================================================================

# Resolve script path (handles symlinks)
if [ -L "${BASH_SOURCE[0]}" ]; then
    SCRIPT_REAL=$(readlink -f "${BASH_SOURCE[0]}")
else
    SCRIPT_REAL="${BASH_SOURCE[0]}"
fi
PROJECT_ROOT="$(cd "$(dirname "$SCRIPT_REAL")/.." && pwd)"

# Load environment and libraries
source "$PROJECT_ROOT/.env"
source "$PROJECT_ROOT/scripts/lib/common-functions.sh"
source "$PROJECT_ROOT/scripts/lib/gpu-cost-functions.sh"

# ============================================================================
# Configuration
# ============================================================================

GPU_ID="${GPU_INSTANCE_ID}"
HOURLY_COST="${GPU_HOURLY_COST:-0.526}"

# Validate required tools
if ! command -v bc &>/dev/null; then
    log_error "bc is required but not installed"
    log_info "Install with: sudo apt-get install -y bc"
    exit 1
fi

if ! command -v aws &>/dev/null; then
    log_error "AWS CLI is required but not installed"
    exit 1
fi

if [[ -z "$GPU_ID" ]]; then
    log_error "GPU_INSTANCE_ID not set in .env"
    exit 1
fi

# ============================================================================
# Helper Functions
# ============================================================================

show_usage() {
    echo "Usage: $0 <command> [arguments]"
    echo ""
    echo "Commands:"
    echo "  start <reason>           Log GPU start event"
    echo "  stop <reason> [chunks]   Log GPU stop event with optional chunk count"
    echo "  status                   Show current GPU status and runtime"
    echo "  report [hours]           Generate cost report (default: 24 hours)"
    echo "  query <hours>            Query usage stats as JSON"
    echo ""
    echo "Examples:"
    echo "  $0 start \"batch-transcription\""
    echo "  $0 stop \"batch-complete\" 150"
    echo "  $0 status"
    echo "  $0 report 24"
    echo "  $0 query 168  # Last 7 days"
    exit 1
}

get_gpu_state() {
    local state=$(aws ec2 describe-instances \
        --instance-ids "$GPU_ID" \
        --region "$AWS_REGION" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text 2>/dev/null)

    echo "$state"
}

show_status() {
    local state=$(get_gpu_state)

    echo "============================================"
    echo "GPU Instance Status"
    echo "============================================"
    echo ""
    echo "Instance ID:  $GPU_ID"
    echo "State:        $state"
    echo "Hourly Cost:  \$${HOURLY_COST}"
    echo ""

    if [[ "$state" == "running" ]]; then
        local last_start=$(gpu_get_last_start "$GPU_ID")

        if [[ -n "$last_start" ]]; then
            local runtime=$(gpu_get_current_runtime "$GPU_ID")
            local cost=$(calculate_cost "$runtime" "$HOURLY_COST")
            local formatted=$(format_duration "$runtime")

            echo "Current Session:"
            echo "  Started:       $(date -d @${last_start} '+%Y-%m-%d %H:%M:%S')"
            echo "  Runtime:       $formatted"
            echo "  Current Cost:  \$${cost}"
        else
            log_warn "GPU is running but no start event found in log"
        fi
    fi
    echo ""
}

# ============================================================================
# Main Command Handler
# ============================================================================

COMMAND="${1:-}"

case "$COMMAND" in
    start)
        REASON="${2:-manual}"

        echo "============================================"
        echo "530: Log GPU Start Event"
        echo "============================================"
        echo ""

        log_info "Logging GPU start event..."
        log_info "  Instance: $GPU_ID"
        log_info "  Reason:   $reason"
        log_info "  Time:     $(date)"

        gpu_log_start "$GPU_ID" "$REASON"

        echo ""
        log_success "GPU start event logged"
        log_info "Log file: $GPU_COST_LOG"
        ;;

    stop)
        REASON="${2:-manual}"
        CHUNKS="${3:-0}"

        echo "============================================"
        echo "530: Log GPU Stop Event"
        echo "============================================"
        echo ""

        # Calculate session runtime and cost
        local last_start=$(gpu_get_last_start "$GPU_ID")

        if [[ -n "$last_start" ]]; then
            local runtime=$(gpu_get_current_runtime "$GPU_ID")
            local cost=$(calculate_cost "$runtime" "$HOURLY_COST")
            local formatted=$(format_duration "$runtime")

            log_info "Session Summary:"
            log_info "  Started:  $(date -d @${last_start} '+%Y-%m-%d %H:%M:%S')"
            log_info "  Stopped:  $(date)"
            log_info "  Runtime:  $formatted"
            log_info "  Cost:     \$${cost}"
            log_info "  Chunks:   $CHUNKS"
            echo ""
        fi

        log_info "Logging GPU stop event..."
        log_info "  Instance: $GPU_ID"
        log_info "  Reason:   $REASON"
        log_info "  Chunks:   $CHUNKS"

        gpu_log_stop "$GPU_ID" "$REASON" "$CHUNKS"

        echo ""
        log_success "GPU stop event logged"
        log_info "Log file: $GPU_COST_LOG"
        ;;

    status)
        show_status
        ;;

    report)
        HOURS="${2:-24}"

        echo "============================================"
        echo "530: Generate GPU Cost Report"
        echo "============================================"
        echo ""

        gpu_generate_report "$HOURS"
        ;;

    query)
        HOURS="${2:-24}"

        if [[ -z "$HOURS" ]]; then
            log_error "Hours argument required for query command"
            show_usage
        fi

        gpu_get_usage_last_hours "$HOURS" "$GPU_ID"
        ;;

    *)
        log_error "Unknown command: $COMMAND"
        echo ""
        show_usage
        ;;
esac
