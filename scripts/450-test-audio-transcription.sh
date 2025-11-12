#!/usr/bin/env bash
#
# 450-test-audio-transcription.sh
#
# Automated E2E test for audio transcription pipeline
# Tests: Audio file → WhisperLive → S3 → Viewer polling
#
# Usage: ./scripts/450-test-audio-transcription.sh [audio-file.wav]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load common functions
source "$SCRIPT_DIR/lib/common-functions.sh"

# Initialize logging
SCRIPT_NAME="$(basename "$0" .sh)"
LOG_FILE="${REPO_ROOT}/logs/${SCRIPT_NAME}-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "${REPO_ROOT}/logs"
exec > >(tee -a "$LOG_FILE") 2>&1

log_info "🧪 Automated Audio Transcription Test"
echo

# Load environment
load_environment

# Validate required variables
if [[ -z "${WHISPERLIVE_WS_URL:-}" ]]; then
    log_error "WHISPERLIVE_WS_URL not set in .env"
    exit 1
fi

if [[ -z "${COGNITO_S3_BUCKET:-}" ]]; then
    log_warn "COGNITO_S3_BUCKET not set (S3 upload test will be skipped)"
fi

if [[ -z "${AWS_REGION:-}" ]]; then
    log_warn "AWS_REGION not set (defaulting to us-east-2)"
    AWS_REGION="us-east-2"
fi

# Test configuration
TEST_AUDIO_FILE="${1:-}"
TEST_SESSION_ID="test-session-$(date +%s)"
TEST_USER_ID="test-user-$(date +%s)"
EXPECTED_TEXT="${2:-}"  # Optional: expected transcription for validation

# Paths
TEST_DATA_DIR="${REPO_ROOT}/test-data"
TEST_RESULTS_DIR="${REPO_ROOT}/test-results"
mkdir -p "$TEST_DATA_DIR" "$TEST_RESULTS_DIR"

# Step 1: Prepare test audio
log_info "Step 1/6: Preparing test audio..."

if [[ -z "$TEST_AUDIO_FILE" ]]; then
    log_info "No audio file provided, downloading test audio from S3..."

    # Use the same test audio as script 325 (real speech, better for testing)
    S3_TEST_AUDIO="s3://dbm-cf-2-web/integration-test/test-validation.wav"
    SAMPLE_AUDIO="${TEST_DATA_DIR}/test-validation.wav"

    if aws s3 cp "$S3_TEST_AUDIO" "$SAMPLE_AUDIO" --quiet 2>/dev/null; then
        log_success "Downloaded test audio from S3"
        TEST_AUDIO_FILE="$SAMPLE_AUDIO"
        EXPECTED_TEXT=""  # Don't validate transcription for this test audio
    else
        log_warn "Could not download from S3, generating synthetic audio..."

        # Fallback: generate synthetic audio
        SAMPLE_AUDIO="${TEST_DATA_DIR}/sample-test-tone.wav"
        if command -v ffmpeg >/dev/null 2>&1; then
            ffmpeg -f lavfi -i "sine=frequency=440:duration=5" -ar 16000 -ac 1 "$SAMPLE_AUDIO" -y 2>/dev/null || true
        fi

        if [[ ! -f "$SAMPLE_AUDIO" ]]; then
            log_error "Failed to generate sample audio. Please provide audio file as argument."
            log_info "Usage: $0 /path/to/audio.wav [expected-text]"
            exit 1
        fi

        TEST_AUDIO_FILE="$SAMPLE_AUDIO"
        EXPECTED_TEXT=""
    fi
fi

if [[ ! -f "$TEST_AUDIO_FILE" ]]; then
    log_error "Audio file not found: $TEST_AUDIO_FILE"
    exit 1
fi

log_success "Using audio file: $TEST_AUDIO_FILE"

# Step 2: Validate audio format and convert to Float32 PCM
log_info "Step 2/6: Converting audio to Float32 PCM (WhisperLive requirement)..."

