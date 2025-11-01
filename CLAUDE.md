# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Quick Orientation

**Before you start coding:**
1. **Configuration is in .env** - ALL deployment values come from `.env` (never hardcoded)
2. **Edit templates, not generated files** - Source of truth is `ui-source/*.template`, NOT `cognito-stack/web/*`
3. **Use deployment scripts** - Run `./scripts/425-deploy-recorder-ui.sh` to deploy UI changes
4. **Logs are your friend** - All scripts log to `logs/` directory with timestamps

**Common tasks:**
- Update UI → Edit `ui-source/app.js.template` or `ui-source/audio.html.template` → Run `./scripts/425-deploy-recorder-ui.sh`
- Deploy from scratch → Run scripts 005, 410, 420, 425, 430 in order
- View logs → `ls -lart logs/` or `tail -f logs/420-*.log`

## Project Overview

Real-time transcription service (CloudDrive) with Cognito authentication, S3 storage, and WhisperLive GPU transcription. Built as a revenue-generating SaaS product to fund AI consciousness research.

**Key Architecture:**
- **Frontend**: S3-hosted static UI (index.html, audio.html) served via CloudFront
- **Backend**: Serverless Lambda functions (cognito-stack/api/) for file management and audio operations
- **Auth**: AWS Cognito (OAuth + SRP) for user authentication
- **Storage**: S3 bucket with user-scoped paths (`users/{userId}/`)
- **Transcription**: WhisperLive on GPU EC2 instance (optional), WebSocket connection for real-time audio

## Critical Configuration Pattern

**ALL deployment-specific values must be in `.env`, NEVER hardcoded.** This enables multiple independent deployments.

### Configuration Sources
1. **`.env`** - Local deployment configuration (gitignored)
2. **`.env.example`** - Template with placeholders
3. **`ui-source/app.js.template`** - UI config template (gets values injected during deployment)

### Required .env Variables
```bash
# AWS Core
AWS_REGION=us-east-2
AWS_ACCOUNT_ID=your-account-id
SERVICE_NAME=clouddrive-app  # Used for resource naming

# Cognito (from deployment outputs)
COGNITO_S3_BUCKET=your-bucket
COGNITO_DOMAIN=your-cognito-domain
COGNITO_USER_POOL_ID=us-east-2_XXXXXXXXX
COGNITO_USER_POOL_CLIENT_ID=xxxxxxxxxxxxxxxxxx
COGNITO_IDENTITY_POOL_ID=us-east-2:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
COGNITO_CLOUDFRONT_URL=https://xxxxxxxxxxxxx.cloudfront.net
COGNITO_API_ENDPOINT=https://xxxxxxxxxx.execute-api.region.amazonaws.com/dev

# CloudDrive Browser Testing (optional - auto-prompted)
CLOUDDRIVE_TEST_EMAIL=your-email@example.com
CLOUDDRIVE_TEST_PASSWORD=your-password

# WhisperLive (optional)
WHISPERLIVE_HOST=your-gpu-ip
WHISPERLIVE_PORT=9090
WHISPERLIVE_WS_URL=wss://your-edge.com/ws
```

**Note:** Many variables are populated automatically by deployment scripts (420, 425) after `serverless deploy`.

### UI Configuration Pattern
**Template files** (`ui-source/*.template`) use placeholders that get replaced during deployment:

**app.js.template** - Placeholders used:
```javascript
const config = {
    userPoolId: 'YOUR_USER_POOL_ID',
    userPoolClientId: 'YOUR_USER_POOL_CLIENT_ID',
    identityPoolId: 'YOUR_IDENTITY_POOL_ID',
    region: 'YOUR_REGION',
    apiUrl: 'YOUR_CLOUDFRONT_API_ENDPOINT',
    s3ApiUrl: 'YOUR_CLOUDFRONT_S3_API_ENDPOINT',
    appUrl: 'YOUR_APP_URL',
    whisperLiveWsUrl: 'YOUR_WHISPERLIVE_WS_URL'
};
```

**audio.html.template** - Placeholders used:
```javascript
TO_BE_REPLACED_USER_POOL_ID
TO_BE_REPLACED_USER_POOL_CLIENT_ID
TO_BE_REPLACED_IDENTITY_POOL_ID
TO_BE_REPLACED_REGION
TO_BE_REPLACED_AUDIO_API_URL
TO_BE_REPLACED_APP_URL
TO_BE_REPLACED_WHISPERLIVE_WS_URL
```

