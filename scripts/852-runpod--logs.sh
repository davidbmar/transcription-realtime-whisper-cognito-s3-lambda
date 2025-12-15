#!/bin/bash
# =============================================================================
# 852-runpod--logs.sh
# =============================================================================
# View logs from the RunPod GPU pod
#
# WHAT THIS SCRIPT DOES:
#   1. Fetches container logs from RunPod API
#   2. Displays recent log output
#
# Usage: ./scripts/852-runpod--logs.sh [OPTIONS]
#
# Options:
#   --follow    Stream logs (like tail -f)
#   --lines N   Number of lines to show (default: 100)
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
FOLLOW_MODE=false
NUM_LINES=100

# =============================================================================
# Parse Arguments
# =============================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --follow|-f)
            FOLLOW_MODE=true
            shift
            ;;
        --lines|-n)
            NUM_LINES="$2"
            shift 2
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
    log_info "RunPod GPU Pod Logs"
    log_info "============================================"
    echo ""

    # Load environment
    load_environment

    # Check pod ID
    if [ -z "${RUNPOD_POD_ID:-}" ]; then
        log_error "No pod configured (RUNPOD_POD_ID not set)"
        echo ""
        echo "Start a pod first: ./scripts/850-runpod--start.sh"
        exit 1
    fi

    log_info "Pod ID: $RUNPOD_POD_ID"
    log_info "Fetching logs..."
    echo ""

    # Fetch logs via API
    local response=$(curl -s "${RUNPOD_REST_API}/pods/${RUNPOD_POD_ID}/logs" \
        -H "Authorization: Bearer ${RUNPOD_API_KEY}")

    # Check for error
    if echo "$response" | jq -e '.error' &>/dev/null; then
        log_error "Failed to fetch logs"
        echo "$response" | jq .
        exit 1
    fi

    # Extract and display logs
    local logs=$(echo "$response" | jq -r '.logs // empty')

    if [ -z "$logs" ]; then
        log_warn "No logs available yet"
        echo ""
        echo "The container may still be starting."
        echo "Check status: ./scripts/851-runpod--status.sh"
        exit 0
    fi

    echo "─────────────────────────────────────────"
    echo "$logs" | tail -n "$NUM_LINES"
    echo "─────────────────────────────────────────"
    echo ""

    if [ "$FOLLOW_MODE" = true ]; then
        log_info "Streaming logs (Ctrl+C to stop)..."
        echo ""
        while true; do
            sleep 5
            local new_response=$(curl -s "${RUNPOD_REST_API}/pods/${RUNPOD_POD_ID}/logs" \
                -H "Authorization: Bearer ${RUNPOD_API_KEY}")
            local new_logs=$(echo "$new_response" | jq -r '.logs // empty')
            if [ -n "$new_logs" ]; then
                echo "$new_logs" | tail -n 10
            fi
        done
    fi
}

main "$@"
