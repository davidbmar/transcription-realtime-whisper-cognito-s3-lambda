# Quick Start: Phase 2 Implementation

**Previous:** Phase 1 IndexedDB Layer ✅ Complete
**Next:** Phase 2 Upload Queue with Retry Logic

---

## What You Need to Build

Create `ui-source/lib/upload-queue.js` - An upload queue manager that:

1. **Manages concurrent uploads** (max 3 at a time)
2. **Implements retry logic** with exponential backoff
3. **Integrates with AudioStorage** (already built)
4. **Handles network failures** gracefully
5. **Emits progress events** for UI updates

---

## Quick Implementation Template

```javascript
// ui-source/lib/upload-queue.js

class UploadQueue {
  constructor(audioStorage, options = {}) {
    this.storage = audioStorage;
    this.maxConcurrent = options.maxConcurrent || 3;
    this.maxRetries = options.maxRetries || 5;
    this.baseDelay = options.baseDelay || 1000; // 1 second
    this.maxDelay = options.maxDelay || 60000;  // 60 seconds

    this.queue = [];           // Pending uploads
    this.active = new Map();   // Currently uploading
    this.paused = false;

    this.eventListeners = new Map();
  }

  // Core Methods to Implement:

  async enqueue(sessionId, chunkNumber) {
    // Add chunk to upload queue
    // Auto-start processing if not at max concurrent
  }

  async processQueue() {
    // Main loop: process queued uploads
    // Respect maxConcurrent limit
  }

  async uploadChunk(sessionId, chunkNumber) {
    // 1. Get chunk from storage
    // 2. Get S3 presigned URL
    // 3. Upload with fetch()
    // 4. Update status in storage
    // 5. Handle errors with retry
  }

  async retryChunk(sessionId, chunkNumber, attempt) {
    // Exponential backoff calculation
    // Check attempt < maxRetries
    // Re-enqueue with delay
  }

  pause() {
    // Stop processing queue
  }

  resume() {
    // Resume processing queue
  }

  // Event system for UI updates
  on(event, handler) {
    // 'upload-start', 'upload-progress', 'upload-complete', 'upload-failed'
  }

  emit(event, data) {
    // Trigger event handlers
  }
}
```

---

## Integration Points

### 1. Get S3 Upload URL

```javascript
// Use existing API endpoint
const response = await fetch(
  `${API_ENDPOINT}/audio/upload-chunk-url`,
  {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${idToken}`,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({
      sessionId: sessionId,
      chunkNumber: chunkNumber,
      mimeType: chunk.mimeType
    })
  }
);

const { uploadUrl, s3Key } = await response.json();
```

### 2. Upload to S3

```javascript
// Upload with progress tracking
const response = await fetch(uploadUrl, {
  method: 'PUT',
  body: chunk.audioBlob,
  headers: {
    'Content-Type': chunk.mimeType
  }
});

if (!response.ok) {
  throw new Error(`Upload failed: ${response.status}`);
}
```

### 3. Update Storage Status

```javascript
// On success
await this.storage.updateChunkStatus(sessionId, chunkNumber, {
  uploadStatus: 'uploaded',
  s3Key: s3Key
});

// On failure
await this.storage.updateChunkStatus(sessionId, chunkNumber, {
  uploadStatus: 'failed',
  lastError: error.message
});
```

---

## Retry Strategy (Exponential Backoff)

```javascript
function calculateDelay(attempt, baseDelay, maxDelay) {
  const delay = Math.min(
    baseDelay * Math.pow(2, attempt),
    maxDelay
  );
  return delay;
}

// Example:
// Attempt 0: 1s
// Attempt 1: 2s
// Attempt 2: 4s
// Attempt 3: 8s
// Attempt 4: 16s
// Attempt 5+: 60s (max)
```

---

## Network Monitoring

```javascript
// Basic online/offline detection
window.addEventListener('online', () => {
  console.log('Network online');
  uploadQueue.resume();
});

window.addEventListener('offline', () => {
  console.log('Network offline');
  uploadQueue.pause();
});
```

---

## Usage Example

```javascript
// Initialize
const storage = new AudioStorage();
await storage.init();

const queue = new UploadQueue(storage, {
  maxConcurrent: 3,
  maxRetries: 5
});