**Deployment scripts** (420, 425) automatically:
1. Copy templates from `ui-source/` to `cognito-stack/web/`
2. Replace ALL placeholders with actual deployment values from .env
3. Upload processed files to S3
4. Invalidate CloudFront cache

**Runtime files** reference config directly (after placeholder replacement)

## Serverless Deployment (cognito-stack/)

### Deploy
```bash
cd cognito-stack
npm install
serverless deploy
```

This creates:
- S3 bucket for storage + CloudFront hosting
- Cognito User Pool + Identity Pool + OAuth App Client
- API Gateway with Cognito authorizer
- Lambda functions (see API Structure below)

### Remove
```bash
cd cognito-stack
serverless remove
```

### Environment Variable Usage in serverless.yml
```yaml
service: ${env:SERVICE_NAME, 'clouddrive-app'}
provider:
  region: ${env:AWS_REGION, 'us-east-2'}
custom:
  s3Bucket: ${env:COGNITO_S3_BUCKET, '${self:service}-bucket'}
```

## API Structure

Lambda functions in `cognito-stack/api/`:

**s3.js** - File Manager API
- `listObjects` - GET /api/s3/list - List user files
- `getDownloadUrl` - GET /api/s3/download/{key+} - Generate presigned download URL (15min)
- `getUploadUrl` - POST /api/s3/upload - Generate presigned upload URL
- `deleteObject` - DELETE /api/s3/delete/{key+} - Delete user file
- `renameObject` - POST /api/s3/rename - Rename file (copy + delete)
- `moveObject` - POST /api/s3/move - Move file to different folder

**audio.js** - Audio Recording API
- `getAudioUploadChunkUrl` - POST /api/audio/upload-chunk - Upload recorded audio chunks
- Session-based organization with chunk numbering

**memory.js** - Claude Memory API
- `storeMemory` - POST /api/memory/{scope} - Store Claude memory files (public or user-scoped)

**handler.js** - Test endpoint
- `getData` - GET /data - Health check / auth test

All endpoints require Cognito JWT token in `Authorization: Bearer {token}` header.

## S3 Bucket Structure

```
s3://{COGNITO_S3_BUCKET}/
├── users/{userId}/              # User files (scoped by Cognito sub)
│   ├── file.pdf
│   ├── folder/
│   │   └── file.txt
│   └── .folder                  # Folder marker files
├── audio-sessions/{userId}/     # Audio recording sessions
│   └── {sessionId}/
│       └── chunk-{N}.webm
├── claude-memory/
│   ├── public/                  # Shared memories
│   └── {userId}/                # User-private memories
└── (CloudFront static assets)   # index.html, audio.html, etc.
```

## UI Source Files (ui-source/)

**index.html** - Dashboard with File Manager
- Login via Cognito OAuth (redirects to hosted UI)
- File browser with upload/download/rename/move/delete
- Folder navigation with breadcrumbs
- Memory viewer (public and user-scoped Claude memories)

**audio.html** - Real-time Audio Recorder
- Records audio in chunks (configurable timeslice)
- Optionally connects to WhisperLive for live transcription
- Uploads chunks to S3 via presigned URLs
- IndexedDB persistence for offline replay
- Word-level timestamp highlighting (karaoke mode)

**app.js.template** - Configuration template
- Gets deployed to `cognito-stack/web/app.js`
- Deployment scripts inject real values

**callback.html** - OAuth callback handler
- Processes Cognito OAuth redirect
- Extracts tokens from URL fragment
- Stores in localStorage

## WhisperLive Integration (Optional)

If transcription is enabled, WhisperLive runs on a separate GPU EC2 instance.

### Patches Required
WhisperLive must be patched to enable word-level timestamps. See `scripts/WHISPERLIVE-PATCHES.md` for details:

1. Enable `word_timestamps=True` in faster-whisper transcribe call
2. Modify `format_segment()` to include word data
3. Override `update_segments()` to extract and pass words

### Word Timestamp Format
```javascript
{
  "segments": [{
    "start": 0.0,
    "end": 5.2,
    "text": "Hello world",
    "words": [
      {"word": "Hello", "start": 0.0, "end": 0.5},
      {"word": "world", "start": 0.8, "end": 1.2}
    ]
  }]
}
```

**CRITICAL**: Word timestamps from WhisperLive are segment-relative, not absolute. UI must convert:
```javascript
const absoluteStart = segment.start + word.start;
const absoluteEnd = segment.start + word.end;
```

