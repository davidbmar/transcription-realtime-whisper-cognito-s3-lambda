#!/bin/bash
# RIVA-099: Common GPU Management Functions
# Shared library for GPU instance management scripts
# Version: 2.0.0

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ENV_FILE:-$PROJECT_ROOT/.env}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$PROJECT_ROOT/artifacts}"
LOGS_DIR="${LOGS_DIR:-$PROJECT_ROOT/logs}"
LOCK_DIR="${LOCK_DIR:-$PROJECT_ROOT/.lock}"

# Ensure directories exist
mkdir -p "$ARTIFACTS_DIR" "$LOGS_DIR" "$LOCK_DIR"

# State files
INSTANCE_FILE="$ARTIFACTS_DIR/instance.json"
STATE_FILE="$ARTIFACTS_DIR/state.json"
COST_FILE="$ARTIFACTS_DIR/cost.json"

# Current log file (set by calling script)
LOG_FILE="${LOG_FILE:-}"
LOG_UUID="${LOG_UUID:-$(uuidgen 2>/dev/null || echo "$(date +%s)-$$")}"

# Colors for console output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Signal handling for graceful shutdown
CLEANUP_ON_EXIT=false
LOCK_ACQUIRED=false

# Cleanup function called on script exit
cleanup_on_exit() {
    if [ "$CLEANUP_ON_EXIT" = "true" ]; then
        # Only log interruption if we're actually being terminated by a signal
        # Exit codes 130 (SIGINT), 143 (SIGTERM), etc indicate signal termination
        local exit_code=$?
        if [ $exit_code -ge 128 ]; then
            json_log "${SCRIPT_NAME:-common}" "cleanup" "warn" "Script interrupted, cleaning up"
        fi

        # Release lock if we acquired it
        if [ "$LOCK_ACQUIRED" = "true" ]; then
            local lock_file="$LOCK_DIR/riva-gpu.lock"
            rm -rf "$lock_file" 2>/dev/null || true
            if [ $exit_code -ge 128 ]; then
                json_log "${SCRIPT_NAME:-common}" "cleanup" "ok" "Lock released during cleanup"
            fi
        fi

        # Only log signal termination if actually terminated by signal
        if [ $exit_code -ge 128 ]; then
            json_log "${SCRIPT_NAME:-common}" "exit" "warn" "Script terminated by signal"
        fi
    fi
}

# Set up signal handlers
setup_signal_handlers() {
    CLEANUP_ON_EXIT=true
    trap cleanup_on_exit EXIT
    trap 'json_log "${SCRIPT_NAME:-common}" "signal" "warn" "Received SIGINT"; exit 130' INT
    trap 'json_log "${SCRIPT_NAME:-common}" "signal" "warn" "Received SIGTERM"; exit 143' TERM
}

# ============================================================================
# JSON Logging
# ============================================================================

# Initialize log file for this run
init_log() {
    local script_name="${1:-unknown}"
    local timestamp=$(date -u +"%Y-%m-%dT%H-%M-%SZ")
    LOG_FILE="$LOGS_DIR/riva-run-${timestamp}-${LOG_UUID}.log"

    # Print log path for watchers
    echo "LOG_PATH=$LOG_FILE"

    # Initial log entry
    json_log "$script_name" "init" "ok" "Logging initialized" \
        "log_file=$LOG_FILE" \
        "version=2.0.0"

    export LOG_FILE
}

