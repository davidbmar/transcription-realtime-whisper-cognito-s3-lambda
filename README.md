# CloudDrive - Real-Time Transcription Platform

**Version:** 6.10.0
**Production-Ready Speech-to-Text Service with Real-Time Transcription**

---

## 🎯 Overview

CloudDrive is a real-time audio transcription and cloud storage SaaS platform with:
- **Real-time transcription** via WhisperLive (Faster-Whisper on GPU)
- **Batch transcription** for recorded audio sessions
- **Cloud storage** with S3 and CloudFront
- **Authentication** via AWS Cognito
- **Offline support** with IndexedDB and automatic upload retry
- **Transcript editor** with word-level highlighting and export

---

## 🏗️ Architecture

### Core Components

```
Browser ──WSS──> Edge Box (Caddy) ──> GPU (WhisperLive:9090)
   │
   └──HTTPS──> CloudFront ──> S3/Lambda ──> Cognito
```

**Frontend:**
- Static HTML/JS on S3 + CloudFront
- Vanilla JavaScript (no frameworks)
- MediaRecorder API for audio capture
- WebSocket for real-time transcription
- IndexedDB for offline storage

**Backend:**
- AWS Lambda (Node.js 18.x) via Serverless Framework
- API Gateway with Cognito authorizer
- S3 for storage
- CloudFront for CDN

**Transcription:**
- WhisperLive (Faster-Whisper on GPU)
- GPU: g4dn.xlarge ($0.526/hour on-demand, $0.158/hour spot)
- Caddy reverse proxy on Edge Box

---

## 🚀 Quick Start

### Prerequisites

- AWS CLI configured with credentials
- SSH key created in AWS (name it in `.env`)
- Node.js 18+ (for serverless backend)
- Bash shell

### 1. Initial Setup

```bash
# Clone repository
cd transcription-realtime-whisper-cognito-s3-lambda-ver4

# Configure environment
./scripts/005-setup-configuration.sh
```

This creates your `.env` file with all necessary configuration.

### 2. Deploy Infrastructure

```bash
# Setup Edge Box (run ON edge box instance)
./scripts/010-setup-edge-box.sh
./scripts/305-setup-whisperlive-edge.sh

# Setup GPU Worker
./scripts/020-deploy-gpu-instance.sh
./scripts/310-configure-whisperlive-gpu.sh

# Lock down security
./scripts/030-configure-gpu-security.sh
./scripts/031-configure-edge-box-security.sh

# Deploy backend (~10-15 minutes)
./scripts/420-deploy-cognito-stack.sh

# Deploy UI
./scripts/425-deploy-recorder-ui.sh

# Create test user
./scripts/430-create-cognito-user.sh
```

### 3. Test

```bash
# Test end-to-end
./scripts/450-test-audio-transcription.sh

# Browser automation tests
.claude/skills/clouddrive-browser/test-login.sh
.claude/skills/clouddrive-browser/test-workflow.sh
```

---

## 📂 Project Structure

```
transcription-realtime-whisper-cognito-s3-lambda-ver4/
│
├── .env                           # Environment variables (gitignored)
├── .env.example                   # Template for configuration
├── CLAUDE.md                      # ⭐ Claude Code guidance (READ THIS)
│
├── cognito-stack/                 # Backend (Serverless Framework)
│   ├── serverless.yml             # CloudFormation template
│   ├── api/                       # Lambda function handlers
│   │   ├── s3.js                  # File operations
│   │   ├── audio.js               # Audio chunk upload
│   │   ├── transcription.js       # Batch transcription
│   │   └── google-docs.js         # Google Docs integration
│   └── web/                       # ⚠️ AUTO-GENERATED (DO NOT EDIT)
│
├── ui-source/                     # ✅ Frontend SOURCE OF TRUTH
│   ├── *.template                 # Template files (edit these!)
│   ├── audio.html.template        # Audio recorder UI
│   ├── transcript-editor.html.template
│   ├── lib/upload-queue.js        # Upload queue with retry
│   └── README.md                  # Template system docs
│
├── scripts/                       # Deployment automation
│   ├── 000-099: Setup
│   ├── 300-399: WhisperLive
│   ├── 400-499: Backend
│   ├── 500-599: Batch processing
│   ├── 800-899: Operations
│   └── lib/                       # Shared libraries
│
├── .claude/                       # Claude Code skills
│   └── skills/
│       ├── script-template/       # Generate new scripts
│       ├── clouddrive-browser/    # Browser automation
│       └── clouddrive-download/   # Download testing files
│
└── logs/                          # Execution logs
```

