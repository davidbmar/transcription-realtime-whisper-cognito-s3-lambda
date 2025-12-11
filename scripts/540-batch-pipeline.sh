#!/bin/bash
set -euo pipefail

# ============================================================================
# Script 540: Modular Batch Processing Pipeline
# ============================================================================
# A clean, modular pipeline that processes audio sessions through multiple
# stages. Each stage can be run independently or as part of the full pipeline.
#
# PIPELINE STAGES:
# ┌─────────────────────────────────────────────────────────────────────────┐
# │  Stage 1: TRANSCRIPTION                                                  │
# │  - Input:  Audio chunks (chunk-001.webm, chunk-002.webm, ...)           │
# │  - Output: layers/layer-0-raw-transcription/chunk-*.json                │
# │  - Runs on: GPU (WhisperLive)                                           │
# └─────────────────────────────────────────────────────────────────────────┘
#                                    ▼
# ┌─────────────────────────────────────────────────────────────────────────┐
# │  Stage 2: DIARIZATION (Speaker Identification)                          │
# │  - Input:  Audio + Raw transcription                                    │
# │  - Output: layers/layer-1-diarization/data.json                        │
# │  - Runs on: GPU (pyannote.audio)                                        │
# └─────────────────────────────────────────────────────────────────────────┘
#                                    ▼
# ┌─────────────────────────────────────────────────────────────────────────┐
# │  Stage 3: AI ANALYSIS (Topics, Summary, Action Items)                   │
# │  - Input:  Diarized transcript                                          │
# │  - Output: layers/layer-2-ai-analysis/data.json                        │
# │  - Runs on: Edge Box (Claude API via Bedrock)                           │
# └─────────────────────────────────────────────────────────────────────────┘
#                                    ▼
# ┌─────────────────────────────────────────────────────────────────────────┐
# │  Stage 4: PREPROCESSING (Optimize for UI)                               │
# │  - Input:  All layer data                                               │
# │  - Output: transcription-processed.json (combined, optimized)           │
# │  - Runs on: Edge Box                                                    │
# └─────────────────────────────────────────────────────────────────────────┘
#
# USAGE:
#   ./540-batch-pipeline.sh                    # Run full pipeline on pending sessions
#   ./540-batch-pipeline.sh --stage transcribe # Run only transcription
#   ./540-batch-pipeline.sh --stage diarize    # Run only diarization
#   ./540-batch-pipeline.sh --stage ai         # Run only AI analysis
#   ./540-batch-pipeline.sh --stage preprocess # Run only preprocessing
#   ./540-batch-pipeline.sh --session <path>   # Process specific session
#   ./540-batch-pipeline.sh --dry-run          # Show what would be processed
#
# CONFIGURATION (.env):
#   GPU_INSTANCE_ID        - EC2 instance ID for GPU worker
#   COGNITO_S3_BUCKET      - S3 bucket for audio/transcripts
#   BATCH_THRESHOLD        - Min chunks to trigger batch (default: 1 for manual)
#   ENABLE_DIARIZATION     - Enable/disable diarization (default: true)
#   ENABLE_AI_ANALYSIS     - Enable/disable AI analysis (default: true)
#
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load environment
source "$PROJECT_ROOT/.env"
source "$PROJECT_ROOT/scripts/lib/common-functions.sh"
source "$PROJECT_ROOT/scripts/lib/layer-functions.sh"

# ============================================================================
# Configuration
# ============================================================================

S3_BUCKET="${COGNITO_S3_BUCKET:-clouddrive-app-bucket}"
ENABLE_DIARIZATION="${ENABLE_DIARIZATION:-true}"
ENABLE_AI_ANALYSIS="${ENABLE_AI_ANALYSIS:-true}"
ENABLE_PREPROCESSING="${ENABLE_PREPROCESSING:-true}"

# Parse arguments
STAGE="all"
SESSION_PATH=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --stage)
            STAGE="$2"
            shift 2
            ;;
        --session)
            SESSION_PATH="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "============================================================"
echo "540: Modular Batch Processing Pipeline"
echo "============================================================"
echo ""
echo "Configuration:"
echo "  Stage:              $STAGE"
echo "  Session:            ${SESSION_PATH:-'(all pending)'}"
echo "  Dry run:            $DRY_RUN"
echo "  Diarization:        $ENABLE_DIARIZATION"
echo "  AI Analysis:        $ENABLE_AI_ANALYSIS"
echo "  Preprocessing:      $ENABLE_PREPROCESSING"
echo ""