# Write JSON log entry
# Usage: json_log script step status details [key=value ...]
json_log() {
    local script="${1:-unknown}"
    local step="${2:-unknown}"
    local status="${3:-ok}"  # ok|warn|error
    local details="${4:-}"
    shift 4 || true

    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
    local exit_code=0
    local duration_ms=0

    # Build JSON object
    local json='{'
    json+='"ts":"'$timestamp'"'
    json+=',"script":"'$script'"'
    json+=',"version":"2.0.0"'
    json+=',"step":"'$step'"'
    json+=',"status":"'$status'"'
    json+=',"details":"'$(echo "$details" | sed 's/"/\\"/g')'"'

    # Parse additional key=value pairs
    while [ $# -gt 0 ]; do
        local key="${1%%=*}"
        local value="${1#*=}"
        if [ "$key" != "$1" ]; then
            # Handle numeric vs string values
            if [[ "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                json+=',"'$key'":'$value
            else
                json+=',"'$key'":"'$(echo "$value" | sed 's/"/\\"/g')'"'
            fi
        fi
        shift
    done

    json+='}'

    # Write to log file if set
    if [ -n "$LOG_FILE" ]; then
        echo "$json" >> "$LOG_FILE"
    fi

    # Also print to console with color coding
    local color="$NC"
    case "$status" in
        ok) color="$GREEN" ;;
        warn) color="$YELLOW" ;;
        error) color="$RED" ;;
    esac

    echo -e "${color}[$step] $details${NC}" >&2
}

# ============================================================================
# Environment Management
# ============================================================================

# Load environment file or fail
load_env_or_fail() {
    if [ ! -f "$ENV_FILE" ]; then
        json_log "${SCRIPT_NAME:-common}" "load_env" "error" "Configuration file not found: $ENV_FILE"
        echo -e "${RED}❌ Configuration file not found: $ENV_FILE${NC}"
        echo "Run: ./scripts/riva-005-setup-project-configuration.sh"
        return 1
    fi

    source "$ENV_FILE"
    json_log "${SCRIPT_NAME:-common}" "load_env" "ok" "Environment loaded from $ENV_FILE"
}

# Atomically update environment file
# Usage: update_env_file KEY VALUE
update_env_file() {
    local key="$1"
    local value="$2"
    local temp_file="${ENV_FILE}.tmp.$$"

    json_log "${SCRIPT_NAME:-common}" "update_env" "ok" "Updating $key in .env" \
        "key=$key" "value=$value"

    # Create temp file with updated value
    if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
        # Update existing key
        sed "s|^${key}=.*|${key}=${value}|" "$ENV_FILE" > "$temp_file"
    else
        # Add new key
        cp "$ENV_FILE" "$temp_file"
        echo "${key}=${value}" >> "$temp_file"
    fi

    # Update ENV_VERSION
    if grep -q "^ENV_VERSION=" "$temp_file"; then
        local current_version=$(grep "^ENV_VERSION=" "$temp_file" | cut -d= -f2)
        local new_version=$((current_version + 1))
        sed -i "s|^ENV_VERSION=.*|ENV_VERSION=${new_version}|" "$temp_file"
    else
        echo "ENV_VERSION=1" >> "$temp_file"
    fi

    # Atomic move
    mv -f "$temp_file" "$ENV_FILE"
}

# ============================================================================
# State Management
# ============================================================================

# Get current instance ID from multiple sources
get_instance_id() {
    local instance_id=""

    # Priority 1: Instance file
    if [ -f "$INSTANCE_FILE" ]; then
        instance_id=$(jq -r '.instance_id // empty' "$INSTANCE_FILE" 2>/dev/null || true)
    fi

    # Priority 2: Environment file
    if [ -z "$instance_id" ] && [ -n "${GPU_INSTANCE_ID:-}" ]; then
        instance_id="$GPU_INSTANCE_ID"
    fi

    # Priority 3: State file
    if [ -z "$instance_id" ] && [ -f "$STATE_FILE" ]; then
        instance_id=$(jq -r '.instance_id // empty' "$STATE_FILE" 2>/dev/null || true)
    fi

    echo "$instance_id"
}