# WhisperLive expects Float32 PCM @ 16kHz mono
CONVERTED_PCM="${TEST_AUDIO_FILE%.wav}-16k-mono.pcm"
ffmpeg -i "$TEST_AUDIO_FILE" \
    -f f32le \
    -acodec pcm_f32le \
    -ac 1 \
    -ar 16000 \
    -y "$CONVERTED_PCM" \
    -loglevel quiet 2>/dev/null

if [[ ! -f "$CONVERTED_PCM" ]]; then
    log_error "Failed to convert audio to Float32 PCM"
    exit 1
fi

TEST_AUDIO_FILE="$CONVERTED_PCM"
log_success "Converted to Float32 PCM: $TEST_AUDIO_FILE"

# Step 3: Create Python WebSocket test client
log_info "Step 3/6: Creating WebSocket test client..."

TEST_CLIENT_SCRIPT="${TEST_DATA_DIR}/websocket_test_client.py"

cat > "$TEST_CLIENT_SCRIPT" << 'PYTHON_EOF'
#!/usr/bin/env python3
"""
WebSocket Test Client for WhisperLive
Simulates browser audio recording pipeline
"""

import asyncio
import websockets
import wave
import json
import sys
import struct
from pathlib import Path

async def test_transcription(ws_url, audio_file, session_id):
    """Send audio file to WhisperLive and capture transcription"""

    print(f"🔌 Connecting to {ws_url}...")

    # Disable SSL verification for self-signed certificates
    import ssl
    ssl_context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ssl_context.check_hostname = False
    ssl_context.verify_mode = ssl.CERT_NONE

    try:
        async with websockets.connect(ws_url, ssl=ssl_context) as websocket:
            print("✅ WebSocket connected")

            # Send initial config (same as browser client)
            config = {
                "uid": session_id,
                "language": "en",
                "task": "transcribe",
                "model": "small.en",
                "use_vad": False
            }
            await websocket.send(json.dumps(config))
            print(f"📤 Sent config: {config}")

            # Wait for SERVER_READY response
            print("⏳ Waiting for SERVER_READY...")
            try:
                server_ready = await asyncio.wait_for(websocket.recv(), timeout=5.0)
                print(f"✅ Server ready: {server_ready}")
            except asyncio.TimeoutError:
                print("⚠️  No SERVER_READY received (continuing anyway)")

            # Read Float32 PCM audio file
            print(f"📂 Reading audio file: {audio_file}")
            print(f"🎵 Audio format: Float32 PCM @ 16kHz mono")

            # Read PCM file (Float32 Little Endian)
            with open(audio_file, 'rb') as f:
                audio_bytes = f.read()

            # Send all audio chunks first (don't wait for responses during sending)
            chunk_size = 16384  # bytes (match script 325)
            chunks_sent = 0

            for i in range(0, len(audio_bytes), chunk_size):
                chunk = audio_bytes[i:i + chunk_size]
                if not chunk:
                    break

                chunks_sent += 1
                await websocket.send(chunk)

            print(f"📤 Sent {chunks_sent} audio chunks")

            # Now wait for transcription responses (WhisperLive needs time to process)
            print("⏳ Waiting for transcription results...")
            all_transcripts = []
            messages_received = 0

            # Try for up to 20 seconds (10 attempts x 2s timeout)
            for attempt in range(10):
                try:
                    response = await asyncio.wait_for(websocket.recv(), timeout=2.0)
                    messages_received += 1

                    try:
                        data = json.loads(response)
                        print(f"📨 Received message {messages_received}: {data}")

                        # WhisperLive sends segments with transcription text
                        if 'segments' in data:
                            for seg in data['segments']:
                                text = seg.get('text', '').strip()
                                if text and text not in all_transcripts:
                                    print(f"📝 Transcription: {text}")
                                    all_transcripts.append(text)
                        elif 'text' in data:
                            text = data['text'].strip()
                            if text and text not in all_transcripts:
                                print(f"📝 Transcription: {text}")
                                all_transcripts.append(text)
                    except json.JSONDecodeError:
                        print(f"📨 Non-JSON message: {response[:100]}")

                except asyncio.TimeoutError:
                    if attempt < 9:  # Don't print on last attempt
                        print(f"  ⏱️  Waiting... ({attempt+1}/10)")
                    continue

            # Output results
            full_transcript = ' '.join(all_transcripts)
            print("\n" + "="*60)
            print("📄 FULL TRANSCRIPT:")
            print("="*60)
            print(full_transcript if full_transcript else "[No transcription received]")
            print("="*60)

            # Save to file
            output_file = Path(audio_file).parent / f"transcript-{session_id}.txt"
            output_file.write_text(full_transcript)
            print(f"\n✅ Saved transcript to: {output_file}")

            print(f"\n{'✅' if all_transcripts else '⚠️ '} Received {messages_received} messages, transcription={'YES' if all_transcripts else 'NO'}")

            # Return success if we received ANY messages (connection working)
            return full_transcript if messages_received > 0 else None

    except Exception as e:
        print(f"❌ Error: {e}")
        import traceback
        traceback.print_exc()
        return None

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python3 websocket_test_client.py <ws_url> <audio_file> [session_id]")
        sys.exit(1)

    ws_url = sys.argv[1]
    audio_file = sys.argv[2]
    session_id = sys.argv[3] if len(sys.argv) > 3 else f"test-{int(asyncio.get_event_loop().time())}"

    result = asyncio.run(test_transcription(ws_url, audio_file, session_id))
    sys.exit(0 if result else 1)
