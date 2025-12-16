#!/bin/bash
# =============================================================================
# 855-runpod--stop.sh
# =============================================================================
# Stop and delete the RunPod GPU pod
#
# WHAT THIS SCRIPT DOES:
#   1. Terminates the RunPod GPU pod
#   2. Clears pod-related variables from .env
#   3. Saves money by stopping when not in use!
#
# Usage: ./scripts/855-runpod--stop.sh [OPTIONS]
#
# Options:
#   --force     Skip confirmation prompt
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
FORCE_MODE=false

# =============================================================================
# Parse Arguments
# =============================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --force|-f)
            FORCE_MODE=true
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
    log_info "RunPod GPU Pod Stop"
    log_info "============================================"
    echo ""

    # Load environment
    load_environment

    # Check pod ID
    if [ -z "${RUNPOD_POD_ID:-}" ]; then
        log_warn "No pod configured (RUNPOD_POD_ID not set)"
        echo ""
        echo "Nothing to stop."
        exit 0
    fi

    log_info "Pod ID: $RUNPOD_POD_ID"
    log_info "GPU:    ${RUNPOD_GPU_SELECTED:-unknown}"
    echo ""

    # Confirmation
    if [ "$FORCE_MODE" != true ]; then
        echo "This will PERMANENTLY DELETE the pod and all data."
        echo ""
        read -p "Are you sure? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log_info "Cancelled"
            exit 0
        fi
        echo ""
    fi

    # Delete pod
    log_info "Deleting pod..."

    local response=$(curl -s -X DELETE "${RUNPOD_REST_API}/pods/${RUNPOD_POD_ID}" \
        -H "Authorization: Bearer ${RUNPOD_API_KEY}")

    # Check for error
    local pod_deleted=true
    if echo "$response" | jq -e '.error' &>/dev/null; then
        local error_msg=$(echo "$response" | jq -r '.error // "unknown error"')
        if [[ "$error_msg" == *"not found"* ]]; then
            log_warn "Pod already deleted (not found)"
        else
            log_error "Failed to delete pod: $error_msg"
            echo "$response" | jq .
            exit 1
        fi
    else
        log_success "Pod deleted successfully!"
    fi
    echo ""

    # Log termination event
    if [ -f "$REPO_ROOT/scripts/lib/gpu-event-logger.sh" ]; then
        source "$REPO_ROOT/scripts/lib/gpu-event-logger.sh"
        log_runpod_terminate "$RUNPOD_POD_ID" "user-terminated"
    fi

    # Clear env vars
    log_info "Clearing pod configuration from .env..."

    update_env_var "RUNPOD_POD_ID" ""
    update_env_var "RUNPOD_HOST" ""
    update_env_var "RUNPOD_PORT" ""
    update_env_var "RUNPOD_GPU_SELECTED" ""

    log_success "Configuration cleared"
    echo ""
    echo "  To start a new pod:"
    echo "  ./scripts/850-runpod--start.sh"
    echo ""
}

main "$@"
