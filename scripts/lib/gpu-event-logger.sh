#!/bin/bash
#===============================================================================
# gpu-event-logger.sh
# Structured JSON logging for GPU events
#===============================================================================

# Log file location
GPU_EVENT_LOG="${GPU_EVENT_LOG:-/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/logs/gpu-events.jsonl}"

# Ensure log directory exists
mkdir -p "$(dirname "$GPU_EVENT_LOG")"

# Log a GPU event in JSON Lines format
# Usage: log_gpu_event "type" "provider" "resource_id" "action" "details"
log_gpu_event() {
    local EVENT_TYPE="$1"      # start, stop, terminate, idle_check, error
    local PROVIDER="$2"        # runpod, aws
    local RESOURCE_ID="$3"     # pod_id or instance_id
    local ACTION="$4"          # created, terminated, checked, warning
    local DETAILS="${5:-}"     # Additional JSON details

    local TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local HOSTNAME=$(hostname)

    # Build JSON event
    local EVENT=$(cat <<EOF
{"timestamp":"${TIMESTAMP}","type":"${EVENT_TYPE}","provider":"${PROVIDER}","resource_id":"${RESOURCE_ID}","action":"${ACTION}","host":"${HOSTNAME}","details":${DETAILS:-null}}
EOF
)

    # Append to log file
    echo "$EVENT" >> "$GPU_EVENT_LOG"

    # Also echo for immediate visibility
    echo "[GPU-EVENT] $EVENT"
}

# Log RunPod pod start
log_runpod_start() {
    local POD_ID="$1"
    local POD_NAME="$2"
    local GPU_TYPE="$3"
    local COST_PER_HR="${4:-0}"
    local DOCKER_IMAGE="${5:-unknown}"
    local IDLE_TIMEOUT="${6:-600}"

    log_gpu_event "start" "runpod" "$POD_ID" "created" \
        "{\"name\":\"${POD_NAME}\",\"gpu\":\"${GPU_TYPE}\",\"cost_per_hr\":${COST_PER_HR},\"image\":\"${DOCKER_IMAGE}\",\"idle_timeout\":${IDLE_TIMEOUT}}"
}

# Log RunPod pod termination
log_runpod_terminate() {
    local POD_ID="$1"
    local REASON="$2"
    local RUNTIME_MIN="${3:-0}"
    local TOTAL_COST="${4:-0}"

    log_gpu_event "terminate" "runpod" "$POD_ID" "terminated" \
        "{\"reason\":\"${REASON}\",\"runtime_min\":${RUNTIME_MIN},\"estimated_cost\":${TOTAL_COST}}"
}

# Log RunPod idle check
log_runpod_check() {
    local POD_ID="$1"
    local STATUS="$2"           # active, idle, starting
    local GPU_UTIL="$3"
    local RUNTIME_MIN="$4"
    local POD_NAME="${5:-}"     # Optional pod name

    if [ -n "$POD_NAME" ]; then
        log_gpu_event "idle_check" "runpod" "$POD_ID" "checked" \
            "{\"status\":\"${STATUS}\",\"gpu_util\":${GPU_UTIL},\"runtime_min\":${RUNTIME_MIN},\"name\":\"${POD_NAME}\"}"
    else
        log_gpu_event "idle_check" "runpod" "$POD_ID" "checked" \
            "{\"status\":\"${STATUS}\",\"gpu_util\":${GPU_UTIL},\"runtime_min\":${RUNTIME_MIN}}"
    fi
}

# Log AWS instance start
log_aws_start() {
    local INSTANCE_ID="$1"
    local INSTANCE_TYPE="$2"
    local NAME="$3"
    local COST_PER_HR="$4"

    log_gpu_event "start" "aws" "$INSTANCE_ID" "created" \
        "{\"name\":\"${NAME}\",\"instance_type\":\"${INSTANCE_TYPE}\",\"cost_per_hr\":${COST_PER_HR}}"
}

# Log AWS instance termination
log_aws_terminate() {
    local INSTANCE_ID="$1"
    local REASON="$2"
    local RUNTIME_MIN="${3:-0}"
    local TOTAL_COST="${4:-0}"

    log_gpu_event "terminate" "aws" "$INSTANCE_ID" "terminated" \
        "{\"reason\":\"${REASON}\",\"runtime_min\":${RUNTIME_MIN},\"estimated_cost\":${TOTAL_COST}}"
}

# Log AWS idle check
log_aws_check() {
    local INSTANCE_ID="$1"
    local STATUS="$2"
    local RUNTIME_MIN="$3"

    log_gpu_event "idle_check" "aws" "$INSTANCE_ID" "checked" \
        "{\"status\":\"${STATUS}\",\"runtime_min\":${RUNTIME_MIN}}"
}

# Log error
log_gpu_error() {
    local PROVIDER="$1"
    local RESOURCE_ID="$2"
    local ERROR_MSG="$3"

    log_gpu_event "error" "$PROVIDER" "$RESOURCE_ID" "error" \
        "{\"message\":\"${ERROR_MSG}\"}"
}

# Get events from last N hours (for dashboard)
get_recent_events() {
    local HOURS="${1:-24}"
    local CUTOFF=$(date -u -d "${HOURS} hours ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
                   date -u -v-${HOURS}H +"%Y-%m-%dT%H:%M:%SZ")

    if [ -f "$GPU_EVENT_LOG" ]; then
        # Filter events newer than cutoff
        while IFS= read -r line; do
            local TS=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('timestamp',''))" 2>/dev/null)
            if [[ "$TS" > "$CUTOFF" ]]; then
                echo "$line"
            fi
        done < "$GPU_EVENT_LOG"
    fi
}

# Calculate cost summary for last N hours
get_cost_summary() {
    local HOURS="${1:-24}"

    if [ ! -f "$GPU_EVENT_LOG" ]; then
        echo '{"total_cost":0,"total_runtime_min":0,"pods_started":0,"pods_terminated":0}'
        return
    fi

    get_recent_events "$HOURS" | python3 -c "
import sys
import json

total_cost = 0
total_runtime = 0
started = 0
terminated = 0

for line in sys.stdin:
    try:
        event = json.loads(line.strip())
        if event.get('action') == 'created':
            started += 1
        elif event.get('action') == 'terminated':
            terminated += 1
            details = event.get('details', {})
            if isinstance(details, dict):
                total_cost += details.get('estimated_cost', 0)
                total_runtime += details.get('runtime_min', 0)
    except:
        pass

print(json.dumps({
    'total_cost': round(total_cost, 2),
    'total_runtime_min': total_runtime,
    'pods_started': started,
    'pods_terminated': terminated
}))
"
}
