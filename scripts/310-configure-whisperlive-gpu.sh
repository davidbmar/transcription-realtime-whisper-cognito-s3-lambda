#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# 310: Configure WhisperLive on GPU Instance
# ============================================================================
# Installs and configures WhisperLive on the GPU EC2 instance.
# This script can be run FROM BUILD BOX (via SSH) or directly ON GPU.
#
# What this does:
# 1. Install WhisperLive from Collabora GitHub
# 2. Install faster-whisper and dependencies
# 3. Download Whisper models
# 4. Patch WhisperLive to enable word-level timestamps
# 5. Create WhisperLive systemd service
# 6. Start WhisperLive server on port 9090
# 7. Verify WhisperLive is responding
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
echo "310: Configure WhisperLive on GPU"
echo "============================================"
echo ""

# ============================================================================
# Determine Execution Mode
# ============================================================================
log_info "Determining execution mode..."

# Load .env if available
if [ -f "$PROJECT_ROOT/.env" ]; then
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
fi

# Check if we're on the GPU instance or build box
if [ -n "${GPU_INSTANCE_IP:-}" ] && [ "$(hostname -I | awk '{print $1}')" != "$GPU_INSTANCE_IP" ]; then
    REMOTE_MODE=true
    log_info "Running in REMOTE mode - will SSH to GPU instance"
    log_info "GPU IP: $GPU_INSTANCE_IP"

    if [ -z "${SSH_KEY:-}" ]; then
        if [ -n "${SSH_KEY_NAME:-}" ]; then
            SSH_KEY="$HOME/.ssh/${SSH_KEY_NAME}.pem"
        else
            log_error "SSH_KEY_NAME not set in .env"
            exit 1
        fi
    fi

    if [ ! -f "$SSH_KEY" ]; then
        log_error "SSH key not found: $SSH_KEY"
        log_error "Expected: $HOME/.ssh/${SSH_KEY_NAME}.pem"
        exit 1
    fi
else
    REMOTE_MODE=false
    log_info "Running in LOCAL mode - executing on GPU instance"
fi

echo ""

# ============================================================================
# Installation Script (to be executed ON GPU)
# ============================================================================
read -r -d '' INSTALL_SCRIPT << 'EOFSCRIPT' || true
#!/bin/bash
set -euo pipefail

echo "============================================"
echo "Installing WhisperLive on GPU Instance"
echo "============================================"
echo ""

# Step 1: Install system dependencies
echo "[1/7] Installing system dependencies..."

# Check if dependencies are already installed
if command -v python3.9 >/dev/null 2>&1 && dpkg -l | grep -q python3.9-venv && dpkg -l | grep -q ffmpeg; then
    echo "✅ System dependencies already installed (skipping apt-get)"
else
    echo "Installing missing dependencies..."

    # Remove broken NVIDIA repositories (common on older GPU instances)
    echo "Cleaning up any broken NVIDIA repositories..."
    sudo rm -f /etc/apt/sources.list.d/nvidia-*.list 2>/dev/null || true

    sudo apt-get update

    # Install Python 3.9 (WhisperLive requires numpy 1.26.4 which needs Python 3.9+)
    # Python 3.9 is the most stable version available in deadsnakes PPA for Ubuntu 20.04
    echo "Installing Python 3.9 from deadsnakes PPA..."
    sudo apt-get install -y software-properties-common
    sudo add-apt-repository -y ppa:deadsnakes/ppa
    sudo apt-get update
    sudo apt-get install -y \
        python3.9 \
        python3.9-venv \
        python3.9-dev \
        git \
        ffmpeg \
        portaudio19-dev

    echo "✅ System dependencies installed"
fi

echo "✅ Python 3.9 ready (required for WhisperLive)"
echo ""

# Step 2: Create WhisperLive directory
echo "[2/7] Creating WhisperLive directory..."
WHISPER_DIR="$HOME/whisperlive"
mkdir -p "$WHISPER_DIR"
cd "$WHISPER_DIR"

