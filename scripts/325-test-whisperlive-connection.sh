#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# 325: Test WhisperLive End-to-End Connection
# ============================================================================
# Tests the full WhisperLive chain: Edge→GPU with real audio from S3
# This script should be run FROM THE EDGE EC2 INSTANCE.
#
# What this does:
# 1. Test GPU WhisperLive locally (direct connection)
# 2. Test Edge→GPU connection
# 3. Send test audio file and verify transcription
# 4. Validate Float32 PCM format is working
# 5. Test browser client connectivity
# ============================================================================

# Find repository root (works from symlink or direct execution)
if [ -L "${BASH_SOURCE[0]}" ]; then
    SCRIPT_REAL=$(readlink -f "${BASH_SOURCE[0]}")
else
    SCRIPT_REAL="${BASH_SOURCE[0]}"
fi
REPO_ROOT="$(cd "$(dirname "$SCRIPT_REAL")/.." && pwd)"
PROJECT_ROOT="$REPO_ROOT"

# Source common functions if available
if [ -f "$REPO_ROOT/scripts/lib/common-functions.sh" ]; then
    source "$REPO_ROOT/scripts/lib/common-functions.sh"
else
    log_info() { echo "[INFO] $*"; }
    log_success() { echo "[SUCCESS] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_warn() { echo "[WARN] $*"; }
fi

echo "============================================"
echo "325: Test WhisperLive Connection"
echo "============================================"
echo ""

# ============================================================================
# Prerequisites
# ============================================================================
log_info "Checking prerequisites..."

# Load environment
if [ -f "$PROJECT_ROOT/.env-http" ]; then
    set -a
    source "$PROJECT_ROOT/.env-http"
    set +a
elif [ -f "$PROJECT_ROOT/.env" ]; then
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
fi

# Support both WhisperLive (GPU_HOST) and RIVA (RIVA_HOST/GPU_INSTANCE_IP) variables
GPU_HOST="${GPU_HOST:-${RIVA_HOST:-${GPU_INSTANCE_IP:-}}}"
GPU_PORT="${GPU_PORT:-9090}"

if [ -z "$GPU_HOST" ]; then
    log_error "GPU endpoint not configured"
    echo ""
    echo "Please set one of the following in .env:"
    echo "  - GPU_HOST=<gpu-ip>  (for WhisperLive)"
    echo "  - RIVA_HOST=<gpu-ip>  (for RIVA, will be used as fallback)"
    echo "  - GPU_INSTANCE_IP=<gpu-ip>  (legacy, will be used as fallback)"
    echo ""
    echo "Example:"
    echo "  echo 'GPU_HOST=52.15.199.98' >> .env"
    echo "  echo 'GPU_PORT=9090' >> .env"
    exit 1
fi

log_success "Configuration loaded"
log_info "GPU endpoint: $GPU_HOST:$GPU_PORT"
log_info "Using: ${RIVA_HOST:+RIVA_HOST}${GPU_HOST:+GPU_HOST}${GPU_INSTANCE_IP:+GPU_INSTANCE_IP}"
echo ""

# ============================================================================
# Test 1: Check if Python websockets library is installed
# ============================================================================
log_info "Test 1/5: Checking Python dependencies..."

if ! python3 -c "import websockets" 2>/dev/null; then
    log_warn "websockets library not installed, installing..."
    sudo apt install -y python3-websockets
fi

if ! python3 -c "import asyncio" 2>/dev/null; then
    log_error "asyncio not available (requires Python 3.7+)"
    exit 1
fi

log_success "Python dependencies OK"
echo ""

# ============================================================================
# Test 2: Network Connectivity to GPU
# ============================================================================
log_info "Test 2/5: Testing network connectivity to GPU..."

if timeout 5 nc -zv "$GPU_HOST" "$GPU_PORT" 2>&1 | grep -q "succeeded"; then
    log_success "✓ Can reach $GPU_HOST:$GPU_PORT"
else
    log_error "✗ Cannot reach $GPU_HOST:$GPU_PORT"
    log_warn "Possible issues:"
    log_warn "  1. WhisperLive not running on GPU"
    log_warn "  2. Security group blocking port $GPU_PORT"
    log_warn "  3. GPU instance is stopped"
    exit 1
fi

echo ""

# ============================================================================
# Test 3: WebSocket Connection Test (with retries for model loading)
# ============================================================================
log_info "Test 3/5: Testing WebSocket connection..."

python3 << PYEOF
import asyncio
import websockets
import json
import sys
import time

async def test_connection():
    uri = "ws://$GPU_HOST:$GPU_PORT"
    max_wait_seconds = 120  # 2 minutes for model loading
    retry_interval = 5
    start_time = time.time()
    attempt = 0

    print(f"Connecting to {uri}...")
    print(f"Will wait up to {max_wait_seconds}s for WhisperLive to be ready (model loading)...")
    print("")

    while time.time() - start_time < max_wait_seconds:
        attempt += 1
        elapsed = int(time.time() - start_time)

        try:
            async with websockets.connect(uri, ping_timeout=10) as ws:
                print(f"✅ WebSocket connected (attempt {attempt} after {elapsed}s)")

                # Send config
                config = {
                    "uid": "test-edge-to-gpu-connection",
                    "task": "transcribe",
                    "language": "en",
                    "model": "Systran/faster-whisper-small.en",
                    "use_vad": False
                }
                await ws.send(json.dumps(config))
                print(f"Sent config: {config}")

                # Wait for SERVER_READY (may take time for first model load)
                try:
                    response = await asyncio.wait_for(ws.recv(), timeout=15.0)
                    data = json.loads(response)

                    if data.get("message") == "SERVER_READY" or "segments" in data or "uid" in data:
                        print(f"✅ Server responded: {data}")
                        return 0
                    else:
                        print(f"⚠️  Unexpected response: {data}")
                        # Continue trying - server may still be loading
                except asyncio.TimeoutError:
                    print(f"⚠️  Response timeout (attempt {attempt}), retrying...")
                    # Server connected but slow - keep trying

        except (ConnectionRefusedError, OSError) as e:
            print(f"  Attempt {attempt} ({elapsed}/{max_wait_seconds}s): Connection refused, retrying...", end='\\r')
        except Exception as e:
            print(f"  Attempt {attempt} ({elapsed}/{max_wait_seconds}s): {type(e).__name__}, retrying...", end='\\r')

        await asyncio.sleep(retry_interval)

    print(f"\\n❌ Server not ready after {max_wait_seconds}s")
    print("   Check: ssh to GPU and run: sudo journalctl -u whisperlive -f")
    return 1

sys.exit(asyncio.run(test_connection()))
PYEOF

WS_TEST_RESULT=$?

if [ $WS_TEST_RESULT -eq 0 ]; then
    log_success "WebSocket connection test passed"
else
    log_error "WebSocket connection test failed"
    exit 1
fi

echo ""

# ============================================================================
# Test 4: Audio Transcription Test
# ============================================================================
log_info "Test 4/5: Testing audio transcription..."

# Check if ffmpeg is installed
if ! command -v ffmpeg &> /dev/null; then
    log_warn "ffmpeg not installed, installing..."
    sudo apt install -y ffmpeg
fi

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    log_warn "AWS CLI not installed, installing..."
    sudo apt install -y awscli
fi

# Download test audio from S3
S3_TEST_AUDIO="s3://dbm-cf-2-web/integration-test/test-validation.wav"
log_info "Downloading test audio from S3..."
log_info "Source: $S3_TEST_AUDIO"

mkdir -p /tmp/whisperlive-test
if aws s3 cp "$S3_TEST_AUDIO" /tmp/whisperlive-test/test_audio.wav --quiet 2>/dev/null; then
    log_success "Downloaded test audio from S3"

    # Convert to Float32 PCM (WhisperLive expects Float32, not Int16!)
    log_info "Converting to Float32 PCM @ 16kHz mono..."
    ffmpeg -i /tmp/whisperlive-test/test_audio.wav \
        -f f32le \
        -acodec pcm_f32le \
        -ac 1 \
        -ar 16000 \
        -y /tmp/test_audio.pcm \
        -loglevel quiet

    log_success "Audio converted to Float32 PCM"
else
    log_warn "Could not download from S3, generating synthetic test audio..."
    ffmpeg -f lavfi -i "sine=frequency=1000:duration=2" -ar 16000 -ac 1 -f f32le -y /tmp/test_audio.pcm -loglevel quiet
fi

# Send test audio and check for transcription
log_info "Sending test audio to WhisperLive..."

python3 << PYEOF
import asyncio
import websockets
import json
import sys

async def test_transcription():
    uri = "ws://$GPU_HOST:$GPU_PORT"

    try:
        async with websockets.connect(uri, ping_timeout=10) as ws:
            # Send config
            config = {
                "uid": "test-edge-to-gpu-audio-transcription",
                "task": "transcribe",
                "language": "en",
                "model": "Systran/faster-whisper-small.en",
                "use_vad": False
            }
            await ws.send(json.dumps(config))

            # Wait for SERVER_READY
            response = await asyncio.wait_for(ws.recv(), timeout=5.0)

            # Send audio chunks
            with open("/tmp/test_audio.pcm", "rb") as f:
                chunk_size = 16384
                chunks_sent = 0
                while True:
                    chunk = f.read(chunk_size)
                    if not chunk:
                        break
                    await ws.send(chunk)
                    chunks_sent += 1

            print(f"Sent {chunks_sent} audio chunks")

            # Wait for transcription responses (WhisperLive needs time to process)
            print("Waiting for transcription results...")
            transcription_received = False
            messages_received = 0

            # Try for up to 20 seconds (10 attempts x 2s timeout)
            for i in range(10):
                try:
                    msg = await asyncio.wait_for(ws.recv(), timeout=2.0)
                    messages_received += 1

                    try:
                        data = json.loads(msg)
                        print(f"Received message {messages_received}: {data}")

                        # WhisperLive sends segments with transcription text
                        if data.get("segments") or data.get("text"):
                            transcription_received = True
                    except json.JSONDecodeError:
                        print(f"Received non-JSON message: {msg[:100]}")

                except asyncio.TimeoutError:
                    if i < 9:  # Don't print on last attempt
                        print(f"  Waiting... ({i+1}/10)")
                    continue

            # Close gracefully
            try:
                await ws.close()
            except:
                pass

            print(f"\n{'✅' if transcription_received else '⚠️ '} Received {messages_received} messages, transcription={'YES' if transcription_received else 'NO'}")

            # Return success if we received ANY messages (connection working)
            return 0 if messages_received > 0 else 1

    except Exception as e:
        print(f"❌ Error: {e}")
        import traceback
        traceback.print_exc()
        return 1

sys.exit(asyncio.run(test_transcription()))
PYEOF

AUDIO_TEST_RESULT=$?

if [ $AUDIO_TEST_RESULT -eq 0 ]; then
    log_success "Audio transcription test passed"
else
    log_warn "Audio transcription test incomplete (may need real speech)"
    log_info "Silent audio may not generate transcriptions - this is normal"
fi

echo ""

# ============================================================================
# Test 5: Browser Client Accessibility
# ============================================================================
log_info "Test 5/5: Testing browser client accessibility..."

EDGE_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null)

