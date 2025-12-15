#!/bin/bash
#===============================================================================
# 999-WATCHDOG--gpu-cost-guardian.sh
# Smart GPU cost guardian - monitors and terminates idle GPU resources
#===============================================================================
#
# WHAT THIS SCRIPT DOES:
# ----------------------
# Monitors both RunPod and AWS for GPU resources that may have been left running.
# Uses smart detection to avoid killing actively-used resources:
#   - Checks GPU utilization (if transcribing, GPU will be busy)
#   - Checks runtime duration
#   - Applies safety caps to prevent runaway costs
#
# DECISION LOGIC (in priority order):
# -----------------------------------
#   Rule 1: runtime < 20 min        → PROTECTED (boot window, never kill)
#   Rule 2: runtime > 2 hours       → KILL (safety cap, prevents runaway costs)
#   Rule 3: boot stage 0 or 1       → WARN (still allocating GPU or pulling image)
#   Rule 4: container running but   → KILL if > 30 min (crashed container)
#           health not responding
#   Rule 5: GPU utilization > 5%    → ACTIVE (don't kill, it's working)
#   Rule 6: idle > 30 min           → KILL (forgotten/unused)
#   Rule 7: otherwise               → OK (still in grace period)
#
# BOOT STAGES (from RunPod API):
# ------------------------------
#   Stage 0: Waiting for GPU allocation (machine={})
#   Stage 1: GPU allocated, pulling image (machine has data, no runtime)
#   Stage 2: Container running (runtime field exists)
#
# USAGE:
#   ./scripts/999-WATCHDOG--gpu-cost-guardian.sh           # Check and report
#   ./scripts/999-WATCHDOG--gpu-cost-guardian.sh --kill    # Check and terminate idle
#   ./scripts/999-WATCHDOG--gpu-cost-guardian.sh --cron    # Silent mode for cron
#
# CRON SETUP (every 15 minutes):
#   crontab -e
#   */15 * * * * /home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/scripts/999-WATCHDOG--gpu-cost-guardian.sh --kill --cron >> /var/log/gpu-watchdog.log 2>&1
#
# ENVIRONMENT:
#   Requires RUNPOD_API_KEY in .env or environment
#   Requires AWS CLI configured for EC2 access
#
#===============================================================================

set -uo pipefail

# Configuration
MIN_SAFE_RUNTIME_MIN=20    # NEVER kill anything running less than this (boot + buffer)
IDLE_THRESHOLD_MIN=30      # Kill if idle longer than this (after MIN_SAFE_RUNTIME_MIN)
MAX_RUNTIME_HOURS=2        # Safety cap - kill anything running longer (even if "active")
GPU_ACTIVE_THRESHOLD=5     # GPU utilization % considered "active"

# Parse arguments
KILL_MODE=false
CRON_MODE=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --kill) KILL_MODE=true; shift ;;
        --cron) CRON_MODE=true; shift ;;
        --help|-h)
            head -45 "$0" | tail -40
            exit 0
            ;;
        *) shift ;;
    esac
done

# Colors (disabled in cron mode)
if [ "$CRON_MODE" = true ]; then
    RED="" GREEN="" YELLOW="" BLUE="" NC=""
