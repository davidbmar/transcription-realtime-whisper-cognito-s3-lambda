# UI Deployment Guide

## Overview

The browser UI files are versioned in **this main repository** and deployed via scripts. When you update the UI, you must copy files from the dev location to the main repo for deployment.

## File Locations

### Development (whisper-live-test repo)
```
/home/ubuntu/event-b/whisper-live-test/
├── site/
│   └── index.html          # UI development happens here
├── Caddyfile               # Reverse proxy config
├── docker-compose.yml      # Container definition
└── .env-http               # Environment-specific (not committed)
```

### Production (main repo for deployment)
```
/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/
├── site/
│   └── index.html          # COPY from dev → here for deployment
├── Caddyfile               # COPY from dev → here
├── docker-compose.yml      # COPY from dev → here
└── .env-http               # Symlink (created by scripts)
```

## Updating UI for Deployment

After making UI changes in `whisper-live-test`, you must copy them to the main repo:

```bash
cd /home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4

# Copy updated files
cp /home/ubuntu/event-b/whisper-live-test/site/index.html site/
cp /home/ubuntu/event-b/whisper-live-test/Caddyfile .
cp /home/ubuntu/event-b/whisper-live-test/docker-compose.yml .

# Commit and push
git add site/index.html Caddyfile docker-compose.yml
git commit -m "Update UI: [describe changes]"
git push
```

## Deployment Scripts

### 305-setup-whisperlive-edge.sh
Initial edge proxy setup:
1. Creates edge directory structure
2. Copies files from `PROJECT_ROOT/site/` to edge directory
3. Creates `.env-http` with current GPU IP
4. Creates symlink: `PROJECT_ROOT/.env-http` → `whisper-live-test/.env-http`
5. Starts Caddy container

### 320-update-edge-clients.sh
Updates browser clients:
1. Copies files from `PROJECT_ROOT/site/` to edge directory
2. Restarts Caddy to pick up changes
3. Verifies deployment

### 220-startup-restore.sh
GPU startup with automatic IP updates:
1. Starts GPU instance
2. Updates `.env-http` with new GPU IP
3. Recreates Caddy container with new IP
4. Auto-restarts WhisperLive

## Fresh Deployment Flow

When someone clones the repo and deploys:

```bash
# 1. Clone main repo
git clone https://github.com/davidbmar/transcription-realtime-whisper-cognito-s3-lambda.git
cd transcription-realtime-whisper-cognito-s3-lambda

# 2. Setup edge proxy
./scripts/305-setup-whisperlive-edge.sh
```

**What happens:**
- ✅ Gets `site/index.html`, `Caddyfile`, `docker-compose.yml` from repo
- ✅ Script copies them to `/home/ubuntu/event-b/whisper-live-test/`
- ✅ Script creates `.env-http` with current environment
- ✅ Caddy serves latest UI

## Why Not Use Symlinks?

**Problem with symlinks:**
- Symlinks pointed to `whisper-live-test` repo (separate repo)
- Fresh checkouts don't have `whisper-live-test` content
- Deployment scripts fail or use placeholder files

**Solution:**
- Store actual files in main repo
- Deployment scripts copy from main repo
- Always get latest version on fresh deployments

## Current UI Features

**Version**: v5.2.0 (2025-10-28)

**Features:**
- ✅ Real-time transcription via WhisperLive
- ✅ Word-level karaoke highlighting (yellow)
- ✅ Split transcription: partial (top) + completed (scrolling)
- ✅ Scrollable sections with auto-scroll to newest
- ✅ Compact single-row controls
- ✅ Waveform visualization (60px height)
- ✅ IndexedDB storage with persistence

**Layout:**
```
┌─────────────────────────────────┐
│ Controls (1 row, compact)       │
├─────────────────────────────────┤
│ Live Recording                  │
│ ├─ Waveform (60px)             │
│ ├─ Partial (50px, visible)     │ ← Current
│ └─ Completed (scrolls) ▼       │ ← History
├─────────────────────────────────┤
│ Previous Chunks (400px scroll) │
│ •••                             │
└─────────────────────────────────┘
```

## Troubleshooting

### UI changes not appearing after deployment

**Cause**: Forgot to copy files from dev to main repo

**Fix**:
```bash
# Copy files
cp /home/ubuntu/event-b/whisper-live-test/site/index.html site/
git add site/index.html
git commit -m "Update UI"
git push

# Re-deploy
./scripts/320-update-edge-clients.sh
```

### Browser cache showing old version

**Fix**: Hard refresh in browser (Ctrl+Shift+R or Cmd+Shift+R)

### Docker container not picking up changes

**Fix**: Restart container
```bash
cd /home/ubuntu/event-b/whisper-live-test
docker compose down
docker compose up -d
```

## Related Documentation

- `docs/EDGE-PROXY-SETUP.md` - Edge proxy architecture and IP management
- `scripts/WHISPERLIVE-PATCHES.md` - Server-side patches for word timestamps
- `site/index.html` - UI source code with inline documentation

## Version History

- **2025-10-28**: Converted symlinks to actual files for deployment
- **2025-10-27**: Split transcription layout, compact controls
- **2025-10-27**: Word-level karaoke highlighting
- **2025-10-27**: Initial edge proxy with WhisperLive integration