---

## 🔧 Common Operations

### Backend Development

```bash
cd cognito-stack

# Deploy all functions
serverless deploy

# Deploy single function (faster)
serverless deploy function -f listS3Files

# View logs
serverless logs -f listS3Files -t
```

### UI Development

```bash
# ⚠️ CRITICAL: Always edit ui-source/*.template (NOT cognito-stack/web/*)

# 1. Edit template
vim ui-source/audio.html.template

# 2. Deploy (replaces TO_BE_REPLACED_* placeholders)
./scripts/425-deploy-recorder-ui.sh

# 3. Verify
curl -s ${COGNITO_CLOUDFRONT_URL}/app.js | grep whisperLiveWsUrl
```

### WhisperLive Operations

```bash
# Start GPU and restore everything (4-5 minutes)
./scripts/820-startup-restore.sh

# Shutdown GPU to save costs (~$189/month savings)
./scripts/810-shutdown-gpu.sh

# Handle Edge Box IP changes
./scripts/825-edge-box-detect-new-ip-and-redeploy.sh
```

### Batch Transcription

```bash
# Run batch transcription
./scripts/515-run-batch-transcribe.py --all

# Scan for missing chunks
./scripts/512-scan-missing-chunks.sh

# Preprocess transcripts for instant editor loading
./scripts/518-scan-and-preprocess-transcripts.sh
```

---

## 📚 Documentation

**For Claude Code Users:**
- **[CLAUDE.md](CLAUDE.md)** - ⭐ Complete development guide (READ THIS FIRST)

**UI Development:**
- **[ui-source/README.md](ui-source/README.md)** - Template system documentation

**Recent Changes:**
- **[CHANGELOG-v6.7.0.md](CHANGELOG-v6.7.0.md)** - Wake Lock API + corruption fixes
- **[CHANGELOG-v6.8.0.md](CHANGELOG-v6.8.0.md)** - Enhanced diagnostics

**Deployment Notes:**
- **[DEPLOYMENT-v6.6.0-SUMMARY.md](DEPLOYMENT-v6.6.0-SUMMARY.md)** - Major deployment
- **[PHASE-1-COMPLETE.md](PHASE-1-COMPLETE.md)** - Download/export features
- **[PHASE-2-COMPLETE.md](PHASE-2-COMPLETE.md)** - Upload queue with retry

**Testing:**
- **[AUTOMATED-TESTING.md](AUTOMATED-TESTING.md)** - Browser automation
- **[BROWSER-DEBUG.md](BROWSER-DEBUG.md)** - Debugging guide

**Setup:**
- **[DNS-LETSENCRYPT-SETUP.md](DNS-LETSENCRYPT-SETUP.md)** - Domain configuration

---

## 🛠️ Script Numbering Convention

Scripts in `scripts/` are numbered by category:

- **000-099:** Initial setup and configuration
- **010-099:** Edge box and GPU instance setup
- **300-399:** WhisperLive Edge/GPU configuration
- **400-499:** Cognito/S3/Lambda backend deployment
- **500-599:** Google Docs integration and batch processing
- **700-799:** Advanced features
- **800-899:** Operations (startup, shutdown, diagnostics)

All scripts log to `logs/` directory automatically.

---

## 🧪 Testing

### Browser Automation (Playwright)

```bash
# Login test
.claude/skills/clouddrive-browser/test-login.sh

# Upload test
.claude/skills/clouddrive-browser/test-upload.sh

# Complete workflow
.claude/skills/clouddrive-browser/test-workflow.sh

# Transcript editor
.claude/skills/clouddrive-browser/test-transcript-editor.sh
```

### Download Files for Testing

```bash
# Download specific file
.claude/skills/clouddrive-download/download.sh "screenshot"

# List all files
.claude/skills/clouddrive-download/file-search.sh --list
```

---

## 💾 S3 Bucket Structure

```
s3://{BUCKET}/
├── users/{userId}/              # User files
├── audio-sessions/{userId}/     # Audio recordings
│   └── {sessionId}/
│       ├── chunk-001.webm
│       ├── chunk-002.webm
│       └── metadata.json
├── transcripts/{sessionId}/     # Batch transcripts
│   └── transcript.json
├── preprocessed/{sessionId}/    # Preprocessed transcripts
│   └── words.json
├── claude-memory/
│   ├── public/
│   └── {userId}/
└── (CloudFront static assets)
```