# Get instance state from AWS
get_instance_state() {
    local instance_id="${1:-$(get_instance_id)}"

    if [ -z "$instance_id" ]; then
        echo "none"
        return
    fi

    local state=$(aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text \
        --region "${AWS_REGION:-us-east-2}" 2>/dev/null || echo "none")

    if [ "$state" = "None" ] || [ "$state" = "null" ]; then
        state="none"
    fi

    echo "$state"
}

# Load state from cache
load_state_cache() {
    if [ -f "$STATE_FILE" ]; then
        cat "$STATE_FILE"
    else
        echo '{}'
    fi
}

# Write state to cache
write_state_cache() {
    local instance_id="${1}"
    local state="${2}"
    local public_ip="${3:-}"
    local private_ip="${4:-}"

    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Build state JSON
    cat > "$STATE_FILE" <<EOF
{
  "instance_id": "$instance_id",
  "state": "$state",
  "public_ip": "$public_ip",
  "private_ip": "$private_ip",
  "last_state_change": "$timestamp",
  "region": "${AWS_REGION:-us-east-2}",
  "instance_type": "${GPU_INSTANCE_TYPE:-unknown}"
}
EOF

    json_log "${SCRIPT_NAME:-common}" "write_state" "ok" "State cache updated" \
        "instance_id=$instance_id" "state=$state"
}

# Write instance facts (static data)
write_instance_facts() {
    local instance_id="${1}"
    local instance_type="${2}"
    local ami_id="${3:-}"
    local security_group_id="${4:-}"
    local key_name="${5:-}"

    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    cat > "$INSTANCE_FILE" <<EOF
{
  "instance_id": "$instance_id",
  "instance_type": "$instance_type",
  "ami_id": "$ami_id",
  "security_group_id": "$security_group_id",
  "key_name": "$key_name",
  "region": "${AWS_REGION:-us-east-2}",
  "created_at": "$timestamp"
}
EOF

    json_log "${SCRIPT_NAME:-common}" "write_facts" "ok" "Instance facts saved" \
        "instance_id=$instance_id"
}

# ============================================================================
# Concurrency Control
# ============================================================================

# Acquire lock with timeout
# Usage: with_lock COMMAND [ARGS...]
with_lock() {
    local lock_file="$LOCK_DIR/riva-gpu.lock"
    local timeout="${LOCK_TIMEOUT:-30}"
    local pid=$$
    local hostname=$(hostname)
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Set up signal handlers
    setup_signal_handlers

    # Try to acquire lock
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if mkdir "$lock_file" 2>/dev/null; then
            # Mark that we acquired the lock
            LOCK_ACQUIRED=true

            # Write lock info
            cat > "$lock_file/info.json" <<EOF
{
  "pid": $pid,
  "script": "${SCRIPT_NAME:-unknown}",
  "start_time": "$timestamp",
  "hostname": "$hostname"
}
EOF
            json_log "${SCRIPT_NAME:-common}" "lock" "ok" "Lock acquired" "pid=$pid"

            # Execute command
            local exit_code=0
            "$@" || exit_code=$?

            # Release lock
            rm -rf "$lock_file"
            LOCK_ACQUIRED=false
            json_log "${SCRIPT_NAME:-common}" "lock" "ok" "Lock released" "pid=$pid"

            return $exit_code
        fi

        # Check if lock holder is still alive
        if [ -f "$lock_file/info.json" ]; then
            local lock_pid=$(jq -r '.pid // 0' "$lock_file/info.json" 2>/dev/null || echo 0)
            if [ $lock_pid -gt 0 ] && ! kill -0 $lock_pid 2>/dev/null; then
                # Lock holder is dead, clean up
                json_log "${SCRIPT_NAME:-common}" "lock" "warn" "Removing stale lock" "old_pid=$lock_pid"
                rm -rf "$lock_file"
                continue
            fi
        fi

        sleep 1
        elapsed=$((elapsed + 1))
    done

    json_log "${SCRIPT_NAME:-common}" "lock" "error" "Failed to acquire lock after ${timeout}s"
    return 5
}

