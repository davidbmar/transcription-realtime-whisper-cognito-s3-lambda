#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Script 540: GPU Usage Reporter
# ============================================================================
# Generates comprehensive reports on GPU usage, costs, and transcription
# activity. Provides insights into resource utilization and helps optimize
# scheduling and cost management.
#
# What this does:
# 1. Query GPU cost logs for specified time period
# 2. Calculate total runtime, costs, and transcription metrics
# 3. Show session breakdowns with timing and chunk counts
# 4. Display queue trends from scheduler logs
# 5. Generate formatted reports (text, JSON, or CSV)
#
# Report Types:
# - summary: Quick overview (default)
# - detailed: Full session list with metrics
# - json: Machine-readable JSON output
# - csv: Spreadsheet-compatible CSV
#
# Time Periods:
# - 24h: Last 24 hours (default)
# - 7d: Last 7 days
# - 30d: Last 30 days
# - custom: Specify hours (e.g., 168 for last week)
#
# Usage:
#   ./540-gpu-usage-reporter.sh                    # 24h summary
#   ./540-gpu-usage-reporter.sh 7d                 # 7 day summary
#   ./540-gpu-usage-reporter.sh 24h detailed       # Detailed 24h report
#   ./540-gpu-usage-reporter.sh 30d json           # JSON format
#   ./540-gpu-usage-reporter.sh 168                # Custom: last 7 days (168h)
#
# Requirements:
# - lib/gpu-cost-functions.sh library
# - /var/log/gpu-cost.log (created by script 530)
# - /var/log/batch-queue.log (created by script 535)
# - .env variables: GPU_INSTANCE_ID, GPU_HOURLY_COST
# - bc installed
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

# Parse arguments
PERIOD_ARG="${1:-24h}"
FORMAT="${2:-summary}"

# Convert period to hours
case "$PERIOD_ARG" in
    24h|24) HOURS=24 ;;
    7d|7|168h) HOURS=168 ;;
    30d|30|720h) HOURS=720 ;;
    *h) HOURS="${PERIOD_ARG%h}" ;;  # Custom hours (e.g., "48h")
    *) HOURS="$PERIOD_ARG" ;;        # Assume numeric hours
esac

# Validate format
case "$FORMAT" in
    summary|detailed|json|csv) ;;
    *)
        log_error "Invalid format: $FORMAT"
        log_info "Valid formats: summary, detailed, json, csv"
        exit 1
        ;;
esac

GPU_ID="${GPU_INSTANCE_ID}"
QUEUE_LOG="/var/log/batch-queue.log"

# ============================================================================
# Report Generation Functions
# ============================================================================

# Generate summary report
generate_summary_report() {
    local hours="$1"

    echo "============================================"
    echo "GPU Usage Summary - Last ${hours} Hours"
    echo "============================================"
    echo ""

    # Get GPU usage stats
    local stats=$(gpu_get_usage_last_hours "$hours" "$GPU_ID")

    local runtime=$(echo "$stats" | jq -r '.total_runtime_seconds')
    local formatted=$(echo "$stats" | jq -r '.total_runtime_formatted')
    local cost=$(echo "$stats" | jq -r '.total_cost_usd')
    local sessions=$(echo "$stats" | jq -r '.sessions')
    local chunks=$(echo "$stats" | jq -r '.chunks_processed')

    echo "GPU Utilization:"
    echo "  Total Runtime:     $formatted ($runtime seconds)"
    echo "  Total Cost:        \$${cost} USD"
    echo "  Sessions:          $sessions"
    echo ""

    echo "Transcription Activity:"
    echo "  Chunks Processed:  $chunks"

    if [[ $chunks -gt 0 && $runtime -gt 0 ]]; then
        local chunks_per_min=$(echo "scale=1; ($chunks * 60) / $runtime" | bc)
        local seconds_per_chunk=$(echo "scale=1; $runtime / $chunks" | bc)
        echo "  Throughput:        $chunks_per_min chunks/min"
        echo "  Avg Time/Chunk:    ${seconds_per_chunk}s"
    fi

    echo ""

    # Calculate utilization percentage
    local period_seconds=$((hours * 3600))
    if [[ $period_seconds -gt 0 ]]; then
        local utilization=$(echo "scale=1; ($runtime * 100) / $period_seconds" | bc)
        echo "Resource Utilization:"
        echo "  GPU Uptime:        ${utilization}% of $hours hours"

        if [[ $sessions -gt 0 ]]; then
            local avg_session=$((runtime / sessions))
            echo "  Avg Session:       $(format_duration $avg_session)"
        fi
    fi

    echo ""

    # Show queue trends if available
    if [[ -f "$QUEUE_LOG" ]]; then
        echo "Queue Trends:"
        local queue_stats=$(get_queue_stats_for_report "$hours")
        local trend=$(echo "$queue_stats" | jq -r '.trend')
        local avg=$(echo "$queue_stats" | jq -r '.avg_queue')
        local current=$(echo "$queue_stats" | jq -r '.current_queue')
        local samples=$(echo "$queue_stats" | jq -r '.samples')

        echo "  Current Queue:     $current chunks"
        echo "  Average Queue:     $avg chunks"
        echo "  Trend:             $trend"
        echo "  Data Points:       $samples"
    fi

    echo ""
}

