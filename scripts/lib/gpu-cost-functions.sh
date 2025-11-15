#!/bin/bash
#
# GPU Cost Tracking Library
#
# This library provides shared functionality for tracking GPU usage and costs:
# - Log GPU start/stop events
# - Calculate runtime and costs
# - Query usage history
# - Generate cost reports
#
# Usage: source this file in any script that controls GPU instances
#

# =============================================================================
# CONFIGURATION
# =============================================================================

# GPU cost log file location
GPU_COST_LOG="${GPU_COST_LOG:-/var/log/gpu-cost.log}"

# Ensure log directory exists
ensure_cost_log_dir() {
    local log_dir=$(dirname "$GPU_COST_LOG")
    if [[ ! -d "$log_dir" ]]; then
        sudo mkdir -p "$log_dir"
        sudo chmod 755 "$log_dir"
    fi

    if [[ ! -f "$GPU_COST_LOG" ]]; then
        sudo touch "$GPU_COST_LOG"
        sudo chmod 644 "$GPU_COST_LOG"
    fi
}

# =============================================================================
# GPU EVENT LOGGING
# =============================================================================

# Log GPU start event
# Usage: gpu_log_start <instance_id> <reason>
gpu_log_start() {
    local instance_id="$1"
    local reason="${2:-manual}"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local epoch=$(date +%s)

    ensure_cost_log_dir

    # Log format: TIMESTAMP|EPOCH|EVENT|INSTANCE_ID|REASON|DETAILS
    echo "${timestamp}|${epoch}|START|${instance_id}|${reason}|" | sudo tee -a "$GPU_COST_LOG" >/dev/null

    log_info "Logged GPU start: $instance_id (reason: $reason)"
}

# Log GPU stop event
# Usage: gpu_log_stop <instance_id> <reason> <chunks_processed>
gpu_log_stop() {
    local instance_id="$1"
    local reason="${2:-manual}"
    local chunks_processed="${3:-0}"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local epoch=$(date +%s)

    ensure_cost_log_dir

    # Log format: TIMESTAMP|EPOCH|EVENT|INSTANCE_ID|REASON|CHUNKS_PROCESSED
    echo "${timestamp}|${epoch}|STOP|${instance_id}|${reason}|chunks=${chunks_processed}" | sudo tee -a "$GPU_COST_LOG" >/dev/null

    log_info "Logged GPU stop: $instance_id (reason: $reason, chunks: $chunks_processed)"
}

# =============================================================================
# COST CALCULATION
# =============================================================================

# Calculate cost for a time period
# Usage: calculate_cost <seconds> <hourly_rate>
calculate_cost() {
    local seconds="$1"
    local hourly_rate="${2:-$GPU_HOURLY_COST}"

    if [[ -z "$hourly_rate" ]]; then
        log_error "GPU_HOURLY_COST not set"
        return 1
    fi

    # Calculate cost: (seconds / 3600) * hourly_rate
    # Use bc for floating point arithmetic
    echo "scale=4; ($seconds / 3600) * $hourly_rate" | bc
}

# Format seconds to human-readable duration
# Usage: format_duration <seconds>
format_duration() {
    local seconds="$1"
    local hours=$((seconds / 3600))
    local minutes=$(((seconds % 3600) / 60))
    local secs=$((seconds % 60))

    if [[ $hours -gt 0 ]]; then
        printf "%dh %dm %ds" $hours $minutes $secs
    elif [[ $minutes -gt 0 ]]; then
        printf "%dm %ds" $minutes $secs
    else
        printf "%ds" $secs
    fi
}

# =============================================================================
# USAGE QUERIES
# =============================================================================

# Get the last start event for an instance
# Usage: gpu_get_last_start <instance_id>
# Returns: epoch timestamp or empty if no start found
gpu_get_last_start() {
    local instance_id="$1"

    if [[ ! -f "$GPU_COST_LOG" ]]; then
        return 1
    fi

    # Find most recent START event for this instance
    grep "|START|${instance_id}|" "$GPU_COST_LOG" | tail -1 | cut -d'|' -f2
}

# Calculate runtime for current session
# Usage: gpu_get_current_runtime <instance_id>
# Returns: seconds since last start
gpu_get_current_runtime() {
    local instance_id="$1"
    local last_start=$(gpu_get_last_start "$instance_id")

    if [[ -z "$last_start" ]]; then
        echo "0"
        return 1
    fi

    local now=$(date +%s)
    echo $((now - last_start))
}