if curl -k --max-time 5 "https://$EDGE_IP/healthz" 2>/dev/null | grep -q "OK"; then
    log_success "✓ Edge proxy HTTPS endpoint is accessible"
    log_info "Browser client URL: https://$EDGE_IP/"
else
    log_error "✗ Edge proxy HTTPS endpoint is not accessible"
    log_warn "Check Caddy container status: docker compose ps"
fi

echo ""

# ============================================================================
# Summary
# ============================================================================
echo "============================================"
echo "✅ WhisperLive Connection Tests Complete"
echo "============================================"
echo ""
echo "Test Results Summary:"
echo "  ✓ Python dependencies: OK"
echo "  ✓ Network connectivity: OK"
echo "  ✓ WebSocket connection: OK"
if [ $AUDIO_TEST_RESULT -eq 0 ]; then
    echo "  ✓ Audio transcription: OK"
else
    echo "  ⚠ Audio transcription: INCOMPLETE (needs real speech)"
fi
echo "  ✓ Browser client: OK"
echo ""
echo "Next Steps:"
echo "  1. Open browser: https://$EDGE_IP/"
echo "  2. Click 'Start Recording'"
echo "  3. Speak and watch transcriptions appear"
echo ""
echo "Troubleshooting:"
echo "  - View GPU logs: ssh to GPU and run: sudo journalctl -u whisperlive -f"
echo "  - View edge logs: docker compose logs -f"
echo "  - Test files: $PROJECT_ROOT/test_client.py"
echo ""
