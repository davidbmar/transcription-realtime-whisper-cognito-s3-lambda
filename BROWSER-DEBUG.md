# Browser Transcription Debugging Guide

## Problem: No transcription text appearing in browser

The automated test (script 325) works perfectly, but the browser isn't showing transcriptions.

## Quick Diagnosis

### Step 1: Hard Refresh the Browser

**CRITICAL**: Clear the browser cache to load the latest code.

```
Chrome/Edge: Ctrl + Shift + R (Windows) or Cmd + Shift + R (Mac)
Firefox: Ctrl + Shift + Delete (clear cache) then F5
Safari: Cmd + Option + E (clear cache) then Cmd + R
```

### Step 2: Open Browser Console

Press `F12` or right-click → Inspect → Console tab

### Step 3: Check for Errors

Look for these specific messages:

**✅ GOOD - WebSocket Connected:**
```
🔌 Connecting to: wss://3.16.164.228/ws
✅ WhisperLive WebSocket connected
```

**❌ BAD - Connection Failed:**
```
❌ WhisperLive WebSocket error
WebSocket connection to 'wss://...' failed
```

**❌ BAD - Configuration Missing:**
```
⚠️ window.config not found
```

### Step 4: Check Network Tab

1. Open F12 → Network tab
2. Filter by "WS" (WebSocket)
3. Start recording
4. Click "Start Recording" in the browser
5. Look for connection to `wss://3.16.164.228/ws`

**Status Codes:**
- `101 Switching Protocols` = ✅ Good (WebSocket connected)
- `400 Bad Request` = ❌ Caddy proxy issue
- `426 Upgrade Required` = ❌ Header forwarding issue
- `1006 Connection Closed` = ❌ SSL certificate not accepted

### Step 5: Accept SSL Certificate

If you see SSL errors, you MUST accept the self-signed certificate:

1. Open new tab: `https://3.16.164.228/healthz`
2. Click "Advanced" → "Proceed to 3.16.164.228 (unsafe)"
3. Should see "OK"
4. Go back to audio recorder and hard refresh

## Common Issues

### Issue 1: Old Cached JavaScript

**Symptom**: No WebSocket connection attempts in console

**Fix**:
```bash
# Clear ALL browser data for the site
# Chrome: Settings → Privacy → Clear browsing data → Cached images/files
# Or use incognito/private mode
```

### Issue 2: WebSocket URL Not Configured

**Symptom**: Console shows `⚠️ window.config not found`

**Fix**:
```bash
# Redeploy UI
./scripts/425-deploy-recorder-ui.sh
```

### Issue 3: SSL Certificate Not Accepted

**Symptom**: WebSocket error 1006, or "Certificate invalid"

**Fix**:
Visit `https://3.16.164.228/healthz` and accept certificate

### Issue 4: WhisperLive Not Running on GPU

**Symptom**: WebSocket connects but no transcriptions

**Fix**:
```bash
# Check GPU WhisperLive status
ssh -i ~/.ssh/dbm-oct18-2025.pem ubuntu@18.223.22.152 'sudo systemctl status whisperlive'

# View logs
ssh -i ~/.ssh/dbm-oct18-2025.pem ubuntu@18.223.22.152 'sudo journalctl -u whisperlive -f'
```

### Issue 5: Microphone Not Working

**Symptom**: Recording starts but no audio chunks

**Fix**:
- Check browser permissions (click lock icon in address bar)
- Grant microphone access
- Try different browser (Chrome works best)

## Verification Checklist

Run through this checklist:

- [ ] Hard refresh browser (Ctrl+Shift+R)
- [ ] Browser console open (F12)
- [ ] SSL certificate accepted (`https://3.16.164.228/healthz`)
- [ ] WebSocket connection shows `101 Switching Protocols` in Network tab
- [ ] Console shows "WhisperLive WebSocket connected"
- [ ] Microphone permission granted
- [ ] Recording button clicked
- [ ] Audio chunks uploading (check console for "Uploading chunk...")
- [ ] GPU WhisperLive running (`systemctl status whisperlive`)

## Expected Console Output (Working)

When everything is working correctly, you should see:

```
🔌 Connecting to: wss://3.16.164.228/ws
✅ WhisperLive WebSocket connected
🎤 Recording started, session: session_2025-11-09T20_00_00_000Z
📤 Uploading chunk 1 to S3...
✅ Chunk 1 uploaded
📝 Transcription: Hello world
📝 Transcription: This is a test
```

## Manual Test

If browser still doesn't work, test WebSocket directly:

```bash
# From edge box or local machine
python3 << 'EOF'
import asyncio
import websockets
import ssl

async def test():
    ssl_context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ssl_context.check_hostname = False
    ssl_context.verify_mode = ssl.CERT_NONE

    async with websockets.connect('wss://3.16.164.228/ws', ssl=ssl_context) as ws:
        print("✅ Connected!")
        await ws.send('{"uid":"test","language":"en","task":"transcribe","model":"small.en"}')
        response = await ws.recv()
        print(f"Response: {response}")

asyncio.run(test())
EOF
```

## Still Not Working?

Check these advanced issues:

1. **CloudFront Cache**: Wait 5-10 minutes for cache invalidation
2. **Browser Extensions**: Disable ad blockers / privacy extensions
3. **Network Firewall**: Check if WebSocket traffic is blocked
4. **Multiple Tabs**: Close all other audio recorder tabs
5. **Browser Version**: Update to latest Chrome/Edge

## Get Help

If still stuck, provide:

1. Browser console screenshot (F12)
2. Network tab showing WebSocket connection
3. Output of: `docker logs whisperlive-edge --tail 50`
4. Output of: `ssh gpu 'sudo journalctl -u whisperlive --since "5 min ago"'`