echo "✅ Directory created: $WHISPER_DIR"
echo ""

# Step 3: Clone WhisperLive repository
echo "[3/7] Cloning WhisperLive repository..."
if [ -d "WhisperLive" ]; then
    echo "WhisperLive already cloned, updating..."
    cd WhisperLive
    git pull
else
    git clone https://github.com/collabora/WhisperLive.git
    cd WhisperLive
fi

echo "✅ WhisperLive repository ready"
echo ""

# Step 4: Create Python virtual environment
echo "[4/7] Creating Python virtual environment with Python 3.9..."

# Check if venv exists and is functional
if [ -d "venv" ] && [ -f "venv/bin/python3" ]; then
    echo "Virtual environment exists, checking health..."
    if venv/bin/python3 -c "import sys; sys.exit(0)" 2>/dev/null; then
        echo "✅ Existing virtual environment is healthy (preserving)"
        source venv/bin/activate
        SKIP_PIP_INSTALL=true
    else
        echo "Virtual environment corrupted, recreating..."
        rm -rf venv
        python3.9 -m venv venv
        source venv/bin/activate
        SKIP_PIP_INSTALL=false
    fi
else
    echo "Creating new virtual environment..."
    python3.9 -m venv venv
    source venv/bin/activate
    SKIP_PIP_INSTALL=false
fi

echo "✅ Virtual environment ready with Python 3.9"
python --version
echo ""

# Step 5: Install WhisperLive and dependencies
echo "[5/7] Installing WhisperLive and dependencies..."

if [ "${SKIP_PIP_INSTALL:-false}" = "true" ]; then
    echo "✅ Dependencies already installed (skipping pip install)"
    # Quick verification
    if python -c "import whisper_live, faster_whisper" 2>/dev/null; then
        echo "✅ Package verification passed"
    else
        echo "⚠️  Verification failed, reinstalling..."
        SKIP_PIP_INSTALL=false
    fi
fi

if [ "${SKIP_PIP_INSTALL:-false}" = "false" ]; then
    pip install --upgrade pip setuptools wheel

    # Install WhisperLive and faster-whisper
    pip install -e .
    pip install faster-whisper

    # Install cuDNN for GPU inference (required for faster-whisper on CUDA)
    # This provides libcudnn_ops.so.* libraries needed by faster-whisper
    echo "Installing cuDNN for GPU inference..."
    pip install nvidia-cudnn-cu11

    echo "✅ WhisperLive and dependencies installed"
fi

echo ""

# Step 6: Download Whisper model
echo "[6/7] Downloading Whisper model (this may take a few minutes)..."

# Check if model is already cached
MODEL_CACHE="$HOME/.cache/huggingface/hub"
if [ -d "$MODEL_CACHE" ] && find "$MODEL_CACHE" -name "*faster-whisper-small.en*" -type d 2>/dev/null | grep -q .; then
    echo "✅ Whisper model already cached (skipping download)"
else
    echo "Downloading model..."
    python3 << 'PYEOF'
from faster_whisper import WhisperModel

# Download small.en model (fast for testing)
print("Downloading faster-whisper-small.en...")
model = WhisperModel("small.en", device="cuda", compute_type="float16")
print("✅ Model downloaded and cached")
PYEOF
    echo "✅ Whisper model downloaded"
fi

echo "✅ Whisper model ready"
echo ""

# Step 7: Patch WhisperLive to enable word timestamps
echo "[7/8] Patching WhisperLive to enable word timestamps..."

# Backup files
BACKEND_FILE="whisper_live/backend/faster_whisper_backend.py"
BASE_FILE="whisper_live/backend/base.py"

# Patch 1: Enable word_timestamps in transcribe() call
if [ -f "$BACKEND_FILE" ]; then
    cp "$BACKEND_FILE" "${BACKEND_FILE}.backup"
    echo "✅ Backed up $BACKEND_FILE"

    if grep -q "word_timestamps=True" "$BACKEND_FILE"; then
        echo "✅ word_timestamps=True already present"
    else
        echo "Adding word_timestamps=True to transcribe() call..."
        sed -i 's/vad_parameters=self.vad_parameters if self.use_vad else None)/vad_parameters=self.vad_parameters if self.use_vad else None,\n            word_timestamps=True)/' "$BACKEND_FILE"
    fi