# Get GPU usage for last N hours
# Usage: gpu_get_usage_last_hours <hours> [instance_id]
# Returns: JSON-formatted usage stats
gpu_get_usage_last_hours() {
    local hours="$1"
    local instance_id="${2:-$GPU_INSTANCE_ID}"
    local cutoff_epoch=$(($(date +%s) - (hours * 3600)))

    if [[ ! -f "$GPU_COST_LOG" ]]; then
        echo '{"total_runtime_seconds":0,"total_cost_usd":0,"sessions":0,"chunks_processed":0}'
        return 0
    fi

    local total_runtime=0
    local session_count=0
    local total_chunks=0
    local last_start=""

    # Process log entries since cutoff
    while IFS='|' read -r timestamp epoch event instance reason details; do
        # Skip entries before cutoff
        if [[ $epoch -lt $cutoff_epoch ]]; then
            continue
        fi

        # Only process events for specified instance
        if [[ -n "$instance_id" && "$instance" != "$instance_id" ]]; then
            continue
        fi

        if [[ "$event" == "START" ]]; then
            last_start="$epoch"
        elif [[ "$event" == "STOP" && -n "$last_start" ]]; then
            local runtime=$((epoch - last_start))
            total_runtime=$((total_runtime + runtime))
            session_count=$((session_count + 1))

            # Extract chunks processed from details
            if [[ "$details" =~ chunks=([0-9]+) ]]; then
                total_chunks=$((total_chunks + ${BASH_REMATCH[1]}))
            fi

            last_start=""
        fi
    done < "$GPU_COST_LOG"

    # If there's an unclosed start, count time up to now
    if [[ -n "$last_start" ]]; then
        local now=$(date +%s)
        local runtime=$((now - last_start))
        total_runtime=$((total_runtime + runtime))
        session_count=$((session_count + 1))
    fi

    # Calculate total cost
    local total_cost=$(calculate_cost "$total_runtime")

    # Output JSON
    cat <<EOF
{
  "total_runtime_seconds": $total_runtime,
  "total_runtime_formatted": "$(format_duration $total_runtime)",
  "total_cost_usd": $total_cost,
  "sessions": $session_count,
  "chunks_processed": $total_chunks,
  "period_hours": $hours,
  "instance_id": "$instance_id"
}
EOF
}

# Get detailed session list for last N hours
# Usage: gpu_get_sessions_last_hours <hours> [instance_id]
gpu_get_sessions_last_hours() {
    local hours="$1"
    local instance_id="${2:-$GPU_INSTANCE_ID}"
    local cutoff_epoch=$(($(date +%s) - (hours * 3600)))

    if [[ ! -f "$GPU_COST_LOG" ]]; then
        return 0
    fi

    local last_start_epoch=""
    local last_start_timestamp=""
    local last_start_reason=""

    # Print header
    printf "%-20s %-20s %-10s %-15s %-10s %-10s\n" "START" "STOP" "DURATION" "COST" "CHUNKS" "REASON"
    printf "%s\n" "------------------------------------------------------------------------------------"

    # Process log entries since cutoff
    while IFS='|' read -r timestamp epoch event instance reason details; do
        # Skip entries before cutoff
        if [[ $epoch -lt $cutoff_epoch ]]; then
            continue
        fi

        # Only process events for specified instance
        if [[ -n "$instance_id" && "$instance" != "$instance_id" ]]; then
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

            # Extract chunks from details
            if [[ "$details" =~ chunks=([0-9]+) ]]; then
                chunks="${BASH_REMATCH[1]}"
            fi

            printf "%-20s %-20s %-10s \$%-14s %-10s %-10s\n" \
                "${last_start_timestamp:11:8}" \
                "${timestamp:11:8}" \
                "$(format_duration $runtime)" \
                "$cost" \
                "$chunks" \
                "$last_start_reason"

            last_start_epoch=""
        fi
    done < "$GPU_COST_LOG"

    # Handle unclosed session
    if [[ -n "$last_start_epoch" ]]; then
        local now=$(date +%s)
        local runtime=$((now - last_start_epoch))
        local cost=$(calculate_cost "$runtime")

        printf "%-20s %-20s %-10s \$%-14s %-10s %-10s\n" \
            "${last_start_timestamp:11:8}" \
            "RUNNING" \
            "$(format_duration $runtime)" \
            "$cost" \
            "?" \
            "$last_start_reason"
    fi
}

# =============================================================================
# REPORT GENERATION
# =============================================================================

# Generate human-readable cost report for last N hours
# Usage: gpu_generate_report <hours>
gpu_generate_report() {
    local hours="${1:-24}"
    local stats=$(gpu_get_usage_last_hours "$hours")

    echo "============================================"
    echo "GPU Usage Report - Last ${hours} Hours"
    echo "============================================"
    echo ""

    # Extract values from JSON
    local runtime=$(echo "$stats" | grep -oP '"total_runtime_seconds":\s*\K\d+')
    local formatted=$(echo "$stats" | grep -oP '"total_runtime_formatted":\s*"\K[^"]+')
    local cost=$(echo "$stats" | grep -oP '"total_cost_usd":\s*\K[0-9.]+')
    local sessions=$(echo "$stats" | grep -oP '"sessions":\s*\K\d+')
    local chunks=$(echo "$stats" | grep -oP '"chunks_processed":\s*\K\d+')

    echo "Total Runtime:     $formatted ($runtime seconds)"
    echo "Total Cost:        \$${cost} USD"
    echo "Sessions:          $sessions"
    echo "Chunks Processed:  $chunks"
    echo ""

    if [[ $sessions -gt 0 ]]; then
        echo "Session Details:"
        echo "------------------------------------------------------------------------------------"
        gpu_get_sessions_last_hours "$hours"
        echo ""
    fi
}

# Export functions
export -f ensure_cost_log_dir
export -f gpu_log_start
export -f gpu_log_stop
export -f calculate_cost
export -f format_duration
export -f gpu_get_last_start
export -f gpu_get_current_runtime
export -f gpu_get_usage_last_hours
export -f gpu_get_sessions_last_hours
export -f gpu_generate_report
