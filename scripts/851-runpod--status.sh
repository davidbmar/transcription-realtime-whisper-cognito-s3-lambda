#!/bin/bash
# =============================================================================
# 851-runpod--status.sh
# =============================================================================
# Check the status of the RunPod GPU pod
#
# WHAT THIS SCRIPT DOES:
#   1. Queries RunPod API for pod status
#   2. Performs health check on the WhisperX API
#   3. Shows GPU utilization and cost accumulator
#
# Usage: ./scripts/851-runpod--status.sh [OPTIONS]
#
# Options:
#   --debug     Show full API responses
#   --help      Show this help message
#
# =============================================================================

set -euo pipefail

# Find repository root
if [ -L "${BASH_SOURCE[0]}" ]; then
    SCRIPT_REAL=$(readlink -f "${BASH_SOURCE[0]}")
else
    SCRIPT_REAL="${BASH_SOURCE[0]}"
fi
REPO_ROOT="$(cd "$(dirname "$SCRIPT_REAL")/.." && pwd)"

# Source common functions
source "$REPO_ROOT/scripts/lib/common-functions.sh"

# =============================================================================
# Configuration
# =============================================================================

RUNPOD_REST_API="https://rest.runpod.io/v1"
DEBUG_MODE=false

# =============================================================================
# Parse Arguments
# =============================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --debug)
            DEBUG_MODE=true
            shift
            ;;
        --help)
            head -20 "$0" | grep "^#" | sed 's/^# //' | sed 's/^#//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# =============================================================================
# Main
# =============================================================================

main() {
    echo ""
    log_info "============================================"
    log_info "RunPod GPU Pod Status"
    log_info "============================================"
    echo ""

    # Load environment
    load_environment

    # Check pod ID
    if [ -z "${RUNPOD_POD_ID:-}" ]; then
        log_warn "No pod configured (RUNPOD_POD_ID not set)"
        echo ""
        echo "Start a pod first: ./scripts/850-runpod--start.sh"
        exit 0
    fi

    log_info "Pod ID: $RUNPOD_POD_ID"
    echo ""

    # Query pod status
    log_info "Querying RunPod API..."

    local response=$(curl -s "${RUNPOD_REST_API}/pods/${RUNPOD_POD_ID}" \
        -H "Authorization: Bearer ${RUNPOD_API_KEY}")

    if [ "$DEBUG_MODE" = true ]; then
        echo "[DEBUG] Full response:"
        echo "$response" | jq .
        echo ""
    fi

    # Check for error
    if echo "$response" | jq -e '.error' &>/dev/null; then
        log_error "Pod not found or API error"
        echo "$response" | jq .
        exit 1
    fi

    # Extract status info
    local status=$(echo "$response" | jq -r '.desiredStatus // "unknown"')
    local gpu_type=$(echo "$response" | jq -r '.machine.gpuDisplayName // "unknown"')
    local gpu_util=$(echo "$response" | jq -r '.runtime.gpus[0].gpuUtilPercent // "N/A"')
    local cost_per_hr=$(echo "$response" | jq -r '.costPerHr // "N/A"')

    echo "  ─────────────────────────────────────────"
    echo "  Status:      $status"
    echo "  GPU Type:    $gpu_type"
    echo "  GPU Util:    ${gpu_util}%"
    echo "  Cost/hr:     \$${cost_per_hr}"
    echo "  ─────────────────────────────────────────"
    echo ""

    # Health check if running
    if [ "$status" = "RUNNING" ]; then
        log_info "Performing health check..."

        local host="${RUNPOD_HOST:-}"
        local port="${RUNPOD_PORT:-443}"
        local protocol="https"

        if [ "${RUNPOD_HTTPS:-true}" != "true" ]; then
            protocol="http"
        fi

        if [ -n "$host" ]; then
            local health_url="${protocol}://${host}/health"
            local health_response=$(curl -s --max-time 10 "$health_url" 2>/dev/null || echo '{"error": "timeout"}')

            if echo "$health_response" | jq -e '.status' &>/dev/null; then
                local health_status=$(echo "$health_response" | jq -r '.status // "unknown"')
                local device=$(echo "$health_response" | jq -r '.device // "unknown"')
                local model=$(echo "$health_response" | jq -r '.model // "unknown"')

                echo "  Health Check:"
                echo "  ─────────────────────────────────────────"
                echo "  API Status:  $health_status"
                echo "  Device:      $device"
                echo "  Model:       $model"
                echo "  Endpoint:    ${protocol}://${host}"
                echo "  ─────────────────────────────────────────"
                echo ""
                log_success "Pod is healthy and ready for transcription"
            else
                log_warn "Health check failed or timed out"
                echo "  Response: $health_response"
            fi
        else
            log_warn "RUNPOD_HOST not configured in .env"
        fi
    else
        log_warn "Pod is not running (status: $status)"
    fi

    echo ""
    echo "  Actions:"
    echo "  ─────────────────────────────────────────"
    echo "  View logs:    ./scripts/852-runpod--logs.sh"
    echo "  Transcribe:   ./scripts/515-runpod--batch-transcribe.sh"
    echo "  Stop pod:     ./scripts/855-runpod--stop.sh"
    echo ""
}

main "$@"