else
    RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' BLUE='\033[0;34m' NC='\033[0m'
fi

log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log_info() { log "${BLUE}[INFO]${NC} $1"; }
log_ok() { log "${GREEN}[OK]${NC} $1"; }
log_warn() { log "${YELLOW}[WARN]${NC} $1"; }
log_error() { log "${RED}[ERROR]${NC} $1"; }

# Load environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
fi

# Load event logger for structured JSON logging
if [ -f "$SCRIPT_DIR/lib/gpu-event-logger.sh" ]; then
    source "$SCRIPT_DIR/lib/gpu-event-logger.sh"
fi

RUNPOD_API_KEY="${RUNPOD_API_KEY:-}"
TOTAL_KILLED=0
TOTAL_RUNNING=0
TOTAL_COST_PER_HOUR=0

#===============================================================================
# RunPod Monitoring
#===============================================================================

check_runpod() {
    log_info "Checking RunPod..."

    if [ -z "$RUNPOD_API_KEY" ]; then
        log_warn "RUNPOD_API_KEY not set, skipping RunPod check"
        return
    fi

    # Get all pods
    PODS_JSON=$(curl -s -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
        "https://rest.runpod.io/v1/pods" 2>/dev/null)

    if [ -z "$PODS_JSON" ] || [ "$PODS_JSON" = "[]" ]; then
        log_ok "No RunPod pods running"
        return
    fi

    # Process each pod
    echo "$PODS_JSON" | python3 -c "
import sys, json
from datetime import datetime, timezone

data = json.load(sys.stdin)
for pod in data:
    pod_id = pod.get('id', 'unknown')
    status = pod.get('desiredStatus', 'unknown')
    cost = pod.get('costPerHr', 0)
    name = pod.get('name', 'unnamed')
    created = pod.get('createdAt', '')

    # Boot stage detection
    machine = pod.get('machine', {})
    runtime = pod.get('runtime')

    # Determine boot stage:
    # 0 = waiting for GPU (machine empty)
    # 1 = GPU allocated, pulling image (machine has data, no runtime)
    # 2 = container running (runtime exists)
    if not machine:
        boot_stage = 0
    elif runtime is None:
        boot_stage = 1
    else:
        boot_stage = 2

    gpu_name = machine.get('gpuDisplayName', 'pending')

    # Calculate runtime
    runtime_min = 0
    if created:
        try:
            # Parse RunPod timestamp format
            created_dt = datetime.strptime(created.split('.')[0], '%Y-%m-%d %H:%M:%S')
            created_dt = created_dt.replace(tzinfo=timezone.utc)
            runtime_min = (datetime.now(timezone.utc) - created_dt).total_seconds() / 60
        except:
            pass

    print(f'{pod_id}|{status}|{cost}|{name}|{runtime_min:.0f}|{boot_stage}|{gpu_name}')
" | while IFS='|' read -r POD_ID STATUS COST NAME RUNTIME_MIN BOOT_STAGE GPU_NAME; do

        if [ "$STATUS" != "RUNNING" ]; then
            continue
        fi

        TOTAL_RUNNING=$((TOTAL_RUNNING + 1))
        TOTAL_COST_PER_HOUR=$(echo "$TOTAL_COST_PER_HOUR + $COST" | bc 2>/dev/null || echo "$TOTAL_COST_PER_HOUR")

        log_info "  Pod: $POD_ID ($NAME)"
        log_info "    Runtime: ${RUNTIME_MIN} min | Cost: \$${COST}/hr | GPU: ${GPU_NAME}"

        # Show boot stage from API
        case "$BOOT_STAGE" in
            0) log_info "    Boot Stage: WAITING FOR GPU (machine not allocated)" ;;
            1) log_info "    Boot Stage: PULLING IMAGE (GPU allocated, container starting)" ;;
            2) log_info "    Boot Stage: CONTAINER RUNNING" ;;
        esac

        # Check GPU utilization via health endpoint (only meaningful if container running)
        GPU_UTIL=0
        HEALTH_RESPONDING=false
        if [ "$BOOT_STAGE" = "2" ]; then
            STATUS_RESP=$(curl -s --max-time 5 "https://${POD_ID}-9999.proxy.runpod.net/status" 2>/dev/null)
            if [ -n "$STATUS_RESP" ] && echo "$STATUS_RESP" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
                HEALTH_RESPONDING=true
                GPU_UTIL=$(echo "$STATUS_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('gpu',{}).get('utilization_percent',0))" 2>/dev/null || echo "0")
                log_info "    GPU Utilization: ${GPU_UTIL}%"
            else
                log_info "    Health endpoint: NOT RESPONDING (container may have crashed)"
            fi
        fi

        # Decision logic
        SHOULD_KILL=false
        REASON=""

        # Decision logic - uses boot stage from RunPod API for accuracy

        # Rule 1: NEVER kill if under minimum safe runtime (boot protection)
        if [ "${RUNTIME_MIN:-0}" -lt "$MIN_SAFE_RUNTIME_MIN" ]; then
            case "$BOOT_STAGE" in
                0) log_ok "    Status: PROTECTED (waiting for GPU, runtime < ${MIN_SAFE_RUNTIME_MIN} min)" ;;
                1) log_ok "    Status: PROTECTED (pulling image, runtime < ${MIN_SAFE_RUNTIME_MIN} min)" ;;
                2) log_ok "    Status: PROTECTED (just started, runtime < ${MIN_SAFE_RUNTIME_MIN} min)" ;;
            esac

        # Rule 2: Safety cap - kill if running too long (prevents runaway costs)
        elif [ "${RUNTIME_MIN:-0}" -gt $((MAX_RUNTIME_HOURS * 60)) ]; then
            SHOULD_KILL=true
            REASON="exceeded max runtime (${MAX_RUNTIME_HOURS}h safety cap)"

        # Rule 3: Still in early boot stages (API says not running yet)
        elif [ "$BOOT_STAGE" = "0" ] || [ "$BOOT_STAGE" = "1" ]; then
            log_warn "    Status: SLOW BOOT (still in stage ${BOOT_STAGE} after ${RUNTIME_MIN} min)"
            log_warn "    May be stuck. Check RunPod console: https://www.runpod.io/console/pods"
            # Don't auto-kill - could be slow GPU allocation or large image

        # Rule 4: Container running but health not responding - likely crashed
        elif [ "$BOOT_STAGE" = "2" ] && [ "$HEALTH_RESPONDING" = false ]; then
            if [ "${RUNTIME_MIN:-0}" -gt "$IDLE_THRESHOLD_MIN" ]; then
                SHOULD_KILL=true
                REASON="container crashed (health not responding for ${RUNTIME_MIN} min)"
            else
                log_warn "    Status: UNHEALTHY (container running but health not responding)"
                log_warn "    Will auto-kill after ${IDLE_THRESHOLD_MIN} min if still unresponsive"
            fi

        # Rule 5: GPU is active - don't kill
        elif [ "${GPU_UTIL:-0}" -gt "$GPU_ACTIVE_THRESHOLD" ]; then
            log_ok "    Status: ACTIVE (GPU ${GPU_UTIL}% in use)"

        # Rule 6: Idle too long - kill
        elif [ "${RUNTIME_MIN:-0}" -gt "$IDLE_THRESHOLD_MIN" ]; then
            SHOULD_KILL=true
            REASON="idle for ${RUNTIME_MIN} min (GPU ${GPU_UTIL}%, threshold: ${IDLE_THRESHOLD_MIN} min)"

        # Rule 7: Running but not idle long enough yet
        else
            log_ok "    Status: OK (idle ${RUNTIME_MIN} min, kill threshold: ${IDLE_THRESHOLD_MIN} min)"
        fi

        # Log the check event
        if type log_runpod_check &>/dev/null; then
            CHECK_STATUS="ok"
            [ "${GPU_UTIL:-0}" -gt "$GPU_ACTIVE_THRESHOLD" ] && CHECK_STATUS="active"
            [ "${RUNTIME_MIN:-0}" -lt "$MIN_SAFE_RUNTIME_MIN" ] && CHECK_STATUS="starting"
            [ "$SHOULD_KILL" = true ] && CHECK_STATUS="idle"
            log_runpod_check "$POD_ID" "$CHECK_STATUS" "${GPU_UTIL:-0}" "${RUNTIME_MIN:-0}"
        fi

        if [ "$SHOULD_KILL" = true ]; then
            log_warn "    Status: IDLE - $REASON"

            if [ "$KILL_MODE" = true ]; then
                log_warn "    Terminating pod..."
                KILL_RESP=$(curl -s -X DELETE -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
                    "https://rest.runpod.io/v1/pods/${POD_ID}" 2>/dev/null)
                log_ok "    Terminated: $POD_ID"
                TOTAL_KILLED=$((TOTAL_KILLED + 1))

                # Log termination event
                ESTIMATED_COST=$(echo "${RUNTIME_MIN:-0} * ${COST:-0} / 60" | bc -l 2>/dev/null | xargs printf "%.2f" 2>/dev/null || echo "0")
                if type log_runpod_terminate &>/dev/null; then
                    log_runpod_terminate "$POD_ID" "$REASON" "${RUNTIME_MIN:-0}" "$ESTIMATED_COST"
                fi
            else
                log_warn "    Would terminate (run with --kill to execute)"
            fi
        fi

        echo ""
    done
}

