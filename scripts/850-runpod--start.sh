#!/bin/bash
# =============================================================================
# 850-runpod--start.sh
# =============================================================================
# Creates a RunPod GPU Pod for WhisperX batch transcription
#
# WHAT THIS SCRIPT DOES:
#   1. Queries RunPod API for available GPUs and their prices
#   2. AUTO-SELECTS the cheapest available GPU on community cloud
#   3. Creates a GPU pod with the WhisperX Docker image
#   4. Waits for the pod to become ready
#   5. Saves pod ID and endpoint URL to .env
#
# PREREQUISITES:
#   - RunPod account with API key (https://www.runpod.io/console/user/settings)
#   - Docker image pushed to Docker Hub
#   - .env file with RUNPOD_API_KEY configured
#
# Usage: ./scripts/850-runpod--start.sh [OPTIONS]
#
# Options:
#   --gpu TYPE      Override GPU type (default: auto-select cheapest)
#   --list-gpus     List available GPU types and exit
#   --debug         Show full API responses
#   --help          Show this help message
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

# Setup logging
mkdir -p "$REPO_ROOT/logs"
exec > >(tee -a "$REPO_ROOT/logs/850-runpod--start-$(date +%Y%m%d-%H%M%S).log") 2>&1

# Source common functions
source "$REPO_ROOT/scripts/lib/common-functions.sh"

# =============================================================================
# Configuration
# =============================================================================

RUNPOD_GRAPHQL_API="https://api.runpod.io/graphql"
RUNPOD_REST_API="https://rest.runpod.io/v1"
GPU_TYPE=""
DEBUG_MODE=false
LIST_GPUS=false

# =============================================================================
# Parse Arguments
# =============================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --gpu)
            GPU_TYPE="$2"
            shift 2
            ;;
        --list-gpus)
            LIST_GPUS=true
            shift
            ;;
        --debug)
            DEBUG_MODE=true
            shift
            ;;
        --help)
            head -30 "$0" | grep "^#" | sed 's/^# //' | sed 's/^#//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# =============================================================================
# Debug Helper
# =============================================================================

debug_log() {
    if [ "$DEBUG_MODE" = true ]; then
        echo "[DEBUG] $1"
    fi
}

debug_json() {
    if [ "$DEBUG_MODE" = true ]; then
        echo "[DEBUG] API Response:"
        echo "$1" | jq . 2>/dev/null || echo "$1"
        echo ""
    fi
}

# =============================================================================
# Known GPU Types (fallback when API doesn't return list)
# =============================================================================
# These are known cheap GPUs on RunPod community cloud, sorted by typical price
KNOWN_CHEAP_GPUS=(
    "NVIDIA GeForce RTX 3070"      # ~$0.13/hr, 8GB
    "NVIDIA RTX A4000"             # ~$0.17/hr, 16GB
    "NVIDIA GeForce RTX 3080"      # ~$0.17/hr, 10GB
    "NVIDIA RTX A5000"             # ~$0.16/hr, 24GB
    "NVIDIA GeForce RTX 4070 Ti"   # ~$0.20/hr, 12GB
)

# =============================================================================
# Find Cheapest Available GPU
# =============================================================================

find_cheapest_gpu() {
    # Log to stderr so stdout only contains the GPU name
    log_info "Finding cheapest available GPU on community cloud..." >&2
    log_info "Using known GPU list (RTX 3070 is typically cheapest at ~\$0.13/hr)" >&2

    # Return the first known cheap GPU - RTX 3070
    # The pod creation will fail if not available, and we can try another
    echo "NVIDIA GeForce RTX 3070"
}

# =============================================================================
# List Available GPUs
# =============================================================================