# ============================================================================
# AWS Operations
# ============================================================================

# Get instance details
get_instance_details() {
    local instance_id="${1:-$(get_instance_id)}"

    if [ -z "$instance_id" ]; then
        echo '{}'
        return
    fi

    aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0]' \
        --output json \
        --region "${AWS_REGION:-us-east-2}" 2>/dev/null || echo '{}'
}

# Get instance IP address
get_instance_ip() {
    local instance_id="${1:-$(get_instance_id)}"

    if [ -z "$instance_id" ]; then
        return
    fi

    aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text \
        --region "${AWS_REGION:-us-east-2}" 2>/dev/null || true
}

# Ensure security group exists (idempotent)
ensure_security_group() {
    local sg_name="${1:-riva-asr-sg-${DEPLOYMENT_ID:-default}}"
    local sg_desc="${2:-Security group for NVIDIA Parakeet Riva ASR server}"

    json_log "${SCRIPT_NAME:-common}" "ensure_sg" "ok" "Checking security group" "name=$sg_name"

    # Check if exists
    local sg_id=$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=$sg_name" \
        --query 'SecurityGroups[0].GroupId' \
        --output text \
        --region "${AWS_REGION:-us-east-2}" 2>/dev/null || echo "None")

    if [ "$sg_id" != "None" ] && [ "$sg_id" != "null" ] && [ -n "$sg_id" ]; then
        json_log "${SCRIPT_NAME:-common}" "ensure_sg" "ok" "Using existing security group" "sg_id=$sg_id"
        echo "$sg_id"
        return 0
    fi

    # Create new
    sg_id=$(aws ec2 create-security-group \
        --group-name "$sg_name" \
        --description "$sg_desc" \
        --query 'GroupId' \
        --output text \
        --region "${AWS_REGION:-us-east-2}")

    json_log "${SCRIPT_NAME:-common}" "ensure_sg" "ok" "Created security group" "sg_id=$sg_id"

    # Add default rules
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 22 \
        --cidr 0.0.0.0/0 \
        --region "${AWS_REGION:-us-east-2}" &>/dev/null || true

    echo "$sg_id"
}

# ============================================================================
# Health Checks
# ============================================================================

# Wait for cloud-init to complete
wait_for_cloud_init() {
    local instance_ip="${1}"
    local ssh_key="${2:-$HOME/.ssh/${SSH_KEY_NAME}.pem}"
    local max_wait="${3:-300}"

    json_log "${SCRIPT_NAME:-common}" "cloud_init" "ok" "Waiting for cloud-init" "ip=$instance_ip"

    local elapsed=0
    while [ $elapsed -lt $max_wait ]; do
        local status=$(ssh -i "$ssh_key" -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
            ubuntu@"$instance_ip" \
            'cloud-init status 2>/dev/null | grep -o "status: .*" | cut -d" " -f2' 2>/dev/null || echo "unknown")

        if [ "$status" = "done" ]; then
            json_log "${SCRIPT_NAME:-common}" "cloud_init" "ok" "Cloud-init completed" "duration_ms=$((elapsed * 1000))"
            return 0
        elif [ "$status" = "error" ]; then
            json_log "${SCRIPT_NAME:-common}" "cloud_init" "error" "Cloud-init failed"
            return 1
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    json_log "${SCRIPT_NAME:-common}" "cloud_init" "warn" "Cloud-init timeout after ${max_wait}s"
    return 1
}

