# WhisperLive Live Transcription - Deployment Fixes Summary

**Date:** November 1, 2025
**Status:** ✅ ALL ISSUES RESOLVED

## Original Problem

Live transcription was not working. Audio was recording and uploading to S3 successfully, but no transcription appeared in the UI.

## Root Causes Identified

1. **Wrong IP Configuration**
   - `.env` configured to point to GPU directly (`wss://3.18.106.129/ws`)
   - Should point to edge box proxy (`wss://3.16.164.228/ws`)
   - Scripts 030/031 enforce edge box architecture, but config was for direct access

2. **JavaScript Config Conflict**
   - Both `app.js` and `audio.html` declared `const config = {...}`
   - Caused "Identifier 'config' has already been declared" error
   - Browser couldn't load configuration properly

3. **Missing Config Import**
   - `audio.html` didn't load `<script src="app.js"></script>`
   - `window.config` was undefined
   - Fell back to hardcoded `wss://your-edge-box.com/ws`

4. **Edge Box Proxy Not Configured**
   - Script 305 hadn't been run
   - Caddy reverse proxy wasn't set up
   - No HTTPS → WebSocket proxying to GPU

5. **Security Groups Misconfigured**
   - Scripts 030/031 not run properly
   - GPU exposed to internet instead of edge-box-only

## Fixes Applied

### 1. Fixed JavaScript Config Conflict
**File:** `ui-source/app.js.template`
```javascript
// Before:
const config = { ... }

// After:
window.config = { ... }
```

### 2. Added Config Import
**File:** `ui-source/audio.html`
```html
<head>
  ...
  <script src="app.js"></script>  <!-- ADDED -->
  <style>
```

### 3. Updated .env Configuration
**File:** `.env`
```bash
# Before:
WHISPERLIVE_WS_URL=wss://3.18.106.129/ws  # GPU direct
EDGE_BOX_DNS=3.18.106.129

# After:
WHISPERLIVE_WS_URL=wss://3.16.164.228/ws  # Edge box proxy
EDGE_BOX_DNS=3.16.164.228
```

### 4. Deployed Edge Box Proxy
```bash
./scripts/305-setup-whisperlive-edge.sh
```
Result: Caddy reverse proxy running on port 443

### 5. Configured Security
```bash
./scripts/030-configure-gpu-security.sh    # Lock GPU to edge-box-only
./scripts/031-configure-edge-box-security.sh  # Configure client access
```

### 6. Redeployed UI
```bash
./scripts/425-deploy-recorder-ui.sh
```
Result: CloudFront serving correct WebSocket URL

## Documentation Updates

### .env.example
Added detailed comments explaining:
- Edge box vs GPU IP configuration
- Architecture: Client → Edge Box → GPU
- Example configurations with real IPs

### CLAUDE.md (NEW)
Created comprehensive deployment guide:
- Complete deployment sequence
- Script execution order
- Edge box architecture explanation
- Troubleshooting section for common issues

## Working Architecture

```
Browser Client
    ↓
wss://3.16.164.228/ws (Edge Box - HTTPS/TLS)
    ↓
Caddy Reverse Proxy
    ↓
ws://3.18.106.129:9090 (GPU - Internal Only)
    ↓
WhisperLive Server
```

## Fresh Deployment Process

Anyone can now deploy from scratch:

```bash
# 1. Configure environment
./scripts/005-setup-configuration.sh
# IMPORTANT: Set WHISPERLIVE_WS_URL to edge box IP

# 2. Deploy backend
./scripts/410-questions-setup-cognito-s3-lambda.sh
./scripts/420-deploy-cognito-stack.sh  # ~10-15 min

# 3. Setup edge proxy (ON edge box)
./scripts/305-setup-whisperlive-edge.sh

# 4. Configure security
./scripts/030-configure-gpu-security.sh
./scripts/031-configure-edge-box-security.sh

# 5. Deploy UI
./scripts/425-deploy-recorder-ui.sh

# 6. Create test user
./scripts/430-create-cognito-user.sh
```

## Testing

1. Visit: https://de70by05kq678.cloudfront.net/audio.html
2. Hard refresh: Ctrl+Shift+R (Cmd+Shift+R)
3. Start recording
4. Browser console should show:
   - ✅ WhisperLive WebSocket connected
   - ✅ Sending WhisperLive Config
   - ✅ WhisperLive ready
   - ✅ Live transcription appears!

## Committed Changes

**Commit:** b6d7217

**Files Modified:**
- `ui-source/app.js.template` - Changed to window.config
- `ui-source/audio.html` - Added app.js import
- `.env.example` - Added edge box documentation
- `CLAUDE.md` - Created deployment guide (NEW)

## Verification Commands

```bash
# 1. Check deployed WebSocket URL
curl -s https://de70by05kq678.cloudfront.net/app.js | grep whisperLiveWsUrl
# Should show: whisperLiveWsUrl: 'wss://3.16.164.228/ws'

# 2. Check edge proxy running
docker ps --filter name=whisperlive-edge

# 3. Test edge box health
curl -k https://3.16.164.228/healthz
# Should return: OK

# 4. Test GPU accessible from edge box
curl http://3.18.106.129:9090
# Should get WebSocket error (proves it's running)
```

## Security Improvements

✅ GPU not exposed to internet (edge-box-only access)
✅ All client traffic over TLS/HTTPS
✅ Client IP allowlist on edge box
✅ Proper reverse proxy architecture

## Status

**Current State:** ✅ FULLY WORKING
**Deployment:** ✅ REPRODUCIBLE FROM SCRIPTS
**Documentation:** ✅ COMPLETE
**Security:** ✅ PROPERLY CONFIGURED

Live transcription now works end-to-end with secure edge box architecture!