fi

# Patch 2: Update base.py format_segment to accept words parameter
if [ -f "$BASE_FILE" ]; then
    cp "$BASE_FILE" "${BASE_FILE}.backup"
    echo "✅ Backed up $BASE_FILE"

    if grep -q "def format_segment(self, start, end, text, completed=False, words=None):" "$BASE_FILE"; then
        echo "✅ format_segment already patched to accept words"
    else
        echo "Patching format_segment to accept words parameter..."
        python3 << 'PYPATCH'
import re

with open("whisper_live/backend/base.py", "r") as f:
    content = f.read()

# Update method signature
content = re.sub(
    r'def format_segment\(self, start, end, text, completed=False\):',
    'def format_segment(self, start, end, text, completed=False, words=None):',
    content
)

# Update return statement
old_return = """        return {
            'start': "{:.3f}".format(start),
            'end': "{:.3f}".format(end),
            'text': text,
            'completed': completed
        }"""

new_return = """        segment = {
            'start': "{:.3f}".format(start),
            'end': "{:.3f}".format(end),
            'text': text,
            'completed': completed
        }
        if words:
            segment['words'] = words
        return segment"""

content = content.replace(old_return, new_return)

with open("whisper_live/backend/base.py", "w") as f:
    f.write(content)

print("✅ Patched format_segment")
PYPATCH
    fi
fi

# Patch 3: Add word extraction to faster_whisper_backend.py
if [ -f "$BACKEND_FILE" ]; then
    if grep -q "def extract_words_from_segment" "$BACKEND_FILE"; then
        echo "✅ extract_words_from_segment already present"
    else
        echo "Adding word extraction methods..."
        python3 << 'PYPATCH'
import logging

# Add helper method and override update_segments
with open("whisper_live/backend/faster_whisper_backend.py", "r") as f:
    content = f.read()

# Add extract_words helper before handle_transcription_output
helper = '''    def extract_words_from_segment(self, segment, segment_start_time):
        """
        Extract word-level timestamps from faster-whisper segment.

        IMPORTANT: Word timestamps from faster-whisper are segment-relative (start from 0.0),
        so we must add segment_start_time to convert them to absolute session timestamps.

        Args:
            segment: A faster-whisper segment object with potential word-level data.
            segment_start_time (float): The absolute start time of this segment in the session.

        Returns:
            list or None: List of word dictionaries with 'start', 'end', 'word', 'probability',
                         or None if no words are available. All timestamps are absolute.
        """
        if not hasattr(segment, 'words') or not segment.words:
            return None

        words_list = []
        for word in segment.words:
            words_list.append({
                'start': float(word.start) + segment_start_time,
                'end': float(word.end) + segment_start_time,
                'word': word.word,
                'probability': float(word.probability)
            })
        return words_list if words_list else None

'''

insertion_point = "    def handle_transcription_output(self, result, duration):"
if insertion_point in content:
    content = content.replace(insertion_point, helper + insertion_point)
else:
    print("⚠️  Could not find insertion point for extract_words_from_segment")

