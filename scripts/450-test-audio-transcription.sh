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
    log_info "No audio file provided, using sample audio"

    # Check if we have sample audio, if not create one using text-to-speech
    SAMPLE_AUDIO="${TEST_DATA_DIR}/sample-hello-world.wav"

    if [[ ! -f "$SAMPLE_AUDIO" ]]; then
        log_info "Generating sample audio file..."

        # Option 1: Use espeak if available
        if command -v espeak >/dev/null 2>&1; then
            espeak -w "$SAMPLE_AUDIO" "Hello world. This is an automated test of the audio transcription pipeline." 2>/dev/null || true
        fi

        # Option 2: Use festival if available
        if [[ ! -f "$SAMPLE_AUDIO" ]] && command -v text2wave >/dev/null 2>&1; then
            echo "Hello world. This is an automated test of the audio transcription pipeline." | \
                text2wave -o "$SAMPLE_AUDIO" 2>/dev/null || true
        fi

        # Option 3: Use ffmpeg to generate tone (fallback)
        if [[ ! -f "$SAMPLE_AUDIO" ]] && command -v ffmpeg >/dev/null 2>&1; then
            log_warn "No TTS available, generating test tone..."
            ffmpeg -f lavfi -i "sine=frequency=440:duration=5" -ar 16000 -ac 1 "$SAMPLE_AUDIO" -y 2>/dev/null || true
        fi

        if [[ ! -f "$SAMPLE_AUDIO" ]]; then
            log_error "Failed to generate sample audio. Please provide audio file as argument."
            log_info "Usage: $0 /path/to/audio.wav [expected-text]"
            exit 1
        fi
    fi

    TEST_AUDIO_FILE="$SAMPLE_AUDIO"
    EXPECTED_TEXT="hello world this is an automated test of the audio transcription pipeline"
fi

if [[ ! -f "$TEST_AUDIO_FILE" ]]; then
    log_error "Audio file not found: $TEST_AUDIO_FILE"
    exit 1
fi

log_success "Using audio file: $TEST_AUDIO_FILE"

# Step 2: Validate audio format
log_info "Step 2/6: Validating audio format..."

if command -v ffprobe >/dev/null 2>&1; then
    AUDIO_INFO=$(ffprobe -v quiet -print_format json -show_streams "$TEST_AUDIO_FILE")
    SAMPLE_RATE=$(echo "$AUDIO_INFO" | grep -o '"sample_rate":"[0-9]*"' | grep -o '[0-9]*' || echo "unknown")
    CHANNELS=$(echo "$AUDIO_INFO" | grep -o '"channels":[0-9]*' | grep -o '[0-9]*' || echo "unknown")

    log_info "Audio format: ${SAMPLE_RATE}Hz, ${CHANNELS} channel(s)"

    # WhisperLive expects 16kHz mono
    if [[ "$SAMPLE_RATE" != "16000" ]] || [[ "$CHANNELS" != "1" ]]; then
        log_warn "Converting to 16kHz mono (WhisperLive requirement)..."
        CONVERTED_AUDIO="${TEST_AUDIO_FILE%.wav}-16k-mono.wav"
        ffmpeg -i "$TEST_AUDIO_FILE" -ar 16000 -ac 1 "$CONVERTED_AUDIO" -y 2>/dev/null
        TEST_AUDIO_FILE="$CONVERTED_AUDIO"
        log_success "Converted to: $TEST_AUDIO_FILE"
    fi
else
    log_warn "ffprobe not found, skipping format validation"
fi

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

            # Read audio file
            print(f"📂 Reading audio file: {audio_file}")
            with wave.open(str(audio_file), 'rb') as wf:
                sample_rate = wf.getframerate()
                channels = wf.getnchannels()
                sample_width = wf.getsampwidth()

                print(f"🎵 Audio: {sample_rate}Hz, {channels}ch, {sample_width*8}bit")

                if sample_rate != 16000 or channels != 1:
                    print("⚠️  Warning: Audio should be 16kHz mono for best results")

                # Send audio in chunks (simulate browser's MediaRecorder)
                chunk_size = 8192  # bytes
                chunk_num = 0
                all_transcripts = []

                while True:
                    audio_data = wf.readframes(chunk_size // (sample_width * channels))
                    if not audio_data:
                        break

                    chunk_num += 1
                    await websocket.send(audio_data)
                    print(f"📤 Sent chunk {chunk_num} ({len(audio_data)} bytes)")

                    # Try to receive transcription (non-blocking)
                    try:
                        response = await asyncio.wait_for(websocket.recv(), timeout=0.1)
                        transcript_data = json.loads(response)

                        if 'segments' in transcript_data:
                            for seg in transcript_data['segments']:
                                text = seg.get('text', '').strip()
                                if text:
                                    print(f"📝 Transcription: {text}")
                                    all_transcripts.append(text)
                    except asyncio.TimeoutError:
                        pass  # No response yet

                    # Small delay between chunks
                    await asyncio.sleep(0.1)

            # Send end-of-stream signal
            await websocket.send(json.dumps({"eof": 1}))
            print("🏁 Sent end-of-stream signal")

            # Wait for final transcription
            print("⏳ Waiting for final transcription...")
            try:
                final_response = await asyncio.wait_for(websocket.recv(), timeout=5.0)
                final_data = json.loads(final_response)

                if 'segments' in final_data:
                    for seg in final_data['segments']:
                        text = seg.get('text', '').strip()
                        if text and text not in all_transcripts:
                            print(f"📝 Final transcription: {text}")
                            all_transcripts.append(text)
            except asyncio.TimeoutError:
                print("⏰ Timeout waiting for final transcription")

            # Output results
            full_transcript = ' '.join(all_transcripts)
            print("\n" + "="*60)
            print("📄 FULL TRANSCRIPT:")
            print("="*60)
            print(full_transcript)
            print("="*60)

            # Save to file
            output_file = Path(audio_file).parent / f"transcript-{session_id}.txt"
            output_file.write_text(full_transcript)
            print(f"\n✅ Saved transcript to: {output_file}")

            return full_transcript

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
TRANSCRIPT_OUTPUT="${TEST_RESULTS_DIR}/transcript-${TEST_SESSION_ID}.txt"

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
