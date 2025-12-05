#!/bin/bash
set -euo pipefail

# Log to file and stdout
mkdir -p "$(dirname "${BASH_SOURCE[0]}")/../logs"
exec > >(tee -a "$(dirname "${BASH_SOURCE[0]}")/../logs/523-run-diarization-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Script 523: Run Diarization on GPU Instance (from build box)
# ============================================================================
# Runs speaker diarization on the GPU instance remotely.
#
# Usage:
#   ./scripts/523-run-diarization.sh [--dry-run] [--backfill] [--limit N]
#
# Options:
#   --dry-run   Preview what would be processed without making changes
#   --backfill  Reprocess all transcripts (even those already diarized)
#   --limit N   Process at most N files
#
# Prerequisites:
#   - GPU instance running (start with 820-start-gpu-instance.sh)
#   - Diarization setup complete (505-deploy-batch-worker.sh)
# ============================================================================

# Resolve script path
if [ -L "${BASH_SOURCE[0]}" ]; then
    SCRIPT_REAL=$(readlink -f "${BASH_SOURCE[0]}")
else
    SCRIPT_REAL="${BASH_SOURCE[0]}"
fi
PROJECT_ROOT="$(cd "$(dirname "$SCRIPT_REAL")/.." && pwd)"

# Load environment
source "$PROJECT_ROOT/.env"
source "$PROJECT_ROOT/scripts/lib/common-functions.sh"

# Parse arguments
DRY_RUN=""
BACKFILL=""
LIMIT=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN="--dry-run"
            shift
            ;;
        --backfill)
            BACKFILL="--backfill"
            shift
            ;;
        --limit)
            LIMIT="--max-sessions $2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--dry-run] [--backfill] [--limit N]"
            exit 1
            ;;
    esac
done

echo "============================================"
echo "523: Run Diarization on GPU"
echo "============================================"
echo ""
echo "NOTE: This script uses AWS IAM role authentication which only works"
echo "on EC2 instances. For Salad or other external GPU providers, you'll"
echo "need to pass AWS credentials as environment variables instead."
echo ""
read -p "Press Enter to continue..."
echo ""

# Get SSH key path
if [[ "$GPU_SSH_KEY_PATH" = /* ]]; then
    SSH_KEY="$GPU_SSH_KEY_PATH"
else
    SSH_KEY="$PROJECT_ROOT/$GPU_SSH_KEY_PATH"
fi

# Check if SSH key exists, fall back to SSH_KEY_NAME
if [ ! -f "$SSH_KEY" ]; then
    if [ -n "${SSH_KEY_NAME:-}" ]; then
        SSH_KEY="$HOME/.ssh/${SSH_KEY_NAME}.pem"
    fi
fi

GPU_IP="$GPU_INSTANCE_IP"

log_info "GPU Instance: $GPU_IP"
log_info "Options: ${DRY_RUN:-} ${BACKFILL:-} ${LIMIT:-}"
echo ""

# Check GPU is reachable
log_info "Checking GPU connectivity..."
if ! ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@"$GPU_IP" 'echo "Connected"' 2>/dev/null; then
    log_error "Cannot connect to GPU instance at $GPU_IP"
    log_info "Start the GPU with: ./scripts/820-start-gpu-instance.sh"
    exit 1
fi
log_success "GPU reachable"
echo ""

# Run diarization
log_info "Running diarization on GPU..."
echo ""

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ubuntu@"$GPU_IP" "
    source /opt/conda/bin/activate diarization
    cd ~/batch-transcription
    set -a && source .env && set +a
    python 520-diarize-transcripts.py $DRY_RUN $BACKFILL $LIMIT
"

echo ""
log_success "Diarization complete"
