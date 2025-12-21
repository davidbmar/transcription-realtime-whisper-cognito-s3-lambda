#!/bin/bash
set -e
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# NVIDIA Riva ASR Deployment - Interactive Configuration Setup
# This script creates .env configuration with preview-then-edit interface

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

# Configuration array indices
declare -A CONFIG_KEYS=(
    [1]="AWS_REGION"
    [2]="AWS_ACCOUNT_ID"
    [3]="GPU_INSTANCE_TYPE"
    [4]="SSH_KEY_NAME"
    [5]="RIVA_MODEL"
    [6]="S3_CONFORMER_RMIR"
    [7]="S3_CONFORMER_SOURCE"
    [8]="S3_CONFORMER_TRITON_CACHE"
    [9]="RIVA_PORT"
    [10]="RIVA_HTTP_PORT"
    [11]="RIVA_LANGUAGE_CODE"
    [12]="NGC_API_KEY"
    [13]="APP_PORT"
    [14]="ENABLE_HTTPS"
    [15]="LOG_LEVEL"
    [16]="WS_MAX_CONNECTIONS"
    [17]="DEMO_PORT"
)

# Default values
declare -A CONFIG_VALUES=(
    [AWS_REGION]="us-east-2"
    [AWS_ACCOUNT_ID]="821850226835"
    [GPU_INSTANCE_TYPE]="g4dn.xlarge"
    [SSH_KEY_NAME]="dbm-oct5-2025"
    [RIVA_MODEL]="conformer-ctc-xl-en-us-streaming"
    [S3_CONFORMER_RMIR]="s3://dbm-cf-2-web/bintarball/riva-models/conformer/conformer-ctc-xl-streaming-40ms.rmir"
    [S3_CONFORMER_SOURCE]="s3://dbm-cf-2-web/bintarball/riva-models/conformer/Conformer-CTC-XL_spe-128_en-US_Riva-ASR-SET-4.0.riva"
    [S3_CONFORMER_TRITON_CACHE]="s3://dbm-cf-2-web/bintarball/riva-repository/conformer-ctc-xl/v1.0/"
    [RIVA_PORT]="50051"
    [RIVA_HTTP_PORT]="8000"
    [RIVA_LANGUAGE_CODE]="en-US"
    [NGC_API_KEY]=""
    [APP_PORT]="8443"
    [ENABLE_HTTPS]="yes"
    [LOG_LEVEL]="INFO"
    [WS_MAX_CONNECTIONS]="100"
    [DEMO_PORT]="8444"
)

# Short display labels for preview
declare -A CONFIG_LABELS=(
    [AWS_REGION]="AWS Region"
    [AWS_ACCOUNT_ID]="AWS Account ID"
    [GPU_INSTANCE_TYPE]="GPU Instance Type"
    [SSH_KEY_NAME]="SSH Key Name"
    [RIVA_MODEL]="Model Name"
    [S3_CONFORMER_RMIR]="S3 Pre-built RMIR"
    [S3_CONFORMER_SOURCE]="S3 Source Model"
    [S3_CONFORMER_TRITON_CACHE]="S3 Triton Cache"
    [RIVA_PORT]="gRPC Port"
    [RIVA_HTTP_PORT]="HTTP Port"
    [RIVA_LANGUAGE_CODE]="Language Code"
    [NGC_API_KEY]="NGC API Key"
    [APP_PORT]="WebSocket Port"
    [ENABLE_HTTPS]="Enable HTTPS"
    [LOG_LEVEL]="Log Level"
    [WS_MAX_CONNECTIONS]="Max Connections"
    [DEMO_PORT]="Demo Server Port"
)

# Flag to track if this is first run
FIRST_RUN=true

# ============================================================================
# Help Text Functions
# ============================================================================

show_help_1() {
    cat << 'EOF'

╔════════════════════════════════════════════════════════════════════════╗
║ HELP: AWS Region                                                      ║
╚════════════════════════════════════════════════════════════════════════╝

WHAT IT IS:
  The AWS region where your GPU instance will be deployed.

WHEN TO CHANGE:
  • If you need lower latency in a specific geographic region
  • If you have existing AWS resources in another region
  • If you want to take advantage of region-specific pricing

COMMON VALUES:
  • us-east-2 (Ohio) - Default, good for US deployments
  • us-east-1 (N. Virginia) - Popular, more services available
  • us-west-2 (Oregon) - West coast option
  • eu-west-1 (Ireland) - European deployments

COST IMPACT:
  Minimal - GPU pricing varies slightly by region (~5-10%)

Press Enter to continue...
EOF
    read
}

show_help_2() {
    cat << 'EOF'

╔════════════════════════════════════════════════════════════════════════╗
║ HELP: AWS Account ID                                                  ║
╚════════════════════════════════════════════════════════════════════════╝

WHAT IT IS:
  Your 12-digit AWS account identifier. This is used to:
  • Create IAM roles for the GPU instance
  • Configure S3 access permissions
  • Set up security groups

HOW TO FIND IT:
  1. Log into AWS Console at https://console.aws.amazon.com
  2. Click your username in top-right corner
  3. Your Account ID is displayed in the dropdown

  OR run: aws sts get-caller-identity --query Account --output text

WHEN TO CHANGE:
  • ALWAYS change this to YOUR account ID
  • The default (821850226835) is for examples only
  • Using wrong account ID will cause deployment to fail

SECURITY NOTE:
  Account ID is not secret, but keep your AWS credentials secure.

Press Enter to continue...
EOF
    read
}

show_help_3() {
    cat << 'EOF'

╔════════════════════════════════════════════════════════════════════════╗
║ HELP: GPU Instance Type                                               ║
╚════════════════════════════════════════════════════════════════════════╝

WHAT IT IS:
  The AWS EC2 instance type with GPU for running Riva ASR.

AVAILABLE OPTIONS:
  ┌──────────────┬───────────┬─────┬────────┬──────────┬─────────────┐
  │ Instance     │ GPU       │ GPU │ vCPUs  │ RAM      │ Cost/Hour   │
  ├──────────────┼───────────┼─────┼────────┼──────────┼─────────────┤
  │ g4dn.xlarge  │ T4        │ 16GB│   4    │  16GB    │ ~$0.526 ⭐  │
  │ g4dn.2xlarge │ T4        │ 16GB│   8    │  32GB    │ ~$0.752     │
  │ g5.xlarge    │ A10G      │ 24GB│   4    │  16GB    │ ~$1.006     │
  │ p3.2xlarge   │ V100      │ 16GB│   8    │  61GB    │ ~$3.060     │
  └──────────────┴───────────┴─────┴────────┴──────────┴─────────────┘

RECOMMENDATION:
  • g4dn.xlarge - Best value for most workloads ⭐
  • Handles 5-10 concurrent transcription streams
  • Good for development and production

WHEN TO UPGRADE:
  • g4dn.2xlarge - More concurrent streams (10-20)
  • g5.xlarge - Newer GPU, better performance
  • p3.2xlarge - Maximum performance, high cost

COST CALCULATOR:
  • g4dn.xlarge running 24/7: ~$380/month
  • With scripts/810-shutdown-gpu.sh: Shut down when not needed!

Press Enter to continue...
EOF
    read
}