#===============================================================================
# AWS GPU Instance Monitoring
#===============================================================================

check_aws() {
    log_info "Checking AWS GPU instances..."

    # Check if AWS CLI is available
    if ! command -v aws &> /dev/null; then
        log_warn "AWS CLI not installed, skipping AWS check"
        return
    fi

    # GPU instance types to monitor
    GPU_TYPES="g4dn.*|g5.*|p3.*|p4d.*|p4de.*|p5.*|g3.*|g3s.*|g6.*|gr6.*"

    # Get running GPU instances
    INSTANCES=$(aws ec2 describe-instances \
        --filters "Name=instance-state-name,Values=running" \
        --query "Reservations[*].Instances[*].[InstanceId,InstanceType,LaunchTime,Tags[?Key=='Name'].Value|[0]]" \
        --output text 2>/dev/null | grep -E "$GPU_TYPES" || true)

    if [ -z "$INSTANCES" ]; then
        log_ok "No AWS GPU instances running"
        return
    fi

    echo "$INSTANCES" | while read -r INSTANCE_ID INSTANCE_TYPE LAUNCH_TIME NAME; do
        NAME="${NAME:-unnamed}"

        # Calculate runtime
        RUNTIME_MIN=0
        if [ -n "$LAUNCH_TIME" ]; then
            LAUNCH_EPOCH=$(date -d "$LAUNCH_TIME" +%s 2>/dev/null || echo "0")
            NOW_EPOCH=$(date +%s)
            RUNTIME_MIN=$(( (NOW_EPOCH - LAUNCH_EPOCH) / 60 ))
        fi

        # Estimate cost (approximate)
        COST_PER_HR="0.50"  # Default estimate
        case "$INSTANCE_TYPE" in
            g4dn.xlarge) COST_PER_HR="0.52" ;;
            g4dn.2xlarge) COST_PER_HR="0.75" ;;
            g5.xlarge) COST_PER_HR="1.00" ;;
            p3.2xlarge) COST_PER_HR="3.06" ;;
        esac

        TOTAL_RUNNING=$((TOTAL_RUNNING + 1))

        log_info "  Instance: $INSTANCE_ID ($NAME)"
        log_info "    Type: $INSTANCE_TYPE | Runtime: ${RUNTIME_MIN} min | Est. cost: \$${COST_PER_HR}/hr"

        # Check GPU utilization via CloudWatch (if available)
        GPU_UTIL=0
        # Note: CloudWatch GPU metrics require the CloudWatch agent
        # For now, we use a simpler heuristic based on runtime

        # Decision logic
        SHOULD_KILL=false
        REASON=""

        if [ "${RUNTIME_MIN:-0}" -lt "$MIN_SAFE_RUNTIME_MIN" ]; then
            log_ok "    Status: STARTING (runtime < ${MIN_SAFE_RUNTIME_MIN} min)"
        elif [ "${RUNTIME_MIN:-0}" -gt $((MAX_RUNTIME_HOURS * 60)) ]; then
            SHOULD_KILL=true
            REASON="exceeded max runtime (${MAX_RUNTIME_HOURS}h safety cap)"
        elif [ "${RUNTIME_MIN:-0}" -gt "$IDLE_THRESHOLD_MIN" ]; then
            # For AWS, we're more conservative - only kill if past safety cap
            # since we can't easily check GPU utilization
            log_warn "    Status: RUNNING ${RUNTIME_MIN} min (check if still needed)"
        else
            log_ok "    Status: OK"
        fi

        if [ "$SHOULD_KILL" = true ]; then
            log_warn "    Status: SHOULD TERMINATE - $REASON"

            if [ "$KILL_MODE" = true ]; then
                log_warn "    Terminating instance..."
                aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" > /dev/null 2>&1
                log_ok "    Terminated: $INSTANCE_ID"
                TOTAL_KILLED=$((TOTAL_KILLED + 1))
            else
                log_warn "    Would terminate (run with --kill to execute)"
            fi
        fi

        echo ""
    done
}

