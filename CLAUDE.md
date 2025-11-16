# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a **monorepo** for CloudDrive, a real-time audio transcription and cloud storage SaaS platform, with supporting infrastructure and experimental transcription engines. The main production component is `transcription-realtime-whisper-cognito-s3-lambda-ver4/`.

## Core Architecture

### System Components

**CloudDrive Application** (transcription-realtime-whisper-cognito-s3-lambda-ver4/)
- Frontend: Static HTML/JS on S3 + CloudFront
- Backend: AWS Lambda (Node.js) via Serverless Framework
- Auth: AWS Cognito (User Pools + Identity Pools + OAuth)
- Storage: S3 with user-scoped paths (`users/{userId}/`)
- Transcription: WhisperLive (Faster-Whisper on GPU) + optional batch processing
- Proxy: Caddy reverse proxy on Edge Box for WSS connections

**EventBridge Orchestrator** (eventbridge-orchestrator/)
- Central event bus for decoupled microservices
- Deployed via Terraform
- Event types: AudioUploaded, TranscriptionCompleted, UserRegistered, etc.
- Schema validation and dead-letter queue

**WhisperLive System** (whisper-live-test/)
- Faster-Whisper on GPU worker (g4dn.xlarge)
- WebSocket server for real-time streaming
- Caddy reverse proxy on Edge Box with SSL termination

### Network Architecture

```
Browser ──WSS──> Edge Box (Caddy) ──> GPU (WhisperLive:9090)
   │
   └──HTTPS──> CloudFront ──> S3/Lambda ──> Cognito
```

**Security Model:**
- GPU Worker: Internal-only, accepts connections ONLY from Edge Box
- Edge Box: Public-facing with client IP allowlist in `authorized_clients.txt`
- CloudFront: HTTPS only with Cognito authorizer

## Key File Locations

### CloudDrive Main Project

**Configuration:**
- `.env` - All environment variables (AWS, Cognito, WhisperLive URLs)
- `.env.example` - Template for configuration

**Backend:**
- `cognito-stack/serverless.yml` - Serverless Framework configuration
- `cognito-stack/api/*.js` - Lambda function handlers
  - `s3.js` - File operations (list, download, upload, delete, rename, move)
  - `audio.js` - Audio chunk upload for recording sessions
  - `memory.js` - Claude memory API integration
  - `transcription.js` - Batch transcription
  - `google-docs.js` - Google Docs integration

**Frontend Source (Source of Truth):**
- `ui-source/*.template` - **ALWAYS edit these, NEVER edit cognito-stack/web/**
- `ui-source/app.js.template` - Main application config
- `ui-source/audio.html.template` - Audio recorder UI
- `ui-source/index.html` - Dashboard
- `ui-source/viewer.html` - Transcript viewer
- `ui-source/transcript-editor.html.template` - Transcript editor

**Deployment Scripts:**
- `scripts/` - Numbered deployment automation (000-899)
- `logs/` - Script execution logs

### EventBridge Orchestrator

- `terraform/*.tf` - Infrastructure as code
- `schemas/*.json` - Event schema definitions
- `lambdas/*/` - Event processing Lambda functions

### WhisperLive

- `src/asr/` - WhisperLive Python code
- `docker-compose.yml` - Caddy proxy configuration
- `Caddyfile` - Reverse proxy rules

## Common Commands

### Backend Development

```bash
# Deploy all backend changes
cd transcription-realtime-whisper-cognito-s3-lambda-ver4/cognito-stack
serverless deploy

# Deploy single Lambda function (faster)
serverless deploy function -f listS3Files

# View function logs (live tail)
serverless logs -f listS3Files -t

# Test function locally
serverless invoke local -f listS3Files
```

### UI Development

```bash
cd transcription-realtime-whisper-cognito-s3-lambda-ver4

# 1. Edit source files in ui-source/*.template
vim ui-source/audio.html.template
vim ui-source/app.js.template

# 2. Deploy changes (replaces placeholders with .env values)
./scripts/425-deploy-recorder-ui.sh

# 3. Verify deployment
curl -s ${COGNITO_CLOUDFRONT_URL}/app.js | grep whisperLiveWsUrl
```

### Full Stack Deployment

```bash
cd transcription-realtime-whisper-cognito-s3-lambda-ver4

# 1. Configure environment
./scripts/005-setup-configuration.sh