# Add update_segments override at the end
override = '''    def update_segments(self, segments, duration):
        """
        Override base class to extract and include word-level timestamps.

        This method processes segments from faster-whisper, extracts word-level
        timestamps, and passes them to format_segment() for inclusion in the
        final segment data sent to clients.

        Args:
            segments (list): List of segments returned by faster-whisper.
            duration (float): Duration of the current audio chunk.

        Returns:
            dict or None: The last processed segment (if any).
        """
        offset = None
        self.current_out = ''
        last_segment = None

        # Process complete segments only if there are more than one
        # and if the last segment's no_speech_prob is below the threshold.
        if len(segments) > 1 and self.get_segment_no_speech_prob(segments[-1]) <= self.no_speech_thresh:
            for s in segments[:-1]:
                text_ = s.text
                self.text.append(text_)
                with self.lock:
                    start = self.timestamp_offset + self.get_segment_start(s)
                    end = self.timestamp_offset + min(duration, self.get_segment_end(s))
                if start >= end:
                    continue
                if self.get_segment_no_speech_prob(s) > self.no_speech_thresh:
                    continue

                # Extract words from this segment (converting to absolute timestamps)
                words = self.extract_words_from_segment(s, start)
                completed_segment = self.format_segment(start, end, text_, completed=True, words=words)
                self.transcript.append(completed_segment)

                if self.translation_queue:
                    try:
                        import queue
                        self.translation_queue.put(completed_segment.copy(), timeout=0.1)
                    except queue.Full:
                        logging.warning("Translation queue is full, skipping segment")
                offset = min(duration, self.get_segment_end(s))

        # Process the last segment if its no_speech_prob is acceptable.
        if self.get_segment_no_speech_prob(segments[-1]) <= self.no_speech_thresh:
            self.current_out += segments[-1].text
            with self.lock:
                segment_start = self.timestamp_offset + self.get_segment_start(segments[-1])
                segment_end = self.timestamp_offset + min(duration, self.get_segment_end(segments[-1]))
                # Extract words with absolute timestamps
                words = self.extract_words_from_segment(segments[-1], segment_start)
                last_segment = self.format_segment(
                    segment_start,
                    segment_end,
                    self.current_out,
                    completed=False,
                    words=words
                )

        # Handle repeated output logic.
        if self.current_out.strip() == self.prev_out.strip() and self.current_out != '':
            self.same_output_count += 1

            # if we remove the audio because of same output on the nth reptition we might remove the
            # audio thats not yet transcribed so, capturing the time when it was repeated for the first time
            if self.end_time_for_same_output is None:
                self.end_time_for_same_output = self.get_segment_end(segments[-1])
            import time
            time.sleep(0.1)  # wait briefly for any new voice activity
        else:
            self.same_output_count = 0
            self.end_time_for_same_output = None

        # If the same incomplete segment is repeated too many times,
        # append it to the transcript and update the offset.
        if self.same_output_count > self.same_output_threshold:
            if not self.text or self.text[-1].strip().lower() != self.current_out.strip().lower():
                self.text.append(self.current_out)
                with self.lock:
                    # Extract words for the repeated segment with absolute timestamps
                    words = self.extract_words_from_segment(segments[-1], self.timestamp_offset)
                    completed_segment = self.format_segment(
                        self.timestamp_offset,
                        self.timestamp_offset + min(duration, self.end_time_for_same_output),
                        self.current_out,
                        completed=True,
                        words=words
                    )
                    self.transcript.append(completed_segment)

                    if self.translation_queue:
                        try:
                            import queue
                            self.translation_queue.put(completed_segment.copy(), timeout=0.1)
                        except queue.Full:
                            logging.warning("Translation queue is full, skipping segment")

            self.current_out = ''
            offset = min(duration, self.end_time_for_same_output)
            self.same_output_count = 0
            last_segment = None
            self.end_time_for_same_output = None
        else:
            self.prev_out = self.current_out

        if offset is not None:
            with self.lock:
                self.timestamp_offset += offset

        return last_segment

'''

content = content.rstrip() + "\n" + override

with open("whisper_live/backend/faster_whisper_backend.py", "w") as f:
    f.write(content)

print("✅ Added word extraction methods")
PYPATCH
    fi
fi

if grep -q "word_timestamps=True" "$BACKEND_FILE" && grep -q "extract_words_from_segment" "$BACKEND_FILE"; then
    echo "✅ All word timestamp patches applied successfully"
else
    echo "⚠️  Some patches may not have applied correctly"
fi

echo ""

# Step 8: Create systemd service
echo "[8/8] Creating systemd service..."