## Claude Code Skills (.claude/skills/)

### clouddrive-download
AWS CLI-based file download for development.
```bash
cd .claude/skills/clouddrive-download
./download.sh "filename.png"
./file-search.sh --list
```

Requires AWS credentials with S3 read access. Uses COGNITO_S3_BUCKET from .env.

### clouddrive-browser
Playwright-based browser automation for E2E testing.
```bash
cd .claude/skills/clouddrive-browser
npm install
./test-login.sh
./test-workflow.sh
```

Requires COGNITO_CLOUDFRONT_URL, CLOUDDRIVE_TEST_EMAIL, CLOUDDRIVE_TEST_PASSWORD in .env.

Auto-prompts for credentials on first run and saves to .env.

## Deployment Workflow

### Automated Deployment (Recommended)

The repository includes numbered deployment scripts (000-999) that automate the entire setup.

**IMPORTANT: WhisperLive uses EDGE BOX architecture for security**
- Edge box = Public-facing HTTPS proxy (Caddy)
- GPU = Internal-only WhisperLive server
- Clients connect to edge box, which proxies to GPU

```bash
# 1. Configure environment (creates .env)
./scripts/005-setup-configuration.sh
# IMPORTANT: Set WHISPERLIVE_WS_URL to edge box IP, NOT GPU IP
# Example: WHISPERLIVE_WS_URL=wss://3.16.164.228/ws (edge box)

# 2. Deploy Cognito backend
./scripts/410-questions-setup-cognito-s3-lambda.sh  # Prepares cognito-stack directory
./scripts/420-deploy-cognito-stack.sh              # Deploys serverless backend (~10-15 min)

# 3. Setup WhisperLive with Edge Box Proxy
# NOTE: Script 305 must run ON the edge box instance itself
# SSH to edge box, then run:
./scripts/305-setup-whisperlive-edge.sh            # Setup Caddy proxy on edge box

# 4. Lock down security (run from ANY instance with .env configured)
./scripts/030-configure-gpu-security.sh            # Lock GPU to edge-box-only access
./scripts/031-configure-edge-box-security.sh       # Configure edge box client allowlist

# 5. Deploy UI
./scripts/425-deploy-recorder-ui.sh                # Deploy UI files with WebSocket config

# 6. Create test user
./scripts/430-create-cognito-user.sh
```

**Deployment Order is Critical:**
1. Backend first (410, 420) - creates infrastructure
2. Edge proxy (305) - must run ON edge box
3. Security lockdown (030, 031) - configures firewalls
4. UI deployment (425) - injects correct WebSocket URL
5. User creation (430) - creates test account

**Script Categories:**
- **000-099**: Initial setup and configuration
- **300-399**: WhisperLive Edge/GPU setup
- **400-499**: Cognito/S3/Lambda backend deployment

**Key Scripts Explained:**

**005-setup-configuration.sh**
- Interactive wizard that creates/updates .env
- Prompts for AWS region, service name, bucket names
- Validates AWS credentials

**410-questions-setup-cognito-s3-lambda.sh**
- Prepares cognito-stack directory structure
- Configures serverless.yml with .env values
- Validates prerequisites for deployment

**420-deploy-cognito-stack.sh**
- Runs `serverless deploy` to create CloudFormation stack
- Retrieves deployment outputs (User Pool ID, CloudFront URL, etc.)
- Automatically updates .env with deployment values
- Creates app.js from template with injected config
- Uploads initial web files to S3
- Invalidates CloudFront cache

**425-deploy-recorder-ui.sh**
- Copies UI files from ui-source/ to cognito-stack/web/
- Replaces ALL placeholders in templates with .env values
- Adds logout button and authentication checks to audio.html
- Uploads updated files to S3
- Invalidates CloudFront cache

**430-create-cognito-user.sh**
- Creates test user in Cognito User Pool
- Sets permanent password (no force change)
- Useful for testing authentication flow

**Script Library System:**
All deployment scripts use shared functions from `scripts/lib/common-functions.sh`:
- `load_environment` - Loads and validates .env variables
- `log_info`, `log_success`, `log_warn`, `log_error` - Colored output
- `validate_required_vars` - Ensures required env vars are set
- Scripts auto-detect repo root even when run from symlinks or subdirectories
- All scripts log output to `logs/` directory with timestamps

### Manual Deployment (Alternative)