# Wait for SSH with exponential backoff
wait_for_ssh_with_backoff() {
    local instance_ip="${1}"
    local ssh_key="${2:-$HOME/.ssh/${SSH_KEY_NAME}.pem}"
    local max_retries="${3:-10}"
    local initial_wait="${4:-2}"

    local wait_time=$initial_wait
    local max_wait=30
    local total_wait=0
    local attempt=1
    local start_time=$(date +%s)

    json_log "${SCRIPT_NAME:-common}" "ssh_wait" "info" "Waiting for SSH to become available" \
        "ip=$instance_ip" "max_retries=$max_retries"

    echo "    ⏳ Waiting for SSH to become available (this is normal after instance start)..."

    while [ $attempt -le $max_retries ]; do
        # Try SSH connection
        if ssh -i "$ssh_key" -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
            ubuntu@"$instance_ip" 'echo "SSH OK"' &>/dev/null; then

            local end_time=$(date +%s)
            local elapsed=$((end_time - start_time))

            json_log "${SCRIPT_NAME:-common}" "ssh_wait" "ok" "SSH available after ${elapsed}s" \
                "attempts=$attempt" "total_wait=$total_wait"
            echo "    ✅ SSH became available after ${elapsed}s (attempt $attempt)"
            return 0
        fi

        # If this isn't the last attempt, wait before retry
        if [ $attempt -lt $max_retries ]; then
            echo "    Attempt $attempt/$max_retries: SSH not ready, waiting ${wait_time}s before retry..."
            sleep $wait_time
            total_wait=$((total_wait + wait_time))

            # Exponential backoff with cap
            wait_time=$((wait_time * 2))
            if [ $wait_time -gt $max_wait ]; then
                wait_time=$max_wait
            fi
        else
            echo "    Attempt $attempt/$max_retries: SSH not ready"
        fi

        attempt=$((attempt + 1))
    done

    json_log "${SCRIPT_NAME:-common}" "ssh_wait" "error" "SSH timeout after $max_retries attempts" \
        "total_wait=$total_wait"
    echo "    ❌ SSH did not become available after $max_retries attempts (${total_wait}s total wait)"
    return 1
}

# Validate SSH connectivity
validate_ssh_connectivity() {
    local instance_ip="${1}"
    local ssh_key="${2:-$HOME/.ssh/${SSH_KEY_NAME}.pem}"

    json_log "${SCRIPT_NAME:-common}" "ssh_check" "ok" "Testing SSH connectivity" "ip=$instance_ip"

    if ssh -i "$ssh_key" -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        ubuntu@"$instance_ip" 'echo "SSH OK"' &>/dev/null; then
        json_log "${SCRIPT_NAME:-common}" "ssh_check" "ok" "SSH connectivity confirmed"
        return 0
    else
        json_log "${SCRIPT_NAME:-common}" "ssh_check" "error" "SSH connectivity failed"
        return 1
    fi
}

# Check Docker status
check_docker_status() {
    local instance_ip="${1}"
    local ssh_key="${2:-$HOME/.ssh/${SSH_KEY_NAME}.pem}"

    json_log "${SCRIPT_NAME:-common}" "docker_check" "ok" "Checking Docker status" "ip=$instance_ip"

    local docker_status=$(ssh -i "$ssh_key" -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        ubuntu@"$instance_ip" \
        'systemctl is-active docker 2>/dev/null' || echo "inactive")

    if [ "$docker_status" = "active" ]; then
        json_log "${SCRIPT_NAME:-common}" "docker_check" "ok" "Docker is running"

        # Check for NVIDIA runtime
        local nvidia_runtime=$(ssh -i "$ssh_key" -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
            ubuntu@"$instance_ip" \
            'docker info 2>/dev/null | grep -c nvidia' || echo "0")

        if [ "$nvidia_runtime" -gt 0 ]; then
            json_log "${SCRIPT_NAME:-common}" "docker_check" "ok" "NVIDIA runtime configured"
            return 0
        else
            json_log "${SCRIPT_NAME:-common}" "docker_check" "warn" "NVIDIA runtime not configured"
            return 1
        fi
    else
        json_log "${SCRIPT_NAME:-common}" "docker_check" "error" "Docker is not running"
        return 1
    fi
}