---

## ⚙️ Environment Variables

Key variables in `.env`:

```bash
# AWS Core
AWS_REGION=us-east-2
SERVICE_NAME=clouddrive-app

# Cognito (auto-populated after deployment)
COGNITO_S3_BUCKET=xxx
COGNITO_USER_POOL_ID=xxx
COGNITO_CLOUDFRONT_URL=https://xxx.cloudfront.net
COGNITO_API_ENDPOINT=https://xxx.execute-api.xxx

# WhisperLive
WHISPERLIVE_WS_URL=wss://EDGE_BOX_IP/ws  # Edge box IP, NOT GPU
GPU_INSTANCE_IP=xxx
GPU_INSTANCE_ID=i-xxx

# Testing
CLOUDDRIVE_TEST_EMAIL=xxx
CLOUDDRIVE_TEST_PASSWORD=xxx
```

---

## 🚨 Critical Patterns

### Template System

**⚠️ ALWAYS edit `ui-source/*.template`, NEVER `cognito-stack/web/*`**

The deployment script replaces placeholders:
- `TO_BE_REPLACED_USER_POOL_ID` → `${COGNITO_USER_POOL_ID}`
- `TO_BE_REPLACED_REGION` → `${AWS_REGION}`
- `TO_BE_REPLACED_WHISPERLIVE_WS_URL` → `${WHISPERLIVE_WS_URL}`

### Lambda Functions

1. **listS3Files** - List user files
2. **getS3DownloadUrl** - Presigned download (15min)
3. **getS3UploadUrl** - Presigned upload
4. **deleteS3Object** - Delete file
5. **renameS3Object** - Rename file
6. **moveS3Object** - Move file
7. **getAudioUploadChunkUrl** - Upload audio chunks
8. **storeMemory** - Claude memory
9. **batchLock** - Transcription locking
10. **googleDocs** - Google Docs API
11. **viewerPublic** - Public viewer (no auth)

---

## 🔍 Troubleshooting

### WebSocket Connection Fails
- Check WHISPERLIVE_WS_URL uses Edge Box IP (not GPU IP)
- Verify GPU is running: `./scripts/537-test-gpu-ssh.sh`
- Check Caddy proxy: `docker ps` on Edge Box

### UI Changes Not Appearing
- Edit `ui-source/*.template` (not cognito-stack/web/*)
- Run `./scripts/425-deploy-recorder-ui.sh`
- Wait 5 minutes for CloudFront cache invalidation

### Edge Box IP Changed
```bash
./scripts/825-edge-box-detect-new-ip-and-redeploy.sh
```

### Audio Chunks Corrupted
- Wake Lock API prevents device sleep
- Chunk validation rejects files < 1KB
- Check browser console for errors

See [CLAUDE.md](CLAUDE.md) for complete troubleshooting guide.

---

## 💰 Cost Optimization

### GPU Shutdown/Startup

Daily shutdown saves ~$189/month:

```bash
# Evening
./scripts/810-shutdown-gpu.sh

# Morning (4-5 minute restoration)
./scripts/820-startup-restore.sh
```

### Spot Instances

Use spot instances for 70% cost savings on GPU.

---

## 🧑‍💻 Development

### Creating New Scripts

Use the script-template skill:

```bash
# From Claude Code
/skill script-template
```

This generates scripts with:
- Automatic logging to `logs/`
- Environment loading
- Error handling
- Success/failure reporting

### Backend Changes

```bash
cd cognito-stack

# Edit Lambda handlers
vim api/s3.js

# Deploy
serverless deploy function -f listS3Files

# Test locally
serverless invoke local -f listS3Files
```

---

## 📄 License

Proprietary - All Rights Reserved

---

## 🚀 Current Version: v6.10.0

**Recent Features:**
- Session folder structure with timezone support
- Absolute session time display
- Transcript editor with download/export
- Word-level highlighting
- Server-side preprocessing for instant loading
- Intelligent staleness detection

**See:** [CLAUDE.md](CLAUDE.md) for complete feature list

---

**For complete development guidance, see [CLAUDE.md](CLAUDE.md)**