1. **Configure**: Copy `.env.example` to `.env` and fill in values
2. **Deploy Backend**: `cd cognito-stack && serverless deploy`
3. **Note Outputs**: CloudFront URL, User Pool ID, Client ID, etc.
4. **Update .env**: Add deployment outputs to .env
5. **Deploy UI**: Deployment scripts copy ui-source/ → cognito-stack/web/ with value injection
6. **(Optional) Deploy GPU**: Separate EC2 instance for WhisperLive

## Testing

### Manual UI Testing
```bash
# Using browser automation skill
cd .claude/skills/clouddrive-browser
./test-login.sh           # Test Cognito OAuth flow
./test-upload.sh file.pdf # Test file upload
./test-workflow.sh        # Full E2E test
```

### Manual API Testing
```bash
# Get auth token (via browser login, extract from localStorage)
TOKEN="eyJraWQ..."

# List files
curl -H "Authorization: Bearer $TOKEN" \
  https://xxx.execute-api.region.amazonaws.com/dev/api/s3/list

# Upload file (two-step: get presigned URL, then PUT)
curl -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"fileName":"test.txt","contentType":"text/plain","fileSize":100}' \
  https://xxx.execute-api.region.amazonaws.com/dev/api/s3/upload
```

### Python Transcription Script
```bash
# Requires WHISPERLIVE_HOST in .env
python transcribe-file.py /path/to/audio.webm
```

## Authentication Flow

1. User clicks "Login" → Redirects to Cognito hosted UI
2. User enters email/password → Cognito validates
3. OAuth callback → `callback.html` extracts tokens from URL fragment
4. Tokens stored in localStorage:
   - `CognitoIdentityServiceProvider.{clientId}.LastAuthUser`
   - `CognitoIdentityServiceProvider.{clientId}.{username}.idToken`
   - `CognitoIdentityServiceProvider.{clientId}.{username}.accessToken`
5. Subsequent API calls include `Authorization: Bearer {idToken}`
6. Lambda functions validate token via Cognito authorizer
7. User ID extracted from token claims (`sub` field) for S3 scoping

## Common Development Commands

### Deployment Scripts
```bash
# Full deployment from scratch
./scripts/005-setup-configuration.sh           # Interactive .env setup
./scripts/410-questions-setup-cognito-s3-lambda.sh  # Prepare cognito-stack
./scripts/420-deploy-cognito-stack.sh          # Deploy backend (10-15 min)
./scripts/425-deploy-recorder-ui.sh            # Deploy UI
./scripts/430-create-cognito-user.sh           # Create test user

# Update UI after making changes to ui-source/
./scripts/425-deploy-recorder-ui.sh

# View deployment logs
ls -lart logs/                                  # All script logs with timestamps
tail -f logs/420-deploy-cognito-stack-*.log   # Follow deployment progress
```

### Serverless
```bash
cd cognito-stack
serverless deploy                    # Deploy all
serverless deploy function -f listS3Files  # Deploy single function
serverless logs -f listS3Files       # View function logs
serverless invoke -f listS3Files     # Test function
serverless remove                     # Destroy stack
```

### Local UI Development
```bash
# Edit template files (NOT the generated files!)
vim ui-source/app.js.template        # Source of truth
vim ui-source/audio.html.template    # Source of truth

# Deploy changes
./scripts/425-deploy-recorder-ui.sh  # Processes templates and uploads to S3

# Or use CloudFront URL directly (recommended for testing)
open $COGNITO_CLOUDFRONT_URL
```

### Deployment Value Injection
Deployment scripts (420, 425) replace placeholders in templates automatically:
```bash
# Scripts use this pattern internally
sed -i "s|YOUR_USER_POOL_CLIENT_ID|$COGNITO_USER_POOL_CLIENT_ID|g" app.js
sed -i "s|TO_BE_REPLACED_REGION|$AWS_REGION|g" audio.html

# DO NOT run these manually - let deployment scripts handle it
```

## Security Principles

1. **No hardcoded secrets** - All in .env (gitignored)
2. **No hardcoded deployment values** - Use environment variables or placeholders
3. **User-scoped storage** - All S3 keys prefixed with `users/{userId}/`
4. **Token validation** - Cognito authorizer on all API endpoints
5. **Presigned URLs** - Short-lived (15min) for uploads/downloads
6. **OAuth/SRP** - No password transmission over HTTP

## Git Workflow