list_available_gpus() {
    echo ""
    echo "============================================"
    echo "Known Cheap GPUs on RunPod Community Cloud"
    echo "============================================"
    echo ""
    printf "%-35s %-8s %-12s\n" "GPU Type" "VRAM" "Est. Price"
    printf "%-35s %-8s %-12s\n" "--------" "----" "----------"
    printf "%-35s %-8s %-12s\n" "NVIDIA GeForce RTX 3070" "8GB" "\$0.13/hr"
    printf "%-35s %-8s %-12s\n" "NVIDIA RTX A5000" "24GB" "\$0.16/hr"
    printf "%-35s %-8s %-12s\n" "NVIDIA RTX A4000" "16GB" "\$0.17/hr"
    printf "%-35s %-8s %-12s\n" "NVIDIA GeForce RTX 3080" "10GB" "\$0.17/hr"
    printf "%-35s %-8s %-12s\n" "NVIDIA GeForce RTX 4070 Ti" "12GB" "\$0.20/hr"

    echo ""
    echo "Note: Prices vary based on availability. The script will"
    echo "default to RTX 3070 (cheapest) when auto-selecting."
    echo ""
    echo "To use a specific GPU:"
    echo "  ./scripts/850-runpod--start.sh --gpu \"NVIDIA RTX A5000\""
    echo ""
}

# =============================================================================
# Try Create Pod (single attempt)
# =============================================================================