# ============================================================================
# Helper Functions
# ============================================================================

get_gpu_ip() {
    aws ec2 describe-instances \
        --instance-ids "$GPU_INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text 2>/dev/null
}

ensure_gpu_running() {
    local state=$(aws ec2 describe-instances \
        --instance-ids "$GPU_INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text 2>/dev/null)

    if [[ "$state" != "running" ]]; then
        log_info "Starting GPU instance..."
        aws ec2 start-instances --instance-ids "$GPU_INSTANCE_ID" >/dev/null

        log_info "Waiting for GPU to be ready..."
        aws ec2 wait instance-running --instance-ids "$GPU_INSTANCE_ID"
        sleep 30  # Wait for SSH
    fi

    get_gpu_ip
}

# Get sessions needing a specific stage
get_sessions_needing_stage() {
    local stage="$1"
    local sessions=()

    # List all session folders
    local all_sessions=$(aws s3 ls "s3://$S3_BUCKET/users/" --recursive \
        | grep -E '/audio/sessions/[^/]+/chunk-001\.(webm|m4a)$' \
        | sed 's|.*/users/|users/|' \
        | sed 's|/chunk-001\..*||' \
        | sort -u)

    for session_path in $all_sessions; do
        local needs_processing=false

        case $stage in
            transcribe)
                # Check if layer-0 transcription exists
                local trans_check=$(aws s3 ls "s3://$S3_BUCKET/${session_path}/layers/layer-0-raw-transcription/" 2>/dev/null | head -1)
                [[ -z "$trans_check" ]] && needs_processing=true
                ;;
            diarize)
                # Check if layer-1 diarization exists (and transcription exists)
                local trans_check=$(aws s3 ls "s3://$S3_BUCKET/${session_path}/layers/layer-0-raw-transcription/" 2>/dev/null | head -1)
                local diar_check=$(aws s3 ls "s3://$S3_BUCKET/${session_path}/layers/layer-1-diarization/" 2>/dev/null | head -1)
                [[ -n "$trans_check" && -z "$diar_check" ]] && needs_processing=true
                ;;
            ai)
                # Check if layer-2 AI analysis exists (and diarization exists)
                local diar_check=$(aws s3 ls "s3://$S3_BUCKET/${session_path}/layers/layer-1-diarization/" 2>/dev/null | head -1)
                local ai_check=$(aws s3 ls "s3://$S3_BUCKET/${session_path}/layers/layer-2-ai-analysis/" 2>/dev/null | head -1)
                [[ -n "$diar_check" && -z "$ai_check" ]] && needs_processing=true
                ;;
            preprocess)
                # Check if preprocessed file exists
                local prep_check=$(aws s3 ls "s3://$S3_BUCKET/${session_path}/transcription-processed.json" 2>/dev/null | head -1)
                [[ -z "$prep_check" ]] && needs_processing=true
                ;;
        esac

        if $needs_processing; then
            sessions+=("$session_path")
        fi
    done

    printf '%s\n' "${sessions[@]}"
}

# ============================================================================
# Stage Functions
# ============================================================================

run_transcription() {
    local session="$1"
    log_info "[TRANSCRIBE] Processing: $session"

    if $DRY_RUN; then
        log_info "  (dry run - would transcribe)"
        return 0
    fi

    # Use existing batch transcribe script
    "$PROJECT_ROOT/scripts/515-run-batch-transcribe.sh" --session "$session"
}

run_diarization() {
    local session="$1"
    log_info "[DIARIZE] Processing: $session"

    if $DRY_RUN; then
        log_info "  (dry run - would diarize)"
        return 0
    fi

    local gpu_ip=$(ensure_gpu_running)

    # Run diarization on GPU
    ssh -i ~/.ssh/dbm-oct18-2025.pem -o StrictHostKeyChecking=no "ubuntu@$gpu_ip" \
        "cd ~/diarization && export COGNITO_S3_BUCKET='$S3_BUCKET' && python3 520-diarize-transcripts.py --session '$session'"
}

run_ai_analysis() {
    local session="$1"
    log_info "[AI] Processing: $session"

    if $DRY_RUN; then
        log_info "  (dry run - would analyze)"
        return 0
    fi

    # Use existing AI analysis script
    "$PROJECT_ROOT/scripts/525-generate-ai-analysis.sh" --session "$session"
}