`.gitignore` includes:
- `.env` (local secrets)
- `cognito-stack/web/` (deployment artifacts - regenerated from ui-source/)
- `node_modules/`
- `logs/` (script execution logs)
- `clouddrive-downloads/` (downloaded files from skill)
- `browser-screenshots/`, `browser-downloads/` (browser skill artifacts)

**CRITICAL - Source of Truth:**
- **ALWAYS edit**: `ui-source/*.template` files
- **NEVER edit**: `cognito-stack/web/*` files (auto-generated, not tracked in git)
- **Reason**: Deployment scripts regenerate `cognito-stack/web/` from templates on every deployment
- **To update UI**: Edit template → Run `./scripts/425-deploy-recorder-ui.sh` → Changes deployed to S3

**Git Status Notes:**
If you see modified files like `scripts/420-deploy-cognito-stack.sh` or `ui-source/audio.html`, these are legitimate source files that should be committed (unlike `cognito-stack/web/` which should never be committed).

## Troubleshooting

### "Token has expired"
Tokens expire after 1 hour. Re-login via UI.

### "No files found" in File Manager
- Check S3 bucket directly: `aws s3 ls s3://$COGNITO_S3_BUCKET/users/`
- Verify user ID matches token sub: Decode JWT at jwt.io
- Check CORS in API Gateway

### WhisperLive Connection Failed
- Verify WHISPERLIVE_WS_URL in .env
- Check GPU instance security group allows WebSocket (port 9090)
- Ensure WhisperLive patches applied
- Test direct connection: `wscat -c ws://{ip}:9090`

### Deployment Placeholders Not Replaced
- Check deployment script replaces ALL placeholders
- Verify app.js in cognito-stack/web/ has real values
- Clear browser cache to reload app.js

### CORS Errors
API Gateway must have CORS enabled:
```yaml
events:
  - http:
      cors: true
```

### "Missing required environment variables"
All scripts validate .env variables. Run `cp .env.example .env` and fill in required values.

### WhisperLive Transcription Not Working

**Symptom:** Audio records and uploads to S3, but no live transcription appears.

**Browser console shows:**
```
WebSocket connection to 'wss://your-edge-box.com/ws' failed
⚠️ window.config not found
```

**Common causes:**

1. **Wrong WebSocket URL in .env**
   - Check: `echo $WHISPERLIVE_WS_URL`
   - Should point to **edge box** (e.g., `wss://3.16.164.228/ws`)
   - NOT GPU directly (e.g., ~~`wss://3.18.106.129/ws`~~)
   - Fix: Update `.env` and redeploy with `./scripts/425-deploy-recorder-ui.sh`

2. **CloudFront serving old cached version**
   - Do hard refresh in browser: Ctrl+Shift+R (Cmd+Shift+R on Mac)
   - Wait 1-2 minutes after deployment for cache invalidation
   - Check: View source and look for `window.config.whisperLiveWsUrl`

3. **Edge box proxy not running**
   - Check: `docker ps | grep whisperlive-edge`
   - Should show: `whisperlive-edge   Up X minutes`
   - Fix: Run `./scripts/305-setup-whisperlive-edge.sh` ON edge box
   - Verify: `curl -k https://<edge-box-ip>/healthz` should return "OK"

4. **GPU not accessible from edge box**
   - From edge box: `curl http://<gpu-ip>:9090`
   - Should see: "Failed to open a WebSocket connection: missing Connection header"
   - If timeout: Check scripts 030/031 didn't block edge box IP
   - Fix: Re-run `./scripts/030-configure-gpu-security.sh`

5. **WhisperLive not running on GPU**
   - SSH to GPU: `ssh ubuntu@<gpu-ip>`
   - Check process: `ps aux | grep whisper`
   - Check service: `systemctl status whisperlive`
   - Logs: `journalctl -u whisperlive -f`

**Quick verification checklist:**
```bash
# 1. Check deployed WebSocket URL
curl -s https://de70by05kq678.cloudfront.net/app.js | grep whisperLiveWsUrl
# Should show: whisperLiveWsUrl: 'wss://<EDGE_BOX_IP>/ws'

# 2. Check edge proxy is running
docker ps --filter name=whisperlive-edge

# 3. Check edge box can reach GPU
curl http://<GPU_IP>:9090
# Should get WebSocket error (proves it's running)

# 4. Test edge box proxy
curl -k https://<EDGE_BOX_IP>/healthz
# Should return: OK
```