# Check GPU availability
check_gpu_availability() {
    local instance_ip="${1}"
    local ssh_key="${2:-$HOME/.ssh/${SSH_KEY_NAME}.pem}"

    json_log "${SCRIPT_NAME:-common}" "gpu_check" "ok" "Checking GPU availability" "ip=$instance_ip"

    local gpu_info=$(ssh -i "$ssh_key" -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        ubuntu@"$instance_ip" \
        'nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null' || echo "")

    if [ -n "$gpu_info" ]; then
        json_log "${SCRIPT_NAME:-common}" "gpu_check" "ok" "GPU detected" "gpu=$gpu_info"
        return 0
    else
        json_log "${SCRIPT_NAME:-common}" "gpu_check" "error" "No GPU detected"
        return 1
    fi
}

# Check RIVA containers
check_riva_containers() {
    local instance_ip="${1}"
    local ssh_key="${2:-$HOME/.ssh/${SSH_KEY_NAME}.pem}"

    json_log "${SCRIPT_NAME:-common}" "riva_check" "ok" "Checking RIVA containers" "ip=$instance_ip"

    local riva_count=$(ssh -i "$ssh_key" -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        ubuntu@"$instance_ip" \
        'docker ps --filter "label=nvidia.riva" --format "{{.Names}}" 2>/dev/null | wc -l' || echo "0")

    if [ "$riva_count" -gt 0 ]; then
        json_log "${SCRIPT_NAME:-common}" "riva_check" "ok" "RIVA containers running" "count=$riva_count"
        return 0
    else
        json_log "${SCRIPT_NAME:-common}" "riva_check" "warn" "No RIVA containers running"
        return 1
    fi
}

# ============================================================================
# Cost Tracking
# ============================================================================

# Get instance hourly rate (simplified pricing table)
get_instance_hourly_rate() {
    local instance_type="${1:-${GPU_INSTANCE_TYPE:-g4dn.xlarge}}"
    local region="${2:-${AWS_REGION:-us-east-2}}"

    # Simplified pricing table (USD per hour)
    case "$instance_type" in
        "g4dn.xlarge") echo "0.526" ;;
        "g4dn.2xlarge") echo "0.752" ;;
        "g4dn.4xlarge") echo "1.204" ;;
        "g5.xlarge") echo "1.006" ;;
        "g5.2xlarge") echo "1.212" ;;
        "p3.2xlarge") echo "3.060" ;;
        *) echo "1.000" ;;  # Default fallback
    esac
}

# Calculate running costs
calculate_running_costs() {
    local start_time="${1}"
    local instance_type="${2:-${GPU_INSTANCE_TYPE:-g4dn.xlarge}}"

    if [ -z "$start_time" ]; then
        echo '{"hourly_usd": 0, "session_usd": 0, "duration_hours": 0}'
        return
    fi

    local hourly_rate=$(get_instance_hourly_rate "$instance_type")
    local now=$(date +%s)
    local start=$(date -d "$start_time" +%s 2>/dev/null || echo "$now")
    local duration_seconds=$((now - start))
    local duration_hours=$(echo "scale=4; $duration_seconds / 3600" | bc)
    local session_cost=$(echo "scale=2; $duration_hours * $hourly_rate" | bc)

    cat <<EOF
{
  "hourly_usd": $hourly_rate,
  "session_usd": $session_cost,
  "duration_hours": $duration_hours,
  "duration_seconds": $duration_seconds
}
EOF
}

