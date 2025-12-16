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
#   --secure        Use secure cloud (guaranteed availability, ~2x cost)
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
USE_SECURE_CLOUD=false

# =============================================================================
# Parse Arguments
# =============================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --gpu)
            GPU_TYPE="$2"
            shift 2
            ;;
        --secure)
            USE_SECURE_CLOUD=true
            shift
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
# Find Cheapest Available GPU (with real-time stock check)
# =============================================================================

find_cheapest_gpu() {
    # Log to stderr so stdout only contains the GPU name
    log_info "Querying RunPod API for GPU availability..." >&2

    # Query GPU types with stock status
    local response=$(curl -s -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
        -H "Content-Type: application/json" \
        -X POST "${RUNPOD_GRAPHQL_API}" \
        -d '{"query":"{ gpuTypes { id displayName memoryInGb communityCloud lowestPrice(input:{gpuCount:1}) { minimumBidPrice uninterruptablePrice stockStatus } } }"}')

    # Parse and find available GPUs sorted by price
    local gpu_id=$(echo "$response" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    gpus = d.get('data', {}).get('gpuTypes', [])

    # Filter community cloud GPUs with High or Medium stock
    available = []
    for g in gpus:
        if not g.get('communityCloud'):
            continue
        lp = g.get('lowestPrice', {})
        stock = (lp.get('stockStatus') or '').lower()
        price = lp.get('uninterruptablePrice')
        if stock in ['high', 'medium'] and price:
            available.append({
                'id': g['id'],
                'name': g['displayName'],
                'price': float(price),
                'stock': stock,
                'mem': g.get('memoryInGb', 0)
            })

    if not available:
        # Fallback to Low stock if nothing else available
        for g in gpus:
            if not g.get('communityCloud'):
                continue
            lp = g.get('lowestPrice', {})
            price = lp.get('uninterruptablePrice')
            if price:
                available.append({
                    'id': g['id'],
                    'name': g['displayName'],
                    'price': float(price),
                    'stock': lp.get('stockStatus', 'unknown'),
                    'mem': g.get('memoryInGb', 0)
                })

    # Sort by price
    available.sort(key=lambda x: x['price'])

    if available:
        best = available[0]
        # Output to stderr for logging
        print(f\"Found {len(available)} available GPUs\", file=sys.stderr)
        print(f\"Best: {best['name']} ({best['mem']}GB) @ \${best['price']}/hr [{best['stock']} stock]\", file=sys.stderr)
        # Output just the ID to stdout
        print(best['id'])
    else:
        print('No GPUs available', file=sys.stderr)
except Exception as e:
    print(f'Error parsing GPU data: {e}', file=sys.stderr)
" 2>&2)

    if [ -n "$gpu_id" ]; then
        echo "$gpu_id"
    else
        # Fallback to known GPU
        log_warn "API query failed, falling back to RTX A5000" >&2
        echo "NVIDIA RTX A5000"
    fi
}

# =============================================================================
# List Available GPUs (real-time from API)
# =============================================================================

list_available_gpus() {
    echo ""
    echo "============================================"
    echo "RunPod Community Cloud - GPU Availability"
    echo "============================================"
    echo ""
    echo "Querying RunPod API..."
    echo ""

    curl -s -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
        -H "Content-Type: application/json" \
        -X POST "${RUNPOD_GRAPHQL_API}" \
        -d '{"query":"{ gpuTypes { id displayName memoryInGb communityCloud lowestPrice(input:{gpuCount:1}) { minimumBidPrice uninterruptablePrice stockStatus } } }"}' | python3 -c "
import sys, json
d = json.load(sys.stdin)
gpus = d.get('data', {}).get('gpuTypes', [])

print(f\"{'':3}{'GPU Type':<38} {'VRAM':>6} {'Price':>9} {'Stock':>8}\")
print('-' * 70)

community = []
for g in gpus:
    if not g.get('communityCloud'):
        continue
    lp = g.get('lowestPrice', {})
    if not lp:
        continue
    community.append({
        'id': g['id'],
        'name': g['displayName'],
        'mem': g.get('memoryInGb', 0),
        'price': lp.get('uninterruptablePrice'),
        'stock': lp.get('stockStatus', 'unknown')
    })

community.sort(key=lambda x: float(x['price']) if x['price'] else 999)

for g in community[:20]:
    stock = g['stock'] or 'unknown'
    marker = '✓' if stock.lower() in ['high', 'medium'] else ' '
    stock_display = stock.upper() if stock.lower() in ['high', 'medium'] else stock
    price = f\"\${g['price']}/hr\" if g['price'] else 'N/A'
    print(f\"{marker:3}{g['name']:<38} {g['mem']:>4}GB {price:>9} {stock_display:>8}\")

print()
print('✓ = High/Medium availability (recommended)')
print()
"

    echo ""
    echo "Usage:"
    echo "  ./scripts/850-runpod--start.sh              # Auto-select best available"
    echo "  ./scripts/850-runpod--start.sh --secure     # Use secure cloud (guaranteed)"
    echo "  ./scripts/850-runpod--start.sh --gpu \"NVIDIA RTX A5000\"  # Specific GPU"
    echo ""
}

# =============================================================================
# Try Create Pod (single attempt)
# =============================================================================

try_create_pod() {
    local gpu_type="$1"
    local pod_name="$2"
    local docker_image="$3"

    # Generate presigned URL for pyannote models (valid for 7 days)
    local pyannote_url=""
    if [ "${ENABLE_DIARIZATION:-false}" = "true" ]; then
        log_info "Generating presigned URL for pyannote models..." >&2
        pyannote_url=$(aws s3 presign "s3://dbm-cf-2-web/bintarball/diarized/latest/huggingface-cache.tar.gz" --expires-in 604800 2>/dev/null || echo "")
        if [ -n "$pyannote_url" ]; then
            log_info "Pyannote models URL generated (diarization enabled)" >&2
        else
            log_warn "Could not generate presigned URL - diarization may not work" >&2
        fi
    fi

    # Determine cloud type
    local cloud_type="COMMUNITY"
    if [ "$USE_SECURE_CLOUD" = true ]; then
        cloud_type="SECURE"
    fi

    # Build request payload
    local payload=$(cat <<EOF
{
    "name": "$pod_name",
    "imageName": "$docker_image",
    "gpuTypeIds": ["$gpu_type"],
    "cloudType": "$cloud_type",
    "gpuCount": 1,
    "volumeInGb": 0,
    "containerDiskInGb": 50,
    "ports": ["8000/http"],
    "env": {
        "WHISPER_MODEL": "${WHISPER_MODEL:-small}",
        "WHISPER_COMPUTE_TYPE": "${WHISPER_COMPUTE_TYPE:-float16}",
        "WHISPER_BATCH_SIZE": "${WHISPER_BATCH_SIZE:-16}",
        "HF_TOKEN": "${HF_TOKEN:-}",
        "ENABLE_DIARIZATION": "${ENABLE_DIARIZATION:-false}",
        "PYANNOTE_CACHE_URL": "${pyannote_url:-}"
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

    # Determine cloud type display
    local cloud_display="COMMUNITY (cheapest)"
    if [ "$USE_SECURE_CLOUD" = true ]; then
        cloud_display="SECURE (guaranteed availability)"
    fi

    # Use stderr for logs so stdout only contains pod_id
    log_info "Creating RunPod GPU Pod..." >&2
    echo "" >&2
    echo "  Configuration:" >&2
    echo "  ─────────────────────────────────────────" >&2
    echo "  Pod Name:     $pod_name" >&2
    echo "  GPU Type:     $gpu_type" >&2
    echo "  Cloud Type:   $cloud_display" >&2
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
# Cleanup Pod (on failure)
# =============================================================================

cleanup_pod() {
    local pod_id="$1"
    local reason="$2"

    log_warn "Cleaning up pod $pod_id due to: $reason"

    local response=$(curl -s -X DELETE "${RUNPOD_REST_API}/pods/${pod_id}" \
        -H "Authorization: Bearer ${RUNPOD_API_KEY}")

    # Clear env vars
    update_env_var "RUNPOD_POD_ID" ""
    update_env_var "RUNPOD_HOST" ""
    update_env_var "RUNPOD_PORT" ""
    update_env_var "RUNPOD_GPU_SELECTED" ""

    log_info "Pod deleted and env vars cleared"
}

# =============================================================================
# Wait for Pod to Start (GPU assignment + image pull)
# =============================================================================

wait_for_pod_start() {
    local pod_id="$1"
    local max_attempts=60  # 10 minutes max (10s intervals) - image pull can take a while
    local attempt=1

    log_info "Waiting for pod to start..."
    echo "  (Image pull + container startup typically takes 2-5 minutes)"
    echo ""

    while [ $attempt -le $max_attempts ]; do
        local response=$(curl -s "${RUNPOD_REST_API}/pods/${pod_id}" \
            -H "Authorization: Bearer ${RUNPOD_API_KEY}")

        debug_json "$response"

        local status=$(echo "$response" | jq -r '.desiredStatus // "unknown"')
        local runtime=$(echo "$response" | jq -r '.runtime // empty')
        local machine_id=$(echo "$response" | jq -r '.machineId // empty')

        # Check for failed state first
        if [ "$status" = "EXITED" ] || [ "$status" = "FAILED" ]; then
            log_error "Pod failed (status: $status)"
            return 1
        fi

        # Show detailed progress
        if [ -n "$runtime" ] && [ "$runtime" != "null" ] && [ "$runtime" != "{}" ]; then
            # Runtime exists - container is starting
            local uptime=$(echo "$response" | jq -r '.runtime.uptimeInSeconds // 0')
            printf "  [%2d/%d] Container running (uptime: %ds)\n" "$attempt" "$max_attempts" "$uptime"
            echo ""
            log_success "Pod has started!"
            return 0
        elif [ -n "$machine_id" ] && [ "$machine_id" != "null" ]; then
            # Machine assigned but container not yet running - image pulling
            printf "  [%2d/%d] GPU assigned (machine: %s) - pulling image...\n" "$attempt" "$max_attempts" "${machine_id:0:8}"
        else
            # Waiting for GPU
            printf "  [%2d/%d] Waiting for GPU... (status: %s)\n" "$attempt" "$max_attempts" "$status"
        fi

        sleep 10
        attempt=$((attempt + 1))
    done

    log_warn "Timeout waiting for pod to start after $((max_attempts * 10)) seconds"
    echo ""
    echo "The pod is still pulling the Docker image (7.75GB can take 10-15 min)."
    echo ""
    echo "The pod is NOT being deleted because it has a GPU assigned."
    echo "Check status: ./scripts/851-runpod--status.sh"
    echo "View console: https://www.runpod.io/console/pods"
    echo ""

    # Save the endpoint anyway so user can check health later
    local proxy_host="${pod_id}-8000.proxy.runpod.net"
    update_env_var "RUNPOD_HOST" "$proxy_host"
    update_env_var "RUNPOD_PORT" "443"
    update_env_var "RUNPOD_HTTPS" "true"

    log_info "Endpoint saved to .env - check health when ready:"
    echo "  curl https://${proxy_host}/health"

    # Return success but with warning - don't trigger cleanup
    return 0
}

# =============================================================================
# Wait for Health Check
# =============================================================================

wait_for_health_check() {
    local pod_id="$1"
    local max_attempts=36  # 6 minutes max (10s intervals) - model loading can take time
    local attempt=1
    local proxy_host="${pod_id}-8000.proxy.runpod.net"
    local health_url="https://${proxy_host}/health"

    log_info "Waiting for API to be healthy..."
    echo "  (Container is downloading models and starting FastAPI)"
    echo "  Health endpoint: $health_url"
    echo ""

    while [ $attempt -le $max_attempts ]; do
        local http_code=$(curl -s -o /tmp/health_response.json -w "%{http_code}" \
            --max-time 10 "$health_url" 2>/dev/null || echo "000")

        if [ "$http_code" = "200" ]; then
            local health_status=$(cat /tmp/health_response.json | jq -r '.status // "unknown"' 2>/dev/null)
            local device=$(cat /tmp/health_response.json | jq -r '.device // "unknown"' 2>/dev/null)
            local model=$(cat /tmp/health_response.json | jq -r '.model // "unknown"' 2>/dev/null)
            local diarization=$(cat /tmp/health_response.json | jq -r '.diarization // false' 2>/dev/null)

            printf "  [%2d/%d] HTTP %s - API READY!\n" "$attempt" "$max_attempts" "$http_code"
            echo ""
            log_success "============================================"
            log_success "POD IS READY AND HEALTHY!"
            log_success "============================================"
            echo ""
            echo "  Pod ID:       $pod_id"
            echo "  Endpoint:     https://${proxy_host}"
            echo "  Status:       $health_status"
            echo "  Device:       $device"
            echo "  Model:        $model"
            echo "  Diarization:  $diarization"
            echo ""

            # Save endpoint to .env
            update_env_var "RUNPOD_HOST" "$proxy_host"
            update_env_var "RUNPOD_PORT" "443"
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
        else
            printf "  [%2d/%d] HTTP %s - waiting...\n" "$attempt" "$max_attempts" "$http_code"
        fi

        sleep 10
        attempt=$((attempt + 1))
    done

    log_error "Timeout waiting for health check after $((max_attempts * 10)) seconds"
    echo ""
    echo "The container may have crashed during startup."
    echo "Check the RunPod console for logs:"
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

    # Log the start event (optional)
    if [ -f "$REPO_ROOT/scripts/lib/gpu-event-logger.sh" ]; then
        source "$REPO_ROOT/scripts/lib/gpu-event-logger.sh"
        log_runpod_start "$pod_id" "$pod_name" "$GPU_TYPE" "0" "$docker_image"
    fi

    # Wait for pod to start (GPU assignment + image pull)
    # Note: wait_for_pod_start returns success even on timeout if GPU is assigned
    # to prevent deleting pods that are still pulling the large Docker image
    wait_for_pod_start "$pod_id"
    local start_result=$?

    # Check if pod actually has a GPU assigned
    local pod_status=$(curl -s "${RUNPOD_REST_API}/pods/${pod_id}" \
        -H "Authorization: Bearer ${RUNPOD_API_KEY}")
    local machine_id=$(echo "$pod_status" | jq -r '.machineId // empty')

    if [ -z "$machine_id" ] || [ "$machine_id" = "null" ]; then
        # No GPU assigned - something is wrong, cleanup
        log_error "No GPU was assigned to this pod"
        cleanup_pod "$pod_id" "No GPU assigned"
        exit 1
    fi

    # GPU is assigned - wait for health check
    log_info "Waiting for API to become healthy..."
    if ! wait_for_health_check "$pod_id"; then
        # Health check timed out, but pod has GPU - don't delete
        log_warn "Health check timed out, but pod is running with GPU assigned"
        echo ""
        echo "The container may still be loading models. Check manually:"
        echo "  ./scripts/851-runpod--status.sh"
        echo "  curl https://${pod_id}-8000.proxy.runpod.net/health"
        echo ""
        echo "To stop the pod if needed:"
        echo "  ./scripts/855-runpod--stop.sh"
        echo ""
        exit 0  # Exit without cleanup
    fi

    log_success "Pod startup complete!"
}

# =============================================================================
# Run
# =============================================================================

main "$@"