#===============================================================================
# Main
#===============================================================================

main() {
    if [ "$CRON_MODE" = false ]; then
        echo "============================================================================"
        echo "GPU Cost Guardian - Smart Watchdog"
        echo "============================================================================"
        echo ""
        echo "Settings:"
        echo "  Idle threshold:    ${IDLE_THRESHOLD_MIN} min"
        echo "  Max runtime:       ${MAX_RUNTIME_HOURS} hours"
        echo "  GPU active if:     >${GPU_ACTIVE_THRESHOLD}% utilization"
        echo "  Kill mode:         $KILL_MODE"
        echo ""
    fi

    check_runpod
    echo ""
    check_aws

    if [ "$CRON_MODE" = false ]; then
        echo ""
        echo "============================================================================"
        echo "Summary"
        echo "============================================================================"
        echo "  GPU resources found: $TOTAL_RUNNING"
        echo "  Resources terminated: $TOTAL_KILLED"
        if [ "$KILL_MODE" = false ] && [ "$TOTAL_RUNNING" -gt 0 ]; then
            echo ""
            echo "  Run with --kill to terminate idle resources"
        fi
        echo ""
    else
        # Cron mode - only log if something happened
        if [ "$TOTAL_KILLED" -gt 0 ]; then
            log_warn "Terminated $TOTAL_KILLED idle GPU resource(s)"
        fi
    fi

    # Generate and upload dashboard
    DASHBOARD_SCRIPT="$SCRIPT_DIR/998-DASHBOARD--generate-gpu-status.sh"
    if [ -x "$DASHBOARD_SCRIPT" ]; then
        if [ "$CRON_MODE" = false ]; then
            echo ""
            echo "Updating dashboard..."
        fi
        "$DASHBOARD_SCRIPT" 2>/dev/null
    fi
}

main