# Update cost metrics
update_cost_metrics() {
    local action="${1}"  # start|stop
    local instance_type="${2:-${GPU_INSTANCE_TYPE:-g4dn.xlarge}}"

    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local hourly_rate=$(get_instance_hourly_rate "$instance_type")

    if [ "$action" = "start" ]; then
        cat > "$COST_FILE" <<EOF
{
  "session_start": "$timestamp",
  "session_end": null,
  "hourly_rate_usd": $hourly_rate,
  "instance_type": "$instance_type",
  "total_sessions": []
}
EOF
    elif [ "$action" = "stop" ] && [ -f "$COST_FILE" ]; then
        local session_start=$(jq -r '.session_start // empty' "$COST_FILE" 2>/dev/null || echo "$timestamp")
        local costs=$(calculate_running_costs "$session_start" "$instance_type")
        local session_cost=$(echo "$costs" | jq -r '.session_usd')

        # Append to sessions history
        local temp_file="${COST_FILE}.tmp"
        jq --arg end "$timestamp" \
           --arg cost "$session_cost" \
           '.session_end = $end | .total_sessions += [{"start": .session_start, "end": $end, "cost_usd": ($cost | tonumber)}]' \
           "$COST_FILE" > "$temp_file"
        mv "$temp_file" "$COST_FILE"
    fi

    json_log "${SCRIPT_NAME:-common}" "cost_update" "ok" "Cost metrics updated" "action=$action"
}

# ============================================================================
# Utility Functions
# ============================================================================

# Check if running on EC2
is_ec2_instance() {
    if [ -f /sys/hypervisor/uuid ] && grep -q "^ec2" /sys/hypervisor/uuid 2>/dev/null; then
        return 0
    fi
    return 1
}

# Get current EC2 instance metadata
get_ec2_metadata() {
    local metadata_item="${1:-instance-id}"

    if is_ec2_instance; then
        curl -s "http://169.254.169.254/latest/meta-data/${metadata_item}" 2>/dev/null || echo ""
    fi
}

# Format duration for display
format_duration() {
    local seconds="${1}"

    local hours=$((seconds / 3600))
    local minutes=$(((seconds % 3600) / 60))
    local secs=$((seconds % 60))

    if [ $hours -gt 0 ]; then
        printf "%dh %dm %ds" $hours $minutes $secs
    elif [ $minutes -gt 0 ]; then
        printf "%dm %ds" $minutes $secs
    else
        printf "%ds" $secs
    fi
}

# Print status line
print_status() {
    local status="${1}"
    local message="${2}"

    case "$status" in
        ok|success)
            echo -e "${GREEN}✅ $message${NC}"
            ;;
        warn|warning)
            echo -e "${YELLOW}⚠️  $message${NC}"
            ;;
        error|fail)
            echo -e "${RED}❌ $message${NC}"
            ;;
        info)
            echo -e "${BLUE}ℹ️  $message${NC}"
            ;;
        *)
            echo "$message"
            ;;
    esac
}

# ============================================================================
# Export Functions
# ============================================================================

# Export all functions for use by other scripts
export -f init_log json_log
export -f load_env_or_fail update_env_file
export -f get_instance_id get_instance_state
export -f load_state_cache write_state_cache write_instance_facts
export -f with_lock
export -f get_instance_details get_instance_ip ensure_security_group
export -f wait_for_cloud_init validate_ssh_connectivity
export -f check_docker_status check_gpu_availability check_riva_containers
export -f get_instance_hourly_rate calculate_running_costs update_cost_metrics
export -f is_ec2_instance get_ec2_metadata
export -f format_duration print_status

# ============================================================================
# Self Test (if run directly)
# ============================================================================

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    echo "RIVA Common Functions Library v2.0.0"
    echo "===================================="
    echo ""
    echo "Available functions:"
    echo "  - Logging: init_log, json_log"
    echo "  - Environment: load_env_or_fail, update_env_file"
    echo "  - State: get_instance_id, get_instance_state, *_state_cache"
    echo "  - Concurrency: with_lock"
    echo "  - AWS: get_instance_*, ensure_security_group"
    echo "  - Health: wait_for_cloud_init, check_*"
    echo "  - Cost: calculate_running_costs, update_cost_metrics"
    echo "  - Utility: format_duration, print_status"
    echo ""
    echo "To use in your script:"
    echo '  source "$(dirname "$0")/riva-099-common.sh"'
fi