// Listen to events
queue.on('upload-complete', (data) => {
  console.log(`Chunk ${data.chunkNumber} uploaded`);
  updateUI(data);
});

queue.on('upload-failed', (data) => {
  console.error(`Chunk ${data.chunkNumber} failed: ${data.error}`);
  showErrorNotification(data);
});

// Start uploading pending chunks
const pending = await storage.getAllPendingChunks();
for (const chunk of pending) {
  await queue.enqueue(chunk.sessionId, chunk.chunkNumber);
}

// When recording new chunks
mediaRecorder.ondataavailable = async (event) => {
  const chunkNumber = ++chunkCounter;

  // Save to IndexedDB
  await storage.saveChunk({
    sessionId: currentSessionId,
    chunkNumber: chunkNumber,
    audioBlob: event.data,
    mimeType: 'audio/webm',
    duration: 5000
  });

  // Queue for upload
  await queue.enqueue(currentSessionId, chunkNumber);
};
```

---

## Testing Strategy

### Unit Tests

1. Test queue adding/removing
2. Test concurrent limit (max 3)
3. Test retry with exponential backoff
4. Test pause/resume
5. Test error handling
6. Test event emission

### Integration Tests

1. Upload actual chunks to S3
2. Simulate network failures
3. Test recovery after page reload
4. Test with slow network (throttling)
5. Test with offline mode

### Test Page Template

```html
<!-- ui-source/lib/test-upload-queue.html -->
<!DOCTYPE html>
<html>
<head>
  <title>Upload Queue Test</title>
</head>
<body>
  <h1>Upload Queue Test</h1>

  <button id="btnInit">Initialize</button>
  <button id="btnCreateChunks">Create Test Chunks</button>
  <button id="btnStartUpload">Start Upload</button>
  <button id="btnPause">Pause</button>
  <button id="btnResume">Resume</button>
  <button id="btnSimulateFailure">Simulate Failure</button>

  <div id="status"></div>
  <div id="log"></div>

  <script src="audio-storage.js"></script>
  <script src="upload-queue.js"></script>
  <script>
    // Test implementation here...
  </script>
</body>
</html>
```

---

## Key Files Reference

### Already Built (Phase 1)
- `ui-source/lib/audio-storage.js` - IndexedDB wrapper ✅
- `ui-source/lib/test-audio-storage.html` - Storage tests ✅

### To Build (Phase 2)
- `ui-source/lib/upload-queue.js` - Queue manager ⏳
- `ui-source/lib/test-upload-queue.html` - Queue tests ⏳

### Existing Integration Points
- `ui-source/audio.html.template` - Main recorder UI (to integrate)
- `cognito-stack/api/audio.js` - Lambda for upload URLs (already exists)

---

## API Endpoints Available

From `cognito-stack/api/audio.js`:

```javascript
// Get upload URL for chunk
POST /audio/upload-chunk-url
Body: {
  sessionId: string,
  chunkNumber: number,
  mimeType: string
}
Response: {
  uploadUrl: string,    // S3 presigned URL
  s3Key: string,        // S3 object key
  expiresIn: number     // URL expiry (900s = 15min)
}
```

---

## Success Criteria for Phase 2

- ✅ Upload queue processes chunks sequentially
- ✅ Maximum 3 concurrent uploads enforced
- ✅ Exponential backoff works correctly
- ✅ Failed uploads retry up to 5 times
- ✅ Network offline/online handling works
- ✅ Upload progress emits events
- ✅ Integration with AudioStorage works
- ✅ Test page validates all functionality

---

## Estimated Time

**2-3 hours** for basic implementation
**1-2 hours** for testing and refinement

**Total:** 3-5 hours (not the full week estimated in NEXT-TASK.md)

---

## Start Command

```bash
cd /home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4

# Create the file
touch ui-source/lib/upload-queue.js

# Edit with your preferred editor
nano ui-source/lib/upload-queue.js
```

---

## Resources

- **Phase 1 Docs:** `PHASE-1-COMPLETE.md` - Full API reference
- **AudioStorage API:** See file header in `ui-source/lib/audio-storage.js`
- **Project Overview:** `CLAUDE.md`
- **Full Plan:** `NEXT-TASK.md`

---

**Ready to go!** 🚀

Start by creating `ui-source/lib/upload-queue.js` and implementing the `UploadQueue` class.