# Set library paths for cuDNN and cuBLAS (installed via pip)
CUDNN_LIB_PATH="$HOME/whisperlive/WhisperLive/venv/lib/python3.9/site-packages/nvidia/cudnn/lib"
CUBLAS_LIB_PATH="$HOME/whisperlive/WhisperLive/venv/lib/python3.9/site-packages/nvidia/cublas/lib"

sudo tee /etc/systemd/system/whisperlive.service > /dev/null << EOF
[Unit]
Description=WhisperLive WebSocket Server
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$HOME/whisperlive/WhisperLive
Environment="PATH=$HOME/whisperlive/WhisperLive/venv/bin"
Environment="LD_LIBRARY_PATH=$CUDNN_LIB_PATH:$CUBLAS_LIB_PATH"
ExecStart=$HOME/whisperlive/WhisperLive/venv/bin/python3 run_server.py \\
    --port 9090 \\
    --backend faster_whisper

Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable whisperlive
sudo systemctl restart whisperlive

echo "✅ WhisperLive service created and started"
echo ""

# Wait for service to be ready
echo "Waiting for WhisperLive to start..."
sleep 5

# Check service status
if sudo systemctl is-active --quiet whisperlive; then
    echo "✅ WhisperLive service is running"

    # Test if port 9090 is listening
    if netstat -tuln 2>/dev/null | grep -q ":9090 " || ss -tuln 2>/dev/null | grep -q ":9090 "; then
        echo "✅ WhisperLive listening on port 9090"
    else
        echo "⚠️  Port 9090 not listening yet, may need more time"
    fi
else
    echo "❌ WhisperLive service failed to start"
    sudo systemctl status whisperlive --no-pager
    exit 1
fi

echo ""
echo "============================================"
echo "✅ WhisperLive Installation Complete"
echo "============================================"
echo ""
echo "Service Management:"
echo "  - Status: sudo systemctl status whisperlive"
echo "  - Logs: sudo journalctl -u whisperlive -f"
echo "  - Restart: sudo systemctl restart whisperlive"
echo "  - Stop: sudo systemctl stop whisperlive"
echo ""
echo "WhisperLive is now listening on port 9090"
echo "Protocol: WebSocket (ws://)"
echo "Expects: Float32 PCM audio @ 16kHz mono"
echo ""
EOFSCRIPT

# ============================================================================
# Execute Installation
# ============================================================================
if [ "$REMOTE_MODE" = true ]; then
    log_info "Executing installation on GPU instance via SSH..."
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "bash -s" << EOF
$INSTALL_SCRIPT
EOF

    if [ $? -eq 0 ]; then
        log_success "✅ Remote installation completed successfully"
    else
        log_error "❌ Remote installation failed"
        exit 1
    fi
else
    log_info "Executing installation locally..."
    bash -c "$INSTALL_SCRIPT"
fi

echo ""
log_info "==================================================================="
log_success "✅ WHISPERLIVE GPU CONFIGURATION COMPLETE"
log_info "==================================================================="
echo ""
log_info "WhisperLive Details:"
log_info "  - Location: ~/whisperlive/WhisperLive"
log_info "  - Service: whisperlive.service"
log_info "  - Port: 9090 (WebSocket)"
log_info "  - Backend: faster_whisper"
log_info "  - Model: small.en (cached)"
echo ""
log_info "Management (on GPU instance):"
log_info "  - Check status: sudo systemctl status whisperlive"
log_info "  - View logs: sudo journalctl -u whisperlive -f"
log_info "  - Restart: sudo systemctl restart whisperlive"
echo ""
log_info "Next Steps:"
log_info "  1. Run 030-configure-gpu-security.sh to allow edge→GPU access (port 9090)"
log_info "  2. Run 325-test-whisperlive-connection.sh to test connectivity"
log_info "  3. Run 320-update-edge-clients.sh to deploy browser clients"
echo ""
log_warn "IMPORTANT: Ensure security groups allow edge IP to access GPU port 9090"
echo ""
