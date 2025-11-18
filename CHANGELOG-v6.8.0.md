# Changelog v6.8.0 - Enhanced Recording Diagnostics & Corruption Prevention

**Date:** 2025-11-18
**Version:** 6.8.0
**Previous Version:** 6.7.0

## Summary

This release adds comprehensive logging and corruption prevention mechanisms to address audio chunk corruption issues discovered during batch transcription testing. Analysis of corrupted chunks revealed that MediaRecorder produces incomplete 5-byte files when the page is backgrounded, despite the Wake Lock API being active.

## Root Cause Analysis

**Issue:** 11 out of 379 audio chunks (2.9%) were corrupted during a 31-minute recording
- **Corrupt chunk pattern:** Chunks 351-378 (final 2.5 minutes of recording)
- **File sizes:** 5 bytes (incomplete WebM header only)
- **Timing:** Recording started at 15:07 UTC, Wake Lock deployed at 04:44 UTC (active during recording)
- **Cause:** Wake Lock API can be released by the system, and MediaRecorder continues producing malformed blobs when page is backgrounded

**Example corrupt chunk:**
```
Chunk 351: 5 bytes  (hex: 1c53 bb6b 80)  <- Just WebM header start
Chunk 350: 140KB    (hex: 1a45 dfa3 ...)  <- Valid full chunk
```

## Changes Implemented

### 1. Minimum Chunk Size Validation
**File:** `ui-source/audio.html.template` (lines 1985-1995)

**What:** Reject audio blobs smaller than 1KB before uploading to S3

**Why:** Prevents uploading incomplete/corrupted chunks that will fail transcription

**Impact:**
- Saves batch transcription retry time (11 chunks × 3 retries = 33 failed attempts avoided)
- Makes recording gaps immediately visible in logs
- Prevents S3 storage waste on corrupt files

```javascript
const MIN_VALID_CHUNK_SIZE = 1000; // 1KB minimum for ~5 seconds of audio
if (ev.data.size < MIN_VALID_CHUNK_SIZE){
  log(`[Recorder] ERROR: Blob too small (${ev.data.size} bytes) - likely corrupted, skipping upload`);
  return; // Don't upload corrupt chunks to S3
}
```

### 2. Blob Size Logging
**File:** `ui-source/audio.html.template` (line 1986)

**What:** Log every received blob size

**Why:** Helps diagnose corruption issues in real-time

**Example output:**
```
[Recorder] Received blob: 149234 bytes
[Recorder] Received blob: 5 bytes
[Recorder] ERROR: Blob too small (5 bytes) - likely corrupted, skipping upload
```

### 3. Page Visibility Detection
**File:** `ui-source/audio.html.template` (lines 3468-3492)

**What:** Detect and log when page is hidden/shown during recording

**Why:** Helps correlate corruption with backgrounding events

**Example output:**
```
[Visibility] Page is now HIDDEN
[Visibility] WARNING: Page hidden during active recording!
[Visibility] Audio chunks may be corrupted while page is in background
[Visibility] Keep this tab in foreground for best results
```

### 4. Enhanced Wake Lock Monitoring
**File:** `ui-source/audio.html.template` (lines 3014-3028)

**What:**
- Detect when Wake Lock is released by system
- Attempt automatic re-acquisition
- Warn if lost during recording

**Why:** Wake Lock can be revoked by battery saver, app switching, or system policies

**Example output:**
```
[WakeLock] WARNING: Wake lock was RELEASED by system!
[WakeLock] CRITICAL: Wake lock lost during active recording - chunks may be corrupted
[WakeLock] Attempting to re-acquire wake lock...
[WakeLock] Successfully re-acquired wake lock
```

### 5. MediaRecorder Event Logging
**File:** `ui-source/audio.html.template` (lines 2013-2028)

**What:** Log MediaRecorder state changes (start, pause, resume, error)

**Why:** Helps diagnose unexpected recorder behavior

**Example output:**
```
[Recorder] MediaRecorder started
[Recorder] WARNING: MediaRecorder paused unexpectedly
[Recorder] ERROR: NotSupportedError - The operation is not supported
```

## Files Modified

1. **ui-source/audio.html.template** (v6.7.0 → v6.8.0)
   - Updated version in header comment
   - Enhanced `rec.ondataavailable` handler (lines 1983-2002)
   - Added MediaRecorder event handlers (lines 2013-2028)
   - Enhanced Wake Lock monitoring (lines 3014-3028)
   - Added Page Visibility detection (lines 3468-3492)

## Deployment

```bash
./scripts/425-deploy-recorder-ui.sh
```

## Testing Recommendations

1. **Test minimum chunk size threshold:**
   - Start recording
   - Background the app immediately
   - Check logs for "Blob too small" messages
   - Verify corrupt chunks are NOT uploaded to S3

2. **Test visibility detection:**
   - Start recording
   - Switch to another tab/app
   - Return to recorder tab
   - Verify visibility warnings in logs

3. **Test Wake Lock monitoring:**
   - Start recording on mobile device
   - Enable battery saver mode
   - Check if Wake Lock release is detected and re-acquired

## Impact on Previous Issues

**Batch Transcription Run (2025-11-18 16:00-16:24):**
- **Before v6.8.0:** 11 corrupt chunks uploaded → 3 retry attempts → 24 minutes total runtime → $0.21 cost
- **After v6.8.0:** 11 corrupt chunks rejected → 368 successful chunks → ~10 minutes runtime → ~$0.09 cost (estimate)

**Savings per corrupted recording:**
- ~14 minutes GPU time
- ~$0.12 per session
- Better user experience (clear gap vs. failed transcription)

## Known Limitations

1. **Wake Lock can still be revoked:** System can override Wake Lock API
2. **No automatic pause/resume:** Recording continues when backgrounded (may produce corrupt chunks)
3. **Threshold may need tuning:** 1KB minimum may be too low/high for different audio codecs

## Future Enhancements (Not in v6.8.0)

1. Auto-pause recording when page goes hidden
2. User notification when Wake Lock is lost
3. Configurable minimum chunk size
4. Automatic retry for small chunks before rejecting
5. Upload chunk size metrics to CloudWatch

## References

- Issue discovered: 2025-11-18 batch transcription run
- Corrupt chunk analysis: chunks 351-378 from session `2025-11-18T15_07_04_017Z`
- GPU cost log: `/var/log/gpu-cost.log` entry `2025-11-18T16:00:34Z`