run_preprocessing() {
    local session="$1"
    log_info "[PREPROCESS] Processing: $session"

    if $DRY_RUN; then
        log_info "  (dry run - would preprocess)"
        return 0
    fi

    # Use existing preprocessing script
    "$PROJECT_ROOT/scripts/518-postprocess-transcripts.sh" --session "$session"
}

# ============================================================================
# Pipeline Execution
# ============================================================================

process_session() {
    local session="$1"
    local start_time=$(date +%s)

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Processing session: $session"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Stage 1: Transcription
    if [[ "$STAGE" == "all" || "$STAGE" == "transcribe" ]]; then
        local trans_check=$(aws s3 ls "s3://$S3_BUCKET/${session}/layers/layer-0-raw-transcription/" 2>/dev/null | head -1)
        if [[ -z "$trans_check" ]]; then
            run_transcription "$session" || log_warn "Transcription failed for $session"
        else
            log_info "[TRANSCRIBE] Already complete, skipping"
        fi
    fi

    # Stage 2: Diarization
    if [[ ("$STAGE" == "all" || "$STAGE" == "diarize") && "$ENABLE_DIARIZATION" == "true" ]]; then
        local diar_check=$(aws s3 ls "s3://$S3_BUCKET/${session}/layers/layer-1-diarization/" 2>/dev/null | head -1)
        if [[ -z "$diar_check" ]]; then
            run_diarization "$session" || log_warn "Diarization failed for $session"
        else
            log_info "[DIARIZE] Already complete, skipping"
        fi
    fi

    # Stage 3: AI Analysis
    if [[ ("$STAGE" == "all" || "$STAGE" == "ai") && "$ENABLE_AI_ANALYSIS" == "true" ]]; then
        local ai_check=$(aws s3 ls "s3://$S3_BUCKET/${session}/layers/layer-2-ai-analysis/" 2>/dev/null | head -1)
        if [[ -z "$ai_check" ]]; then
            run_ai_analysis "$session" || log_warn "AI analysis failed for $session"
        else
            log_info "[AI] Already complete, skipping"
        fi
    fi

    # Stage 4: Preprocessing
    if [[ ("$STAGE" == "all" || "$STAGE" == "preprocess") && "$ENABLE_PREPROCESSING" == "true" ]]; then
        local prep_check=$(aws s3 ls "s3://$S3_BUCKET/${session}/transcription-processed.json" 2>/dev/null | head -1)
        if [[ -z "$prep_check" ]]; then
            run_preprocessing "$session" || log_warn "Preprocessing failed for $session"
        else
            log_info "[PREPROCESS] Already complete, skipping"
        fi
    fi

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    log_success "Session complete in ${duration}s"
}

# ============================================================================
# Main
# ============================================================================

if [[ -n "$SESSION_PATH" ]]; then
    # Process specific session
    process_session "$SESSION_PATH"
else
    # Find sessions needing processing
    log_info "Scanning for sessions needing processing..."

    case $STAGE in
        transcribe)
            sessions=$(get_sessions_needing_stage "transcribe")
            ;;
        diarize)
            sessions=$(get_sessions_needing_stage "diarize")
            ;;
        ai)
            sessions=$(get_sessions_needing_stage "ai")
            ;;
        preprocess)
            sessions=$(get_sessions_needing_stage "preprocess")
            ;;
        all)
            # Get all sessions that need any stage
            sessions=$(get_sessions_needing_stage "transcribe")
            sessions+=$'\n'$(get_sessions_needing_stage "diarize")
            sessions+=$'\n'$(get_sessions_needing_stage "ai")
            sessions+=$'\n'$(get_sessions_needing_stage "preprocess")
            sessions=$(echo "$sessions" | sort -u | grep -v '^$')
            ;;
    esac

    session_count=$(echo "$sessions" | grep -c . || echo 0)

    if [[ $session_count -eq 0 ]]; then
        log_success "No sessions need processing"
        exit 0
    fi

    log_info "Found $session_count sessions to process"
    echo ""

    for session in $sessions; do
        [[ -z "$session" ]] && continue
        process_session "$session"
    done
fi

echo ""
echo "============================================================"
log_success "PIPELINE COMPLETE"
echo "============================================================"