show_help_4() {
    cat << 'EOF'

╔════════════════════════════════════════════════════════════════════════╗
║ HELP: SSH Key Name                                                    ║
╚════════════════════════════════════════════════════════════════════════╝

WHAT IT IS:
  The name of an AWS EC2 key pair for SSH access to your GPU instance.

WHY YOU NEED IT:
  • Debug issues on the GPU instance
  • Check NVIDIA driver installation
  • View Riva server logs directly
  • Manual troubleshooting

HOW TO FIND/CREATE:
  1. AWS Console → EC2 → Key Pairs (left sidebar)
  2. Use existing key name (WITHOUT .pem extension)
     Example: If file is "dbm-oct5-2025.pem", enter "dbm-oct5-2025"

  OR create new key:
  3. Click "Create key pair"
  4. Enter name: dbm-oct5-2025
  5. Select "pem" format
  6. Download and save to ~/.ssh/

IMPORTANT:
  • Use key name only, not the file path
  • Key must exist in the AWS region you selected (#1)
  • Keep the .pem file secure - you can't download it again

CONNECTING LATER:
  ssh -i ~/.ssh/dbm-oct5-2025.pem ubuntu@<GPU-IP>

Press Enter to continue...
EOF
    read
}

show_help_5() {
    cat << 'EOF'

╔════════════════════════════════════════════════════════════════════════╗
║ HELP: Model Name                                                      ║
╚════════════════════════════════════════════════════════════════════════╝

WHAT IT IS:
  The identifier Riva uses to serve this ASR model via gRPC API.

DEFAULT: conformer-ctc-xl-en-us-streaming

THIS IS THE MODEL NAME, NOT THE FILE:
  • This is what you pass to Riva's ASR API
  • The actual model files are in settings #6 and #7
  • Think of this as a "service name" for the model

WHEN TO CHANGE:
  • Usually DON'T change this
  • Only change if deploying a different model architecture
  • Must match the model you're deploying (#6 or #7)

RELATIONSHIP TO FILES:
  Model Name (#5):      conformer-ctc-xl-en-us-streaming
                           ↓
  Pre-built RMIR (#6):  conformer-ctc-xl-streaming-40ms.rmir
                           ↓
  Source Model (#7):    Conformer-CTC-XL_spe-128_en-US_Riva-ASR-SET-4.0.riva

  For more info on file relationships, type 'i' at the main menu.

TECHNICAL DETAIL:
  • conformer-ctc-xl = Architecture (Conformer with CTC decoder, XL size)
  • en-us = Language
  • streaming = Optimized for real-time streaming audio
  • 40ms = Timestep resolution (critical for latency)

Press Enter to continue...
EOF
    read
}

show_help_6() {
    cat << 'EOF'

╔════════════════════════════════════════════════════════════════════════╗
║ HELP: S3 Pre-built RMIR                                               ║
╚════════════════════════════════════════════════════════════════════════╝

WHAT IT IS:
  S3 path to a pre-built RMIR file (ready-to-deploy model binary).

FILE FORMAT: .rmir (Riva Model Intermediate Representation)
  • Pre-compiled, optimized, ready to use
  • Deployment script downloads and loads directly
  • FAST: Deployment takes 5-10 minutes

DEFAULT PATH:
  s3://dbm-cf-2-web/bintarball/riva-models/conformer/
    conformer-ctc-xl-streaming-40ms.rmir

WHEN TO USE THIS:
  ✅ Fast deployment (recommended)
  ✅ Production deployments
  ✅ When you trust the pre-built binary
  ✅ When you don't need custom model modifications

WHEN TO USE SOURCE (#7) INSTEAD:
  • Need to rebuild from source
  • Custom model modifications
  • Verification required
  • Building takes 30-45 minutes extra

CRITICAL PARAMETER: 40ms timestep
  The "40ms" in the filename is the model's timestep resolution:
  • Affects latency (lower = faster partial results)
  • Must match your audio processing pipeline
  • 40ms is optimal for real-time streaming

RELATIONSHIP TO OTHER SETTINGS:
  Model Name (#5)  → conformer-ctc-xl-en-us-streaming
  RMIR (#6)        → Fast deployment from this file
  Source (#7)      → Slow deployment, builds RMIR from this

Press Enter to continue...
EOF
    read
}

show_help_7() {
    cat << 'EOF'

╔════════════════════════════════════════════════════════════════════════╗
║ HELP: S3 Source Model                                                 ║
╚════════════════════════════════════════════════════════════════════════╝

WHAT IT IS:
  S3 path to source .riva model file (needs compilation before use).

FILE FORMAT: .riva (NVIDIA Riva Archive)
  • Source model that requires riva-build to compile
  • Converts to RMIR format during deployment
  • SLOW: Build process adds 30-45 minutes

DEFAULT PATH:
  s3://dbm-cf-2-web/bintarball/riva-models/conformer/
    Conformer-CTC-XL_spe-128_en-US_Riva-ASR-SET-4.0.riva

WHEN TO USE THIS:
  • Building from source required
  • Custom model modifications needed
  • Verification of build process important
  • You don't have a pre-built RMIR

WHEN TO USE PRE-BUILT (#6) INSTEAD:
  ✅ Fast deployment (5-10 min vs 35-55 min)
  ✅ Production deployments
  ✅ Most common use case

BUILD PROCESS:
  1. Download .riva file from S3
  2. Run riva-build tool (GPU required, 30-45 min)
  3. Generates .rmir file
  4. Load RMIR into Riva server

TECHNICAL DETAILS:
  • Conformer-CTC-XL = Model architecture
  • spe-128 = SentencePiece tokenizer with 128 vocab
  • Riva-ASR-SET-4.0 = Training dataset version
  • Timestep configured during build (40ms)

RELATIONSHIP TO OTHER SETTINGS:
  Model Name (#5)  → conformer-ctc-xl-en-us-streaming
  RMIR (#6)        → Pre-built (FAST) ⭐
  Source (#7)      → This file, needs build (SLOW)

  Type 'i' at main menu for visual diagram.

Press Enter to continue...
EOF
    read
}

show_help_8() {
    cat << 'EOF'

╔════════════════════════════════════════════════════════════════════════╗
║ HELP: S3 Triton Cache                                                 ║
╚════════════════════════════════════════════════════════════════════════╝

WHAT IT IS:
  S3 location where pre-built Triton models are cached for fast deployment.

FORMAT: S3 directory path ending with /
  s3://dbm-cf-2-web/conformer-ctc-xl/v1.0/riva_repository/

CACHE PURPOSE:
  • Scripts 100-102: UPLOAD Triton models here (one-time, 30-50 min)
  • Script 125: DOWNLOAD from here (fast, 2-3 min)
  • Reusable across multiple GPU instances

WHAT GETS CACHED:
  • Pre-built Triton model files (output of riva-deploy)
  • Model directories (encoder, decoder, streaming components)
  • Configuration files (config.pbtxt, etc.)
  • Total size: ~2-4 GB

TWO DEPLOYMENT MODES:
  Mode 1: Fast (use cache)
    → Script 125 downloads from this location
    → 2-3 min deployment
    → Requires scripts 100-102 run once first

  Mode 2: Fresh build
    → Uses S3_CONFORMER_RMIR (#6) or S3_CONFORMER_SOURCE (#7)
    → Runs riva-build + riva-deploy each time
    → 30-50 min deployment

WHEN TO CHANGE:
  • Different model version
  • Different S3 bucket/region
  • Custom cache organization

RELATIONSHIP TO OTHER SETTINGS:
  RMIR (#6)         → Input for building Triton models
  Source (#7)       → Alternative input (slower)
  Triton Cache (#8) → Output/storage for fast redeployment ⭐

Press Enter to continue...
EOF
    read
}

show_help_9() {
    cat << 'EOF'

╔════════════════════════════════════════════════════════════════════════╗
║ HELP: gRPC Port                                                       ║
╚════════════════════════════════════════════════════════════════════════╝

WHAT IT IS:
  TCP port where Riva server listens for gRPC streaming requests.

DEFAULT: 50051 (Riva's standard gRPC port)

WHAT IT'S USED FOR:
  • Streaming audio data to Riva for transcription
  • Bidirectional communication (send audio, receive text)
  • Low-latency real-time protocol

WHEN TO CHANGE:
  • Port conflict with other services
  • Corporate firewall requires specific port
  • Multiple Riva instances on same machine

SECURITY GROUPS:
  The deployment script automatically:
  • Opens this port in AWS security group
  • Restricts access to build box IP only
  • Uses TCP protocol (gRPC uses HTTP/2)

TESTING CONNECTIVITY:
  After deployment, test with:
  nc -zv <GPU-IP> 50051

  Or use grpcurl:
  grpcurl -plaintext <GPU-IP>:50051 list

TECHNICAL NOTE:
  gRPC is HTTP/2-based, supports:
  • Streaming (bidirectional)
  • Multiplexing (multiple streams per connection)
  • Binary protocol (efficient)

Press Enter to continue...
EOF
    read
}

show_help_10() {
    cat << 'EOF'

╔════════════════════════════════════════════════════════════════════════╗
║ HELP: HTTP Port                                                       ║
╚════════════════════════════════════════════════════════════════════════╝

WHAT IT IS:
  TCP port where Riva server exposes HTTP API and health checks.

DEFAULT: 8000 (Riva's standard HTTP port)

WHAT IT'S USED FOR:
  • Health check endpoint: http://<GPU-IP>:8000/health
  • Riva server status and metrics
  • REST API (alternative to gRPC)
  • Prometheus metrics: http://<GPU-IP>:8000/metrics

HEALTH CHECK EXAMPLES:
  curl http://<GPU-IP>:8000/health
  # Response: {"status": "healthy", "version": "2.19.0"}

  curl http://<GPU-IP>:8000/metrics
  # Prometheus format metrics

WHEN TO CHANGE:
  • Port conflict with other services
  • Corporate policy requires specific port
  • Multiple Riva instances

MONITORING:
  The deployment scripts use this port to:
  • Verify Riva started successfully
  • Monitor server health
  • Scrape metrics for observability

RELATIONSHIP TO gRPC PORT (#8):
  • gRPC Port (50051) - Main API, streaming audio
  • HTTP Port (8000)  - Health checks, metrics, REST

Press Enter to continue...
EOF
    read
}

show_help_11() {
    cat << 'EOF'

╔════════════════════════════════════════════════════════════════════════╗
║ HELP: Language Code                                                   ║
╚════════════════════════════════════════════════════════════════════════╝

WHAT IT IS:
  BCP-47 language code for ASR transcription.

DEFAULT: en-US (English - United States)

SUPPORTED VALUES (depends on model):
  • en-US - English (US) ⭐
  • en-GB - English (UK)
  • es-US - Spanish (US)
  • es-ES - Spanish (Spain)
  • de-DE - German
  • fr-FR - French
  • it-IT - Italian
  • pt-BR - Portuguese (Brazil)

IMPORTANT:
  ⚠️  The language code MUST match the model you selected (#5)

  Example:
    Model: conformer-ctc-xl-en-us-streaming
    Language: en-US ✅ (matches)
    Language: es-US ❌ (mismatch - will fail)

WHEN TO CHANGE:
  • Deploying a different language model
  • Multi-language deployment (deploy multiple models)
  • Regional dialect preference

HOW IT'S USED:
  When clients connect to Riva, they specify:
  • Language code
  • Model name
  • Riva validates the combination

MULTI-LANGUAGE DEPLOYMENTS:
  To support multiple languages:
  1. Deploy multiple .rmir files (one per language)
  2. Each with its own model name
  3. Clients select model at connection time

Press Enter to continue...
EOF
    read
}

show_help_12() {
    cat << 'EOF'

╔════════════════════════════════════════════════════════════════════════╗
║ HELP: NGC API Key                                                     ║
╚════════════════════════════════════════════════════════════════════════╝

WHAT IT IS:
  NVIDIA NGC (NVIDIA GPU Cloud) API key for accessing:
  • Riva containers (Docker images)
  • Pre-trained models
  • NVIDIA tools and SDKs

OPTIONAL: You can leave this empty if:
  ✅ Using pre-downloaded containers (from S3)
  ✅ Using pre-built RMIR files (#6)
  ✅ Not pulling from NGC directly

REQUIRED IF:
  • Pulling latest Riva containers from nvcr.io
  • Downloading models from NGC catalog
  • Using riva-build tools that require NGC auth

HOW TO GET YOUR API KEY:
  1. Go to https://catalog.ngc.nvidia.com/
  2. Sign in (free NVIDIA account required)
  3. Click your profile icon (top right)
  4. Select "Setup" → "Generate API Key"
  5. Copy the key (starts with "nvapi-")
  6. Keep it secure - treat like a password

KEY FORMAT:
  nvapi-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

WHERE IT'S STORED:
  • Saved in .env file (permissions 600)
  • Used in docker login commands
  • Passed to riva-build tools

SECURITY:
  ⚠️  Keep your NGC API key secret
  • Don't commit to git (.env is in .gitignore)
  • Don't share in logs or screenshots
  • Regenerate if compromised

Press Enter to continue...
EOF
    read
}

show_help_13() {
    cat << 'EOF'

╔════════════════════════════════════════════════════════════════════════╗
║ HELP: WebSocket Port                                                  ║
╚════════════════════════════════════════════════════════════════════════╝

WHAT IT IS:
  TCP port where the WebSocket bridge server listens for browser connections.

DEFAULT: 8443 (Standard HTTPS alternative port)

WHAT IT DOES:
  The WebSocket bridge runs on the BUILD BOX and:
  • Accepts WebSocket connections from browsers
  • Converts audio from browsers to gRPC format
  • Forwards to Riva server on GPU instance
  • Returns transcriptions to browser

ARCHITECTURE:
  Browser → WSS (port 8443) → WebSocket Bridge (build box)
                               → gRPC (port 50051) → Riva (GPU)

WHY 8443?
  • Standard port for HTTPS alternatives
  • Usually allowed through firewalls
  • Clearly indicates secure WebSocket (WSS)
  • Avoids conflict with web servers on 443

WHEN TO CHANGE:
  • Port 8443 already in use
  • Corporate firewall requires specific port
  • Running multiple WebSocket bridges

HTTPS/WSS (#13):
  If HTTPS enabled (recommended):
  • Browsers connect via wss://build-box-ip:8443/
  • SSL certificates auto-generated during setup

  If HTTPS disabled:
  • Browsers connect via ws://build-box-ip:8443/
  • Less secure, not recommended

FIREWALL:
  Ensure port 8443 is open:
  • AWS security group (auto-configured)
  • Corporate firewall (manual)
  • Local firewall: sudo ufw allow 8443/tcp

Press Enter to continue...
EOF
    read
}

show_help_14() {
    cat << 'EOF'

╔════════════════════════════════════════════════════════════════════════╗
║ HELP: Enable HTTPS                                                    ║
╚════════════════════════════════════════════════════════════════════════╝

WHAT IT IS:
  Whether to enable TLS/SSL encryption for the WebSocket bridge.

DEFAULT: yes (Recommended for all deployments)

WHEN ENABLED (yes):
  ✅ Encrypted communication (wss://)
  ✅ Required for HTTPS websites to connect
  ✅ Prevents audio interception
  ✅ Auto-generated self-signed certificates

  Browsers connect via:
    wss://build-box-ip:8443/

WHEN DISABLED (no):
  ❌ Unencrypted communication (ws://)
  ❌ Modern browsers block from HTTPS sites
  ❌ Audio data sent in clear text
  ⚠️  Only use for local testing

  Browsers connect via:
    ws://localhost:8443/

WHY ENABLE:
  Modern browsers require secure contexts:
  • Microphone access requires HTTPS/WSS
  • Mixed content (HTTPS→WS) is blocked
  • Security best practice

CERTIFICATES:
  The setup script automatically:
  • Generates self-signed certificate
  • Stores in /opt/whisperlive/certs/
  • Configures WebSocket bridge to use it

BROWSER WARNING:
  Self-signed certificates trigger browser warnings:
  • Click "Advanced" → "Proceed to site"
  • Or install certificate in browser trust store
  • Or use Let's Encrypt for production

PRODUCTION DEPLOYMENTS:
  For production, consider:
  • Let's Encrypt certificate (free)
  • Corporate CA-signed certificate
  • AWS Certificate Manager (for ALB)

Press Enter to continue...
EOF
    read
}

show_help_15() {
    cat << 'EOF'

╔════════════════════════════════════════════════════════════════════════╗
║ HELP: Log Level                                                       ║
╚════════════════════════════════════════════════════════════════════════╝

WHAT IT IS:
  Controls verbosity of logging for debugging and monitoring.

AVAILABLE LEVELS (from most to least verbose):
  ┌───────────┬──────────────────────────────────────────────────────┐
  │ Level     │ What Gets Logged                                     │
  ├───────────┼──────────────────────────────────────────────────────┤
  │ DEBUG     │ Everything - function calls, variables, flow        │
  │ INFO      │ Important events, successful operations ⭐          │
  │ WARNING   │ Warnings and errors only                            │
  │ ERROR     │ Errors only                                          │
  │ CRITICAL  │ Critical failures only                               │
  └───────────┴──────────────────────────────────────────────────────┘

DEFAULT: INFO (Recommended for most users)

WHEN TO USE DEBUG:
  • Troubleshooting deployment issues
  • Investigating transcription errors
  • Understanding system behavior
  • Development and testing

  WARNING: DEBUG logs are VERY verbose
  • Large log files (GB per day possible)
  • May impact performance slightly
  • Contains sensitive data (audio metadata)

WHEN TO USE INFO:
  ✅ Production deployments
  ✅ Normal operations
  ✅ Balanced visibility/performance

  Logs include:
  • Connection events
  • Transcription sessions
  • Errors and warnings
  • Performance metrics

WHEN TO USE WARNING/ERROR:
  • Mature production systems
  • Log aggregation systems in place
  • Minimal log volume required

WHERE LOGS GO:
  • Build box: /opt/whisperlive/logs/
  • GPU instance: /opt/whisperlive/logs/
  • Systemd: journalctl -u riva-websocket-bridge

VIEW LOGS:
  tail -f /opt/whisperlive/logs/websocket-bridge.log
  sudo journalctl -u riva-websocket-bridge -f

Press Enter to continue...
EOF
    read
}

show_help_16() {
    cat << 'EOF'

╔════════════════════════════════════════════════════════════════════════╗
║ HELP: Max WebSocket Connections                                       ║
╚════════════════════════════════════════════════════════════════════════╝

WHAT IT IS:
  Maximum number of concurrent browser connections to WebSocket bridge.

DEFAULT: 100

WHAT IT MEANS:
  • 100 browsers can connect simultaneously
  • Each connection = 1 active transcription session
  • Connections are WebSocket (persistent)

RESOURCE IMPLICATIONS:
  Each connection uses:
  • ~2-5 MB RAM on build box
  • ~50-100 MB GPU RAM on GPU instance
  • Network bandwidth (audio up, text down)

SIZING GUIDE:
  ┌─────────────┬──────────────┬───────────────┬─────────────────┐
  │ Connections │ Build Box    │ GPU Instance  │ Use Case        │
  ├─────────────┼──────────────┼───────────────┼─────────────────┤
  │ 1-10        │ Any          │ g4dn.xlarge   │ Dev/Testing     │
  │ 10-50       │ t3.medium+   │ g4dn.xlarge   │ Small prod      │
  │ 50-100      │ t3.large+    │ g4dn.2xlarge  │ Medium prod ⭐  │
  │ 100-200     │ t3.xlarge+   │ g5.xlarge+    │ Large prod      │
  └─────────────┴──────────────┴───────────────┴─────────────────┘

WHEN TO INCREASE:
  • Expecting more concurrent users
  • Load testing
  • High-traffic production deployment

WHEN TO DECREASE:
  • Development environment
  • Resource-constrained build box
  • Cost optimization

WHAT HAPPENS WHEN LIMIT REACHED:
  • New connections rejected with error
  • Existing connections continue normally
  • Client receives "server at capacity" message
  • No impact on Riva server

MONITORING:
  Track active connections:
  • Prometheus metrics endpoint
  • WebSocket bridge logs
  • AWS CloudWatch

LOAD BALANCING:
  For >100 connections, consider:
  • Multiple WebSocket bridge instances
  • AWS Application Load Balancer
  • Horizontal scaling

Press Enter to continue...
EOF
    read
}

show_help_17() {
    cat << 'EOF'

╔════════════════════════════════════════════════════════════════════════╗
║ HELP: Demo Server Port                                                ║
╚════════════════════════════════════════════════════════════════════════╝

WHAT IT IS:
  TCP port where the HTTPS demo web server listens for browser connections.

DEFAULT: 8444 (Alternate HTTPS port)

WHAT IT DOES:
  The demo server runs on the BUILD BOX and:
  • Serves the demo HTML/JS UI (demo.html)
  • Provides test interface for speech transcription
  • Runs alongside WebSocket bridge
  • Uses same SSL certificates as WebSocket bridge

ARCHITECTURE:
  Browser → HTTPS (port 8444) → Demo Server (build box)
         ↓
         WSS (port 8443) → WebSocket Bridge → gRPC → Riva (GPU)

WHY 8444?
  • Standard alternate HTTPS port
  • Separates demo UI from WebSocket API
  • Usually allowed through firewalls
  • Avoids conflict with WebSocket port (8443)

WHEN TO CHANGE:
  • Port 8444 already in use
  • Corporate firewall requires specific port
  • Running multiple demo servers

RELATIONSHIP TO APP_PORT (#13):
  • APP_PORT (8443) - WebSocket bridge API endpoint
  • DEMO_PORT (8444) - Demo UI web server
  • Both can run on same build box
  • Demo page connects to WebSocket via APP_PORT

FIREWALL:
  Ensure port 8444 is open:
  • AWS security group (auto-configured)
  • Corporate firewall (manual)
  • Local firewall: sudo ufw allow 8444/tcp

ACCESS:
  After deployment, access demo at:
  https://<BUILD-BOX-IP>:8444/demo.html

PRODUCTION:
  For production deployments:
  • Integrate with your own UI
  • Use reverse proxy (nginx/ALB) on standard ports
  • Demo server is optional, WebSocket bridge is required

Press Enter to continue...
EOF
    read
}

show_model_info() {
    cat << 'EOF'

╔════════════════════════════════════════════════════════════════════════╗
║ INFO: Understanding Model Files and Relationships                     ║
╚════════════════════════════════════════════════════════════════════════╝

There are FOUR related settings for the Conformer model:

┌────────────────────────────────────────────────────────────────────────┐
│ #5: MODEL NAME (API identifier)                                       │
│     conformer-ctc-xl-en-us-streaming                                   │
│                                                                        │
│     • What clients use to request this model                          │
│     • Passed in gRPC API calls                                        │
│     • Like a "service name" for the model                             │
└────────────────────────────────────────────────────────────────────────┘
                                   ↓
┌────────────────────────────────────────────────────────────────────────┐
│ #6: S3 PRE-BUILT RMIR (Fast deployment - RECOMMENDED) ⭐              │
│     s3://.../conformer-ctc-xl-streaming-40ms.rmir                      │
│                                                                        │
│     • Ready-to-use binary model file                                  │
│     • Pre-compiled and optimized                                      │
│     • Deployment time: 5-10 minutes                                   │
│     • File size: ~2 GB                                                │
│     • Use this unless you need to build from source                   │
└────────────────────────────────────────────────────────────────────────┘

                                   OR

┌────────────────────────────────────────────────────────────────────────┐
│ #7: S3 SOURCE MODEL (Slow deployment - build from source)             │
│     s3://.../Conformer-CTC-XL_spe-128_en-US_Riva-ASR-SET-4.0.riva     │
│                                                                        │
│     • Source model that requires compilation                          │
│     • Uses riva-build tool to create RMIR                             │
│     • Build time: 30-45 minutes (GPU required)                        │
│     • Total deployment time: 35-55 minutes                            │
│     • File size: ~1.5 GB (source) → ~2 GB (RMIR)                      │
│     • Use when you need to verify build or modify model               │
└────────────────────────────────────────────────────────────────────────┘
                                   ↓
┌────────────────────────────────────────────────────────────────────────┐
│ #8: S3 TRITON CACHE (FASTEST redeployment - 2-3 min!) ⚡              │
│     s3://.../conformer-ctc-xl/v1.0/riva_repository/                    │
│                                                                        │
│     • Pre-built Triton models ready for instant loading               │
│     • Cached output from riva-build + riva-deploy                     │
│     • Deployment time: 2-3 minutes (vs 30-50 min rebuilding!)         │
│     • Used by script 125-deploy-conformer-from-s3-cache.sh            │
│     • Enables 60-70% faster redeployments                             │
│     • Populated by running scripts 100→101→102 (one-time)             │
└────────────────────────────────────────────────────────────────────────┘

DEPLOYMENT FLOW:

  Fast Path (Using #6 - RMIR):
  ┌──────────┐      ┌──────────┐      ┌──────────┐      ┌──────────┐
  │ Download │  →   │  Verify  │  →   │   Load   │  →   │  Ready!  │
  │   RMIR   │      │Checksum  │      │   into   │      │ 5-10 min │
  │          │      │          │      │   Riva   │      │          │
  └──────────┘      └──────────┘      └──────────┘      └──────────┘

  Slow Path (Using #7 - Source .riva):
  ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐
  │ Download │ → │ Run      │ → │ Generate │ → │   Load   │ → │  Ready!  │
  │  .riva   │   │riva-build│   │   RMIR   │   │   into   │   │ 35-55min │
  │          │   │(30-45min)│   │          │   │   Riva   │   │          │
  └──────────┘   └──────────┘   └──────────┘   └──────────┘   └──────────┘

CRITICAL PARAMETER: 40ms Timestep
  • The "40ms" in the RMIR filename is the model's timestep resolution
  • Controls how often the model produces output
  • Lower = faster partial results, higher GPU load
  • 40ms is optimal for real-time streaming
  • Must be configured during riva-build (if using #7)

WHICH SHOULD YOU USE?

  Use Pre-built RMIR (#6) if:
  ✅ You want fast deployment
  ✅ You trust the pre-built binary
  ✅ Production deployments
  ✅ Most common use case

  Use Source Model (#7) if:
  • You need to build from source for verification
  • Custom model modifications required
  • Learning the build process
  • Compliance requires building from source

RECOMMENDATION:
  Start with RMIR (#6) for fast deployment. You can always rebuild from
  source (#7) later if needed.

Press Enter to continue...
EOF
    read
}

# ============================================================================
# Display Functions
# ============================================================================

show_welcome() {
    clear
    cat << 'EOF'
╔════════════════════════════════════════════════════════════════════════╗
║                                                                        ║
║        NVIDIA Riva Conformer-CTC Streaming ASR                        ║
║        Interactive Configuration Tool                                 ║
║                                                                        ║
╚════════════════════════════════════════════════════════════════════════╝

Welcome! This tool helps you configure your Riva ASR deployment.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
HOW IT WORKS:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  1. You'll see all 16 configuration settings with smart defaults
  2. Review the values
  3. Edit only what you need to change
  4. Save and you're ready to deploy!

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
AVAILABLE COMMANDS:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  NUMBER      Edit that setting
              Example: Type "3" to edit GPU Instance Type

  ?NUMBER     Show detailed help for a setting
              Example: Type "?7" for help on S3 Source Model

  i           Show info about model file relationships
              Explains how settings #5, #6, #7 work together

  a           Accept all defaults and create .env file

  q           Quit without saving

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
MOST USERS ONLY NEED TO CHANGE:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  #2  AWS Account ID      → Use YOUR 12-digit account ID
  #4  SSH Key Name        → Use YOUR existing EC2 key pair name
  #12 NGC API Key         → Optional, for pulling NVIDIA containers

  All other defaults are production-ready! ✅

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Press Enter to continue...
EOF
    read
}

get_display_value() {
    local key=$1
    local value="${CONFIG_VALUES[$key]}"

    # Special formatting for specific fields
    case $key in
        GPU_INSTANCE_TYPE)
            echo "$value (~\$0.526/hr)"
            ;;
        S3_CONFORMER_RMIR)
            echo "s3://.../conformer/$(basename "$value")"
            ;;
        S3_CONFORMER_SOURCE)
            echo "s3://.../conformer/$(basename "$value")"
            ;;
        S3_CONFORMER_TRITON_CACHE)
            echo "s3://.../conformer/riva_repository/"
            ;;
        NGC_API_KEY)
            if [ -z "$value" ]; then
                echo "(not set - optional)"
            else
                echo "nvapi-***${value: -6}"
            fi
            ;;
        *)
            echo "$value"
            ;;
    esac
}

show_preview() {
    clear
    cat << 'EOF'
╔════════════════════════════════════════════════════════════════════════╗
║        NVIDIA Riva Conformer-CTC Configuration Preview                ║
╚════════════════════════════════════════════════════════════════════════╝

EOF

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "AWS CONFIGURATION"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf " ${CYAN}%-2s${NC}. %-25s ${BOLD}%s${NC}\n" "1" "${CONFIG_LABELS[AWS_REGION]}" "$(get_display_value AWS_REGION)"
    printf " ${CYAN}%-2s${NC}. %-25s ${BOLD}%s${NC}\n" "2" "${CONFIG_LABELS[AWS_ACCOUNT_ID]}" "$(get_display_value AWS_ACCOUNT_ID)"
    printf " ${CYAN}%-2s${NC}. %-25s ${BOLD}%s${NC}\n" "3" "${CONFIG_LABELS[GPU_INSTANCE_TYPE]}" "$(get_display_value GPU_INSTANCE_TYPE)"
    printf " ${CYAN}%-2s${NC}. %-25s ${BOLD}%s${NC}\n" "4" "${CONFIG_LABELS[SSH_KEY_NAME]}" "$(get_display_value SSH_KEY_NAME)"
    echo ""

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "RIVA MODEL CONFIGURATION"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf " ${CYAN}%-2s${NC}. %-25s ${BOLD}%s${NC}\n" "5" "${CONFIG_LABELS[RIVA_MODEL]}" "$(get_display_value RIVA_MODEL)"
    printf " ${CYAN}%-2s${NC}. %-25s ${BOLD}%s${NC}\n" "6" "${CONFIG_LABELS[S3_CONFORMER_RMIR]}" "$(get_display_value S3_CONFORMER_RMIR)"
    printf " ${CYAN}%-2s${NC}. %-25s ${BOLD}%s${NC}\n" "7" "${CONFIG_LABELS[S3_CONFORMER_SOURCE]}" "$(get_display_value S3_CONFORMER_SOURCE)"
    printf " ${CYAN}%-2s${NC}. %-25s ${BOLD}%s${NC}\n" "8" "${CONFIG_LABELS[S3_CONFORMER_TRITON_CACHE]}" "$(get_display_value S3_CONFORMER_TRITON_CACHE)"
    printf " ${CYAN}%-2s${NC}. %-25s ${BOLD}%s${NC}\n" "9" "${CONFIG_LABELS[RIVA_PORT]}" "$(get_display_value RIVA_PORT)"
    printf " ${CYAN}%-2s${NC}. %-25s ${BOLD}%s${NC}\n" "10" "${CONFIG_LABELS[RIVA_HTTP_PORT]}" "$(get_display_value RIVA_HTTP_PORT)"
    printf " ${CYAN}%-2s${NC}. %-25s ${BOLD}%s${NC}\n" "11" "${CONFIG_LABELS[RIVA_LANGUAGE_CODE]}" "$(get_display_value RIVA_LANGUAGE_CODE)"
    echo ""

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "OPTIONAL CONFIGURATION"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf " ${CYAN}%-2s${NC}. %-25s ${BOLD}%s${NC}\n" "12" "${CONFIG_LABELS[NGC_API_KEY]}" "$(get_display_value NGC_API_KEY)"
    printf " ${CYAN}%-2s${NC}. %-25s ${BOLD}%s${NC}\n" "13" "${CONFIG_LABELS[APP_PORT]}" "$(get_display_value APP_PORT)"
    printf " ${CYAN}%-2s${NC}. %-25s ${BOLD}%s${NC}\n" "14" "${CONFIG_LABELS[ENABLE_HTTPS]}" "$(get_display_value ENABLE_HTTPS)"
    printf " ${CYAN}%-2s${NC}. %-25s ${BOLD}%s${NC}\n" "15" "${CONFIG_LABELS[LOG_LEVEL]}" "$(get_display_value LOG_LEVEL)"
    printf " ${CYAN}%-2s${NC}. %-25s ${BOLD}%s${NC}\n" "16" "${CONFIG_LABELS[WS_MAX_CONNECTIONS]}" "$(get_display_value WS_MAX_CONNECTIONS)"
    echo ""

    echo "┌────────────────────────────────────────────────────────────────────────┐"
    echo -e "│ ${BOLD}COMMANDS:${NC}                                                            │"
    echo -e "│   ${CYAN}1-16${NC}        Edit that setting (e.g., \"${CYAN}3${NC}\" to edit GPU type)        │"
    echo -e "│   ${CYAN}?1-?16${NC}      Show detailed help (e.g., \"${CYAN}?7${NC}\" for S3 Source help)    │"
    echo -e "│   ${CYAN}i${NC}           Info about model file relationships                   │"
    echo -e "│   ${CYAN}a${NC}           Accept all and create .env file                       │"
    echo -e "│   ${CYAN}q${NC}           Quit without saving                                   │"
    echo "└────────────────────────────────────────────────────────────────────────┘"
    echo ""
}

# ============================================================================
# Edit Functions
# ============================================================================

edit_setting() {
    local num=$1
    local key="${CONFIG_KEYS[$num]}"
    local label="${CONFIG_LABELS[$key]}"
    local current="${CONFIG_VALUES[$key]}"

    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}Editing: $label${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Show current value
    if [ "$key" = "NGC_API_KEY" ] && [ -n "$current" ]; then
        echo -e "Current value: ${DIM}nvapi-***${current: -6}${NC}"
    else
        echo -e "Current value: ${DIM}$current${NC}"
    fi
    echo ""

    # Show context-specific prompts
    case $key in
        AWS_ACCOUNT_ID)
            echo "Enter your 12-digit AWS Account ID"
            echo "Find it: AWS Console → Click your name (top-right) → Account ID"
            echo "Or run: aws sts get-caller-identity --query Account --output text"
            ;;
        GPU_INSTANCE_TYPE)
            echo "Available GPU instance types:"
            echo "  • g4dn.xlarge  - T4 GPU, 4 vCPU, 16GB RAM (~\$0.526/hr) [RECOMMENDED]"
            echo "  • g4dn.2xlarge - T4 GPU, 8 vCPU, 32GB RAM (~\$0.752/hr)"
            echo "  • g5.xlarge    - A10G, 4 vCPU, 16GB RAM (~\$1.006/hr)"
            echo "  • p3.2xlarge   - V100, 8 vCPU, 61GB RAM (~\$3.06/hr)"
            ;;
        SSH_KEY_NAME)
            echo "Enter the name of your EC2 key pair (without .pem extension)"
            echo "Example: If file is 'dbm-oct5-2025.pem', enter 'dbm-oct5-2025'"
            echo "Find existing keys: AWS Console → EC2 → Key Pairs"
            ;;
        NGC_API_KEY)
            echo "Get your NGC API key from: https://catalog.ngc.nvidia.com/"
            echo "Click profile icon → Setup → Generate API Key"
            echo "Leave empty if using pre-downloaded containers from S3"
            ;;
        S3_CONFORMER_RMIR)
            echo "S3 path to pre-built RMIR file (fast deployment)"
            echo "Default is recommended unless you have a custom RMIR"
            ;;
        S3_CONFORMER_SOURCE)
            echo "S3 path to source .riva file (requires riva-build)"
            echo "Default is recommended unless you have a custom source model"
            ;;
    esac

    echo ""

    # Read new value with hidden input for NGC API key
    if [ "$key" = "NGC_API_KEY" ]; then
        echo -n -e "${YELLOW}Enter new value (hidden input, press Enter to skip): ${NC}"
        read -s new_value
        echo ""
    else
        echo -n -e "${YELLOW}Enter new value (or press Enter to keep current): ${NC}"
        read new_value
    fi

    # If empty, keep current value
    if [ -z "$new_value" ]; then
        echo -e "${GREEN}✓ Keeping current value${NC}"
        sleep 1
        return
    fi

    # Validate based on field type
    case $key in
        AWS_ACCOUNT_ID)
            if [[ ! $new_value =~ ^[0-9]{12}$ ]]; then
                echo -e "${RED}❌ Invalid AWS Account ID. Must be exactly 12 digits.${NC}"
                echo "Press Enter to continue..."
                read
                return
            fi
            ;;
        RIVA_PORT|RIVA_HTTP_PORT|APP_PORT)
            if [[ ! $new_value =~ ^[0-9]+$ ]] || [ "$new_value" -lt 1 ] || [ "$new_value" -gt 65535 ]; then
                echo -e "${RED}❌ Invalid port number. Must be 1-65535.${NC}"
                echo "Press Enter to continue..."
                read
                return
            fi
            ;;
        WS_MAX_CONNECTIONS)
            if [[ ! $new_value =~ ^[0-9]+$ ]] || [ "$new_value" -lt 1 ]; then
                echo -e "${RED}❌ Invalid number. Must be positive integer.${NC}"
                echo "Press Enter to continue..."
                read
                return
            fi
            ;;
    esac

    # Update value
    CONFIG_VALUES[$key]="$new_value"
    echo -e "${GREEN}✓ Updated successfully${NC}"
    sleep 1
}

# ============================================================================
# Main Interactive Loop
# ============================================================================

# Check if .env already exists
if [ -f "$ENV_FILE" ]; then
    echo -e "${YELLOW}⚠️  Configuration file already exists: $ENV_FILE${NC}"
    echo -n "Do you want to overwrite it? [y/N]: "
    read overwrite
    if [[ ! $overwrite =~ ^[Yy]$ ]]; then
        echo "Configuration setup cancelled."
        exit 0
    fi
    echo ""
    FIRST_RUN=false
fi

# Show welcome screen on first run
if [ "$FIRST_RUN" = "true" ]; then
    show_welcome
fi

# Main loop
while true; do
    show_preview

    echo -n -e "${BOLD}Enter command: ${NC}"
    read command

    # Parse command
    case $command in
        [1-9]|1[0-6])
            # Edit setting
            edit_setting "$command"
            ;;
        \?[1-9]|\?1[0-6])
            # Show help
            help_num="${command:1}"
            "show_help_$help_num"
            ;;
        i|I)
            # Show model info
            show_model_info
            ;;
        a|A)
            # Accept all and create .env
            break
            ;;
        q|Q)
            # Quit
            echo ""
            echo "Configuration cancelled. No changes saved."
            exit 0
            ;;
        "")
            # Empty input, just refresh
            ;;
        *)
            echo ""
            echo -e "${RED}❌ Invalid command: '$command'${NC}"
            echo ""
            echo "Valid commands:"
            echo "  • 1-16      Edit a setting (e.g., '3')"
            echo "  • ?1-?16    Show help (e.g., '?7')"
            echo "  • i         Model info"
            echo "  • a         Accept and save"
            echo "  • q         Quit"
            echo ""
            echo "Press Enter to continue..."
            read
            ;;
    esac
done

# ============================================================================
# Generate .env File
# ============================================================================

clear
echo -e "${BLUE}📝 Creating configuration file...${NC}"
echo ""

# Generate timestamp
DEPLOYMENT_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
DEPLOYMENT_ID="riva-$(date +%Y%m%d-%H%M%S)"

# Create .env file
cat > "$ENV_FILE" << EOF
# NVIDIA Riva ASR Deployment Configuration
# Generated on: $DEPLOYMENT_TIMESTAMP
# Deployment ID: $DEPLOYMENT_ID

# ============================================================================
# Deployment Strategy
# ============================================================================
DEPLOYMENT_STRATEGY=1
DEPLOYMENT_ID=$DEPLOYMENT_ID
DEPLOYMENT_TIMESTAMP=$DEPLOYMENT_TIMESTAMP
RIVA_HOST_TYPE=aws_ec2

# ============================================================================
# AWS Configuration (for EC2 deployment)
# ============================================================================
AWS_REGION=${CONFIG_VALUES[AWS_REGION]}
AWS_ACCOUNT_ID=${CONFIG_VALUES[AWS_ACCOUNT_ID]}
GPU_INSTANCE_TYPE=${CONFIG_VALUES[GPU_INSTANCE_TYPE]}
SSH_KEY_NAME=${CONFIG_VALUES[SSH_KEY_NAME]}

# ============================================================================
# Riva Server Connection
# ============================================================================
RIVA_HOST=auto_detected
RIVA_PORT=${CONFIG_VALUES[RIVA_PORT]}
RIVA_HTTP_PORT=${CONFIG_VALUES[RIVA_HTTP_PORT]}
RIVA_SSL=false
RIVA_SSL_CERT=
RIVA_SSL_KEY=

# ============================================================================
# Riva Model Configuration
# ============================================================================
RIVA_MODEL=${CONFIG_VALUES[RIVA_MODEL]}
RIVA_LANGUAGE_CODE=${CONFIG_VALUES[RIVA_LANGUAGE_CODE]}
RIVA_ENABLE_AUTOMATIC_PUNCTUATION=true
RIVA_ENABLE_WORD_TIME_OFFSETS=true

# ============================================================================
# S3 Model Paths
# ============================================================================
# Shared configuration
S3_MODEL_BUCKET=dbm-cf-2-web
RIVA_SERVER_PATH=s3://dbm-cf-2-web/bintarball/riva-containers/riva-speech-2.19.0.tar.gz

# Conformer-CTC (Scripts 100-110, Deploy: 125)
S3_CONFORMER_RMIR=${CONFIG_VALUES[S3_CONFORMER_RMIR]}
S3_CONFORMER_SOURCE=${CONFIG_VALUES[S3_CONFORMER_SOURCE]}
S3_CONFORMER_TRITON_CACHE=${CONFIG_VALUES[S3_CONFORMER_TRITON_CACHE]}

# Parakeet RNNT (Scripts 116-118, Deploy: 135)
S3_PARAKEET_SOURCE=s3://dbm-cf-2-web/bintarball/riva-models/parakeet/parakeet-rnnt-riva-1-1b-en-us-deployable_v8.1.tar.gz
S3_PARAKEET_TRITON_CACHE=s3://dbm-cf-2-web/bintarball/riva-repository/parakeet-rnnt-1.1b/v8.1/

# ============================================================================
# NVIDIA NGC
# ============================================================================
NGC_API_KEY=${CONFIG_VALUES[NGC_API_KEY]}

# ============================================================================
# Connection Settings
# ============================================================================
RIVA_TIMEOUT_MS=5000
RIVA_MAX_RETRIES=3
RIVA_RETRY_DELAY_MS=1000

# ============================================================================
# Performance Tuning
# ============================================================================
RIVA_MAX_BATCH_SIZE=8
RIVA_CHUNK_SIZE_BYTES=8192
RIVA_ENABLE_PARTIAL_RESULTS=true
RIVA_PARTIAL_RESULT_INTERVAL_MS=300

# ============================================================================
# Build & Deployment Optimizations (Scripts 100-102, 125)
# ============================================================================
# REMOTE_SYNC: Skip SCP hop, sync GPU→S3 directly in script 102
# Requires GPU instance to have AWS credentials (IAM role)
REMOTE_SYNC=false

# GOLDEN_WAV_S3: Optional validation audio for script 124
# Used to smoke-test models before uploading to S3 cache
# Should be 16kHz mono PCM WAV, 3-5 seconds duration
GOLDEN_WAV_S3=

# ============================================================================
# Application Server Settings
# ============================================================================
APP_HOST=0.0.0.0
APP_PORT=${CONFIG_VALUES[APP_PORT]}
DEMO_PORT=${CONFIG_VALUES[DEMO_PORT]}
APP_SSL_CERT=/opt/whisperlive/certs/server.crt
APP_SSL_KEY=/opt/whisperlive/certs/server.key

# WebSocket Bridge Deployment Directory (auto-detected from project name)
BRIDGE_DEPLOY_DIR=/opt/whisperlive/$(basename "$PROJECT_ROOT")

# ============================================================================
# WebSocket Settings
# ============================================================================
WS_MAX_CONNECTIONS=${CONFIG_VALUES[WS_MAX_CONNECTIONS]}
WS_PING_INTERVAL_S=30
WS_MAX_MESSAGE_SIZE_MB=10

# ============================================================================
# Audio Processing
# ============================================================================
AUDIO_SAMPLE_RATE=16000
AUDIO_CHANNELS=1
AUDIO_ENCODING=pcm16
AUDIO_MAX_SEGMENT_DURATION_S=30
AUDIO_VAD_ENABLED=true
AUDIO_VAD_THRESHOLD=0.5

# ============================================================================
# Observability
# ============================================================================
LOG_LEVEL=${CONFIG_VALUES[LOG_LEVEL]}
LOG_DIR=/opt/whisperlive/logs
METRICS_ENABLED=true
METRICS_PORT=9090
TRACING_ENABLED=false
TRACING_ENDPOINT=http://localhost:4317

# ============================================================================
# Development/Testing
# ============================================================================
DEBUG_MODE=false
TEST_AUDIO_PATH=/opt/whisperlive/test_audio

# ============================================================================
# Batch Transcription Configuration
# ============================================================================
# Used by scripts/515-run-batch-transcribe.sh for optimized parallel processing
#
# Performance Tuning:
# - BATCH_SIZE: Number of chunks to process in a single batch (default: 100)
#   * Higher = fewer model reloads, faster total time
#   * Lower = more frequent progress updates, easier to debug
#   * Recommended: 100 for production, 10 for testing
#
# - BATCH_MAX_PARALLEL_*: Concurrent S3 operations (default: 20)
#   * Higher = faster downloads/uploads, more system resources
#   * Lower = more conservative, safer for resource-constrained systems
#   * AWS S3 limit: ~5,500 requests/second per prefix
#   * Recommended: 20-40 depending on available memory/network
#
# - BATCH_DOWNLOAD_THRESHOLD: When to start GPU processing (default: 30)
#   * Batches <30: Wait for all downloads (minimize transfer overhead)
#   * Batches ≥30: Start GPU after 30 files (faster startup)
#
# - WHISPER_MODEL: Accuracy vs speed trade-off
#   * tiny.en (39M params): 4-5x faster, lower accuracy
#   * base.en (74M params): 2-3x faster, good accuracy [RECOMMENDED]
#   * small.en (244M params): Baseline speed, better accuracy [DEFAULT]
#   * medium.en (769M params): 2x slower, best accuracy
#
# - WHISPER_COMPUTE_TYPE: Precision vs speed
#   * int8: ~2x faster, minimal accuracy loss [RECOMMENDED FOR SPEED]
#   * int8_float16: 1.5x faster, hybrid approach
#   * float16: Baseline speed [DEFAULT]
#   * float32: Slower, no benefit
#
# Example configurations:
#   Fastest (2-3x speedup): WHISPER_MODEL=base.en, WHISPER_COMPUTE_TYPE=int8
#   Balanced: WHISPER_MODEL=small.en, WHISPER_COMPUTE_TYPE=int8 [DEFAULT]
#   Best Quality: WHISPER_MODEL=medium.en, WHISPER_COMPUTE_TYPE=int8
#
BATCH_SIZE=100
BATCH_MAX_PARALLEL_DOWNLOAD=20
BATCH_MAX_PARALLEL_UPLOAD=20
BATCH_DOWNLOAD_THRESHOLD=30
BATCH_DOWNLOAD_TIMEOUT=60
WHISPER_MODEL=small.en
WHISPER_COMPUTE_TYPE=int8

# GPU Configuration for Batch Processing
GPU_INSTANCE_ID=your-gpu-instance-id      # EC2 instance ID (i-xxxxx)
GPU_SSH_KEY_PATH=/home/ubuntu/.ssh/your-key.pem
GPU_HOURLY_COST=0.526                      # g4dn.xlarge on-demand pricing

# ============================================================================
# Status Flags (used by deployment scripts)
# ============================================================================
CONFIG_VALIDATION_PASSED=true
RIVA_DEPLOYMENT_STATUS=pending
APP_DEPLOYMENT_STATUS=pending
TESTING_STATUS=pending
EOF

# Set proper permissions
chmod 600 "$ENV_FILE"

echo -e "${GREEN}✅ Configuration file created: $ENV_FILE${NC}"
echo ""

# Show configuration summary
echo -e "${BLUE}📋 Configuration Summary:${NC}"
echo "  • Deployment Strategy: AWS EC2 GPU Worker"
echo "  • AWS Region: ${CONFIG_VALUES[AWS_REGION]}"
echo "  • AWS Account: ${CONFIG_VALUES[AWS_ACCOUNT_ID]}"
echo "  • Instance Type: ${CONFIG_VALUES[GPU_INSTANCE_TYPE]}"
echo "  • SSH Key: ${CONFIG_VALUES[SSH_KEY_NAME]}"
echo "  • Riva Model: ${CONFIG_VALUES[RIVA_MODEL]}"
echo "  • App Port: ${CONFIG_VALUES[APP_PORT]}"
echo "  • HTTPS: ${CONFIG_VALUES[ENABLE_HTTPS]}"
echo "  • Log Level: ${CONFIG_VALUES[LOG_LEVEL]}"
echo ""

# Show next steps
echo -e "${GREEN}🎯 Next Steps:${NC}"
echo -e "1. Install build box dependencies: ${CYAN}./scripts/010-setup-build-box.sh${NC}"
echo -e "2. Deploy GPU instance: ${CYAN}./scripts/020-deploy-gpu-instance.sh${NC}"
echo -e "3. Configure security groups: ${CYAN}./scripts/030-configure-security-groups.sh${NC}"
echo -e "4. Deploy Conformer-CTC model: ${CYAN}./scripts/110-deploy-conformer-streaming.sh${NC}"
echo -e "5. Test: ${CYAN}https://<BUILDBOX-IP>:8444/demo.html${NC}"
echo ""
echo -e "Or run the complete deployment: ${CYAN}./scripts/riva-000-run-complete-deployment.sh${NC}"
echo ""

echo -e "${BLUE}⚠️  Security Note:${NC}"
echo "• The .env file contains sensitive configuration"
echo "• It's excluded from git (check .gitignore)"
echo "• Keep this file secure and don't share it"
echo ""

echo -e "${CYAN}✨ Configuration setup complete!${NC}"