# Generate detailed report
generate_detailed_report() {
    local hours="$1"

    generate_summary_report "$hours"

    echo "============================================"
    echo "Session Details"
    echo "============================================"
    echo ""

    gpu_get_sessions_last_hours "$hours" "$GPU_ID"

    echo ""
}

# Generate JSON report
generate_json_report() {
    local hours="$1"

    local gpu_stats=$(gpu_get_usage_last_hours "$hours" "$GPU_ID")
    local queue_stats=$(get_queue_stats_for_report "$hours")

    # Combine stats into single JSON
    jq -n \
        --argjson gpu "$gpu_stats" \
        --argjson queue "$queue_stats" \
        '{
            "period_hours": $gpu.period_hours,
            "generated_at": (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
            "gpu": $gpu,
            "queue": $queue
        }'
}

# Generate CSV report
generate_csv_report() {
    local hours="$1"

    # CSV header
    echo "timestamp,event,instance_id,runtime_seconds,cost_usd,chunks_processed,reason"

    # Get session data
    local cutoff_epoch=$(($(date +%s) - (hours * 3600)))
    local gpu_log="${GPU_COST_LOG:-/var/log/gpu-cost.log}"

    if [[ ! -f "$gpu_log" ]]; then
        return 0
    fi

    local last_start_epoch=""
    local last_start_timestamp=""
    local last_start_reason=""

    while IFS='|' read -r timestamp epoch event instance reason details; do
        if [[ $epoch -lt $cutoff_epoch ]]; then
            continue
        fi

        if [[ -n "$GPU_ID" && "$instance" != "$GPU_ID" ]]; then
            continue
        fi

        if [[ "$event" == "START" ]]; then
            last_start_epoch="$epoch"
            last_start_timestamp="$timestamp"
            last_start_reason="$reason"
        elif [[ "$event" == "STOP" && -n "$last_start_epoch" ]]; then
            local runtime=$((epoch - last_start_epoch))
            local cost=$(calculate_cost "$runtime")
            local chunks="0"

            if [[ "$details" =~ chunks=([0-9]+) ]]; then
                chunks="${BASH_REMATCH[1]}"
            fi

            echo "${last_start_timestamp},session,${instance},${runtime},${cost},${chunks},${last_start_reason}"

            last_start_epoch=""
        fi
    done < "$gpu_log"
}

# Get queue stats (wrapper for error handling)
get_queue_stats_for_report() {
    local hours="$1"
    local cutoff_epoch=$(($(date +%s) - (hours * 3600)))

    if [[ ! -f "$QUEUE_LOG" ]]; then
        echo '{"trend":"no-data","avg_queue":0,"current_queue":0,"samples":0}'
        return 0
    fi

    local total=0
    local count=0
    local last_size=0

    while IFS='|' read -r timestamp epoch action chunk_count threshold; do
        if [[ $epoch -lt $cutoff_epoch ]]; then
            continue
        fi

        total=$((total + chunk_count))
        count=$((count + 1))
        last_size=$chunk_count
    done < "$QUEUE_LOG"

    if [[ $count -eq 0 ]]; then
        echo '{"trend":"no-data","avg_queue":0,"current_queue":0,"samples":0}'
        return 0
    fi

    local avg=$((total / count))
    local trend="stable"

    if [[ $last_size -gt $((avg + avg / 4)) ]]; then
        trend="growing"
    elif [[ $last_size -lt $((avg - avg / 4)) ]]; then
        trend="shrinking"
    fi

    cat <<EOF
{
  "trend": "$trend",
  "avg_queue": $avg,
  "current_queue": $last_size,
  "samples": $count
}
EOF
}

# ============================================================================
# Main Report Generation
# ============================================================================

echo "============================================"
echo "540: GPU Usage Reporter"
echo "============================================"
echo ""
log_info "Report Configuration:"
log_info "  Period:  $HOURS hours"
log_info "  Format:  $FORMAT"
log_info "  GPU:     $GPU_ID"
echo ""

case "$FORMAT" in
    summary)
        generate_summary_report "$HOURS"
        ;;
    detailed)
        generate_detailed_report "$HOURS"
        ;;
    json)
        generate_json_report "$HOURS"
        ;;
    csv)
        generate_csv_report "$HOURS"
        ;;
esac

# Export function for use by other scripts
export -f get_queue_stats_for_report