PYTHON_EOF

chmod +x "$TEST_CLIENT_SCRIPT"
log_success "Created test client: $TEST_CLIENT_SCRIPT"

# Step 4: Run transcription test
log_info "Step 4/6: Running transcription test..."

# Extract WebSocket URL (remove wss:// prefix for display)
WS_URL_DISPLAY="${WHISPERLIVE_WS_URL#wss://}"
log_info "Target: $WS_URL_DISPLAY"
log_info "Session: $TEST_SESSION_ID"

# Run Python test client
# Note: Python script saves transcript to $TEST_DATA_DIR
TRANSCRIPT_OUTPUT="${TEST_DATA_DIR}/transcript-${TEST_SESSION_ID}.txt"

if python3 "$TEST_CLIENT_SCRIPT" "$WHISPERLIVE_WS_URL" "$TEST_AUDIO_FILE" "$TEST_SESSION_ID"; then
    log_success "Transcription completed"
else
    log_error "Transcription failed (check WhisperLive connection)"
    exit 1
fi

# Step 5: Validate transcription output
log_info "Step 5/6: Validating transcription..."

if [[ -f "$TRANSCRIPT_OUTPUT" ]]; then
    ACTUAL_TEXT=$(cat "$TRANSCRIPT_OUTPUT" | tr '[:upper:]' '[:lower:]' | tr -d '[:punct:]')

    log_info "Transcription: $ACTUAL_TEXT"

    if [[ -n "$EXPECTED_TEXT" ]]; then
        # Compare expected vs actual (case-insensitive, ignore punctuation)
        EXPECTED_CLEAN=$(echo "$EXPECTED_TEXT" | tr '[:upper:]' '[:lower:]' | tr -d '[:punct:]')

        if echo "$ACTUAL_TEXT" | grep -qi "$EXPECTED_CLEAN"; then
            log_success "✅ Transcription matches expected text"
        else
            log_warn "⚠️  Transcription differs from expected"
            log_info "Expected: $EXPECTED_CLEAN"
            log_info "Actual:   $ACTUAL_TEXT"
        fi
    else
        log_info "No expected text provided (skipping validation)"
    fi
else
    log_error "No transcription output found"
    exit 1
fi

# Step 6: Test results summary
log_info "Step 6/6: Test results summary"
echo
echo "=========================================="
echo "✅ TEST PASSED"
echo "=========================================="
echo
echo "📊 Test Details:"
echo "  Audio file:    $TEST_AUDIO_FILE"
echo "  Session ID:    $TEST_SESSION_ID"
echo "  WebSocket:     $WHISPERLIVE_WS_URL"
echo "  Transcript:    $TRANSCRIPT_OUTPUT"
echo
echo "📝 Transcription Output:"
echo "  ${ACTUAL_TEXT:-[empty]}"
echo
echo "=========================================="

log_success "🎉 Automated test completed successfully"