# 2. Setup Edge Box (run ON edge box instance)
./scripts/010-setup-edge-box.sh
./scripts/305-setup-whisperlive-edge.sh

# 3. Setup GPU Worker
./scripts/020-deploy-gpu-instance.sh
./scripts/310-configure-whisperlive-gpu.sh

# 4. Security configuration
./scripts/030-configure-gpu-security.sh      # Lock GPU to edge-only
./scripts/031-configure-edge-box-security.sh # Configure client allowlist

# 5. Deploy backend (~10-15 minutes)
./scripts/420-deploy-cognito-stack.sh

# 6. Deploy UI
./scripts/425-deploy-recorder-ui.sh

# 7. Create test user
./scripts/430-create-cognito-user.sh

# 8. Test end-to-end
./scripts/450-test-audio-transcription.sh
```

### WhisperLive Operations

```bash
cd transcription-realtime-whisper-cognito-s3-lambda-ver4

# Start GPU and restore everything (4-5 minutes)
./scripts/820-startup-restore.sh

# Shutdown GPU to save costs (~$189/month savings)
./scripts/810-shutdown-gpu.sh

# Handle Edge Box IP changes after restart
./scripts/825-edge-box-detect-new-ip-and-redeploy.sh

# Diagnose connection issues
./scripts/826-edge-box-diagnose-connection-issues.sh
```

### Batch Transcription

```bash
cd transcription-realtime-whisper-cognito-s3-lambda-ver4

# Run batch transcription on all audio sessions
./scripts/515-run-batch-transcribe.py --all

# Scan for missing audio chunks
./scripts/512-scan-missing-chunks.sh

# Check GPU usage costs
./scripts/530-gpu-cost-tracker.sh
```

### EventBridge Deployment

```bash
cd eventbridge-orchestrator

# Deploy all infrastructure
./deploy-all.sh --auto-approve

# Or step-by-step:
./step-001-preflight-check.sh
./step-010-setup-iam-permissions.sh
./step-020-deploy-infrastructure.sh
./step-040-deploy-lambdas.sh
./step-050-test-events.sh

# Using Terraform directly
cd terraform
terraform init
terraform plan
terraform apply
```

### Testing

```bash
cd transcription-realtime-whisper-cognito-s3-lambda-ver4

# Browser automation tests (Playwright)
.claude/skills/clouddrive-browser/test-login.sh
.claude/skills/clouddrive-browser/test-upload.sh
.claude/skills/clouddrive-browser/test-workflow.sh
.claude/skills/clouddrive-browser/test-transcript-editor.sh