try_create_pod() {
    local gpu_type="$1"
    local pod_name="$2"
    local docker_image="$3"

    # Build request payload
    local payload=$(cat <<EOF
{
    "name": "$pod_name",
    "imageName": "$docker_image",
    "gpuTypeIds": ["$gpu_type"],
    "cloudType": "COMMUNITY",
    "gpuCount": 1,
    "volumeInGb": 0,
    "containerDiskInGb": 50,
    "ports": ["8000/http"],
    "env": {
        "WHISPER_MODEL": "${WHISPER_MODEL:-small}",
        "WHISPER_COMPUTE_TYPE": "${WHISPER_COMPUTE_TYPE:-float16}",
        "WHISPER_BATCH_SIZE": "${WHISPER_BATCH_SIZE:-16}",
        "HF_TOKEN": "${HF_TOKEN:-}",
        "ENABLE_DIARIZATION": "${ENABLE_DIARIZATION:-false}"
    }
}
EOF
)

    debug_log "Request payload:"
    debug_json "$payload"

    local response=$(curl -s -X POST "${RUNPOD_REST_API}/pods" \
        -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$payload")

    debug_json "$response"

    # Check for error (API returns array on error, object on success)
    # Array response = error, Object with "id" = success
    local is_array=$(echo "$response" | jq -r 'if type == "array" then "yes" else "no" end' 2>/dev/null)

    if [ "$is_array" = "yes" ]; then
        local error_msg=$(echo "$response" | jq -r '.[0].error // .[0].problems[0] // "unknown error"' 2>/dev/null)
        echo "FAILED:$error_msg"
        return 1
    fi

    # Check for error field in object response
    if echo "$response" | jq -e '.error' &>/dev/null 2>&1; then
        local error_msg=$(echo "$response" | jq -r '.error // "unknown error"' 2>/dev/null)
        echo "FAILED:$error_msg"
        return 1
    fi

    # Extract pod ID
    local pod_id=$(echo "$response" | jq -r '.id // .podId // empty' 2>/dev/null)

    if [ -z "$pod_id" ]; then
        echo "FAILED:No pod ID in response"
        return 1
    fi

    echo "$pod_id"
    return 0
}

# =============================================================================
# Create Pod (with fallback to other GPUs)
# =============================================================================

create_pod() {
    local gpu_type="$1"
    local pod_name="$2"
    local docker_image="$3"

    # Use stderr for logs so stdout only contains pod_id
    log_info "Creating RunPod GPU Pod..." >&2
    echo "" >&2
    echo "  Configuration:" >&2
    echo "  ─────────────────────────────────────────" >&2
    echo "  Pod Name:     $pod_name" >&2
    echo "  GPU Type:     $gpu_type" >&2
    echo "  Cloud Type:   COMMUNITY (cheapest)" >&2
    echo "  Docker Image: $docker_image" >&2
    echo "  ─────────────────────────────────────────" >&2
    echo "" >&2

    log_info "Sending create request to RunPod API..." >&2

    local result=$(try_create_pod "$gpu_type" "$pod_name" "$docker_image")

    if [[ "$result" != FAILED:* ]]; then
        # Success!
        local pod_id="$result"
        log_success "Pod created! ID: $pod_id" >&2

        # Save pod ID to .env (quote values with spaces)
        update_env_var "RUNPOD_POD_ID" "$pod_id"
        update_env_var "RUNPOD_GPU_SELECTED" "\"$gpu_type\""
        log_success "Saved RUNPOD_POD_ID and RUNPOD_GPU_SELECTED to .env" >&2

        echo "$pod_id"
        return 0
    fi

    # First GPU failed - try others in the list
    local error_msg="${result#FAILED:}"
    log_warn "GPU '$gpu_type' not available: $error_msg" >&2
    log_info "Trying other GPUs..." >&2
    echo "" >&2

    for fallback_gpu in "${KNOWN_CHEAP_GPUS[@]}"; do
        # Skip the one we already tried
        if [ "$fallback_gpu" = "$gpu_type" ]; then
            continue
        fi

        log_info "Trying: $fallback_gpu..." >&2
        result=$(try_create_pod "$fallback_gpu" "$pod_name" "$docker_image")

        if [[ "$result" != FAILED:* ]]; then
            # Success!
            local pod_id="$result"
            log_success "Pod created with $fallback_gpu! ID: $pod_id" >&2

            # Save pod ID to .env (quote values with spaces)
            update_env_var "RUNPOD_POD_ID" "$pod_id"
            update_env_var "RUNPOD_GPU_SELECTED" "\"$fallback_gpu\""
            log_success "Saved RUNPOD_POD_ID and RUNPOD_GPU_SELECTED to .env" >&2

            echo "$pod_id"
            return 0
        fi

        error_msg="${result#FAILED:}"
        log_warn "  Not available: $error_msg" >&2
    done

    # All GPUs failed
    log_error "No GPUs available on community cloud" >&2
    echo "" >&2
    echo "All attempted GPUs:" >&2
    for gpu in "${KNOWN_CHEAP_GPUS[@]}"; do
        echo "  - $gpu" >&2
    done
    echo "" >&2
    echo "Options:" >&2
    echo "  1. Try again later (availability changes frequently)" >&2
    echo "  2. Use secure cloud (more expensive but more reliable):" >&2
    echo "     Edit script to use cloudType: SECURE" >&2
    echo "  3. Check RunPod console: https://www.runpod.io/console/pods" >&2
    echo "" >&2
    return 1
}

# =============================================================================
# Wait for Pod Ready
# =============================================================================

wait_for_pod_ready() {
    local pod_id="$1"
    local max_attempts=30
    local attempt=1

    log_info "Waiting for pod to become ready..."
    echo "  (This typically takes 1-3 minutes for image pull + startup)"
    echo ""

    while [ $attempt -le $max_attempts ]; do
        local response=$(curl -s "${RUNPOD_REST_API}/pods/${pod_id}" \
            -H "Authorization: Bearer ${RUNPOD_API_KEY}")

        debug_json "$response"

        local status=$(echo "$response" | jq -r '.desiredStatus // .status // "unknown"')
        local runtime=$(echo "$response" | jq -r '.runtime // empty')

        # Show progress
        printf "  [%2d/%d] Status: %s\n" "$attempt" "$max_attempts" "$status"

        if [ "$status" = "RUNNING" ] && [ -n "$runtime" ] && [ "$runtime" != "null" ]; then
            # For community cloud, we need to use proxy URL format
            local pod_id_short=$(echo "$pod_id" | cut -c1-12)
            local proxy_host="${pod_id}-8000.proxy.runpod.net"
            local proxy_port="443"

            echo ""
            log_success "============================================"
            log_success "POD IS READY!"
            log_success "============================================"
            echo ""
            echo "  Pod ID:   $pod_id"
            echo "  Endpoint: https://${proxy_host}"
            echo ""

            # Save endpoint to .env (proxy URL for community cloud)
            update_env_var "RUNPOD_HOST" "$proxy_host"
            update_env_var "RUNPOD_PORT" "$proxy_port"
            update_env_var "RUNPOD_HTTPS" "true"

            log_success "Saved endpoint to .env"
            echo ""
            echo "  Next steps:"
            echo "  ─────────────────────────────────────────"
            echo "  1. Check status: ./scripts/851-runpod--status.sh"
            echo "  2. View logs:    ./scripts/852-runpod--logs.sh"
            echo "  3. Transcribe:   ./scripts/515-runpod--batch-transcribe.sh --all"
            echo "  4. Stop pod:     ./scripts/855-runpod--stop.sh"
            echo ""

            return 0
        fi

        # Check for failed state
        if [ "$status" = "EXITED" ] || [ "$status" = "FAILED" ]; then
            log_error "Pod failed to start (status: $status)"
            echo ""
            echo "Full response:"
            echo "$response" | jq .
            return 1
        fi

        sleep 10
        attempt=$((attempt + 1))
    done

    log_warn "Timeout waiting for pod"
    echo ""
    echo "The pod may still be starting. Check status manually:"
    echo "  ./scripts/851-runpod--status.sh"
    echo ""
    echo "Or check the RunPod console:"
    echo "  https://www.runpod.io/console/pods"

    return 1
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo ""
    log_info "============================================"
    log_info "RunPod GPU Pod Starter"
    log_info "============================================"
    echo ""

    # Load environment
    load_environment

    # Validate API key
    if [ -z "${RUNPOD_API_KEY:-}" ]; then
        log_error "RUNPOD_API_KEY not set in .env"
        echo ""
        echo "Get your API key from: https://www.runpod.io/console/user/settings"
        echo "Then add it to .env: RUNPOD_API_KEY=rpa_xxxxx"
        exit 1
    fi

    # Handle --list-gpus
    if [ "$LIST_GPUS" = true ]; then
        list_available_gpus
        exit 0
    fi

    # Check if pod already exists
    if [ -n "${RUNPOD_POD_ID:-}" ] && [ "${RUNPOD_POD_ID}" != "" ]; then
        log_warn "Pod ID already configured: $RUNPOD_POD_ID"
        echo ""
        echo "Options:"
        echo "  1. Delete existing pod first:"
        echo "     ./scripts/855-runpod--stop.sh"
        echo ""
        echo "  2. Check existing pod status:"
        echo "     ./scripts/851-runpod--status.sh"
        echo ""
        exit 1
    fi

    # Determine GPU type
    if [ -z "$GPU_TYPE" ]; then
        # Auto-select cheapest GPU
        GPU_TYPE=$(find_cheapest_gpu)
        if [ -z "$GPU_TYPE" ]; then
            log_error "Failed to find available GPU"
            exit 1
        fi
    else
        log_info "Using specified GPU: $GPU_TYPE"
    fi

    # Set pod name
    local pod_name="whisperx-$(date +%Y%m%d-%H%M%S)"

    # Get Docker image from .env
    local docker_image="${WHISPERX_DOCKER_IMAGE:-davidbmar/whisperx-runpod:latest}"

    # Create pod
    local pod_id=$(create_pod "$GPU_TYPE" "$pod_name" "$docker_image")

    if [ -z "$pod_id" ]; then
        exit 1
    fi

    # Log the start event
    if [ -f "$SCRIPT_DIR/lib/gpu-event-logger.sh" ]; then
        source "$SCRIPT_DIR/lib/gpu-event-logger.sh"
        log_runpod_start "$pod_id" "$pod_name" "$GPU_TYPE" "0" "$docker_image"
    fi

    # Wait for ready
    wait_for_pod_ready "$pod_id"
}

# =============================================================================
# Run
# =============================================================================

main "$@"