# Download files from CloudDrive for testing
.claude/skills/clouddrive-download/download.sh "screenshot"
.claude/skills/clouddrive-download/file-search.sh --list
```

## Critical Configuration Patterns

### Template Processing

**Source of Truth:** `ui-source/*.template` files

The deployment script (`scripts/425-deploy-recorder-ui.sh`) replaces placeholders with `.env` values:
- `YOUR_USER_POOL_ID` → `${COGNITO_USER_POOL_ID}`
- `TO_BE_REPLACED_REGION` → `${AWS_REGION}`
- `YOUR_WHISPERLIVE_WS_URL` → `${WHISPERLIVE_WS_URL}`

**CRITICAL:** Always edit `ui-source/*.template`, never `cognito-stack/web/*` (auto-generated)

### Environment Variables (.env)

```bash
# AWS Core
AWS_REGION=us-east-2
AWS_ACCOUNT_ID=xxxx
SERVICE_NAME=clouddrive-app

# Cognito (auto-populated after deployment)
COGNITO_S3_BUCKET=xxx
COGNITO_USER_POOL_ID=xxx
COGNITO_CLOUDFRONT_URL=https://xxx.cloudfront.net
COGNITO_API_ENDPOINT=https://xxx.execute-api.xxx

# WhisperLive
WHISPERLIVE_WS_URL=wss://3.16.164.228/ws  # Edge box IP, NOT GPU IP
GPU_INSTANCE_IP=3.18.106.129
GPU_INSTANCE_ID=i-xxx

# Testing
CLOUDDRIVE_TEST_EMAIL=xxx
CLOUDDRIVE_TEST_PASSWORD=xxx
```

### S3 Bucket Structure

```
s3://{BUCKET}/
├── users/{userId}/              # User files
├── audio-sessions/{userId}/     # Audio recordings
│   └── {sessionId}/
│       ├── chunk-001.webm
│       └── metadata.json
├── transcripts/{sessionId}/     # Batch transcripts
├── claude-memory/
│   ├── public/
│   └── {userId}/
└── (CloudFront static assets)
```

### Lambda Function Reference

1. **listS3Files** - List files in user's S3 path
2. **getS3DownloadUrl** - Generate presigned download URL (15min expiry)
3. **getS3UploadUrl** - Generate presigned upload URL
4. **deleteS3Object** - Delete user file
5. **renameS3Object** - Rename file (copy + delete)
6. **moveS3Object** - Move file to different folder
7. **getAudioUploadChunkUrl** - Upload audio chunks during recording
8. **storeMemory** - Store Claude memory files
9. **batchLock** - Batch transcription locking mechanism
10. **googleDocs** - Google Docs integration API

## Script Numbering Convention

- **000-099:** Initial setup and configuration
- **010-099:** Edge box and GPU instance setup
- **300-399:** WhisperLive Edge/GPU configuration
- **400-499:** Cognito/S3/Lambda backend deployment
- **500-599:** Google Docs integration and batch processing
- **700-799:** Advanced features
- **800-899:** Operations (startup, shutdown, diagnostics)

## Technology Stack

**Frontend:**
- Vanilla JavaScript (no frameworks)
- MediaRecorder API for audio capture
- WebSocket for real-time transcription
- IndexedDB for offline storage

**Backend:**
- AWS Lambda (Node.js 18.x)
- API Gateway (REST with Cognito authorizer)
- Cognito (User Pools, Identity Pools, OAuth)
- S3 + CloudFront
- EventBridge (event bus)

**Transcription:**
- Faster-Whisper (optimized OpenAI Whisper)
- WhisperLive (WebSocket server)
- GPU: g4dn.xlarge ($0.526/hour on-demand, $0.158/hour spot)

**Infrastructure:**
- Serverless Framework (backend deployment)
- Terraform (EventBridge infrastructure)
- Docker (containerization)
- Systemd (service management)
- Caddy (reverse proxy + SSL)

**Development:**
- Playwright (browser automation)
- AWS CLI (infrastructure management)
- Bash (deployment automation)

## Troubleshooting

### Edge Box IP Changes

**Problem:** Edge Box gets new public IP after stop/start

**Solution:**
```bash
./scripts/825-edge-box-detect-new-ip-and-redeploy.sh
./scripts/827-edge-box-enable-auto-ip-detection-on-boot.sh
```

This updates:
1. `.env` WHISPERLIVE_WS_URL
2. UI templates
3. CloudFront deployment
4. Caddy configuration

### Common Issues Checklist

1. **WebSocket connection fails:**
   - Verify WHISPERLIVE_WS_URL uses Edge Box IP (not GPU IP)
   - Check Edge Box security group allows client IP
   - Verify GPU is running and WhisperLive service is active

2. **Cognito authentication fails:**
   - Clear browser localStorage
   - Verify Cognito User Pool and App Client IDs in .env
   - Check CloudFront URL matches deployed domain

3. **UI changes not appearing:**
   - Verify editing `ui-source/*.template` (not cognito-stack/web/*)
   - Run `./scripts/425-deploy-recorder-ui.sh`
   - Wait for CloudFront cache invalidation (~5 minutes)

4. **Lambda function errors:**
   - Check CloudWatch logs: `serverless logs -f <functionName> -t`
   - Verify IAM permissions in serverless.yml
   - Test locally: `serverless invoke local -f <functionName>`

5. **S3 presigned URL expires:**
   - URLs expire after 15 minutes
   - Generate new URL via API

### GPU Cost Optimization

**Daily shutdown/startup pattern saves ~$189/month:**

```bash
# Evening
./scripts/810-shutdown-gpu.sh

# Morning (4-5 minute restoration)
./scripts/820-startup-restore.sh
```

**Spot instances:** Use for 70% cost savings on GPU

## Experimental Projects

This monorepo contains several experimental transcription engines:

- **nvidia-parakeet-ver-6** - NVIDIA Parakeet RNNT with NIM
- **nvidia-riva-conformer-streaming-ver-8/9** - NVIDIA Riva 2.19 with Conformer-CTC-XL
- **rnn-t-Parakeet** - Experimental RNN-T implementation
- **audio-ui-cf-s3-lambda-cognito** - Earlier UI iteration
- **smart-transcription-router** - Routing logic for multiple ASR engines

These are for research and comparison. The production system uses WhisperLive.
