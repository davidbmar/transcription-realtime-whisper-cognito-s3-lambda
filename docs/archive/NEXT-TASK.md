# Next Task: Audio Recorder Mobile Resilience Revamp

**Status:** Ready to implement
**Priority:** High
**Estimated Time:** 4-5 weeks

---

## Context: What Happened

During a mobile phone recording session on Nov 17, 2025:
- **83 out of 127 audio chunks were lost** (66% failure rate)
- Chunks 1-43 uploaded successfully (~150KB each)
- Chunk 44 failed completely (missing)
- Chunks 45-127 corrupted (only 5 bytes each - partial WebM headers)

**Root Cause:** Mobile browser suspended the app when screen locked, killing in-progress uploads

---

## Problem Analysis

### Current Architecture Issues

1. **No Persistent Storage**
   - Audio chunks stored only in React state (memory)
   - Data lost on page reload, backgrounding, or crashes
   - File: `ui-source/audio.html.template` line 378-391

2. **No Upload Retry Logic**
   - Failed uploads marked as 'failed' but never retried
   - File: `ui-source/audio.html.template` line 291-298

3. **No IndexedDB Implementation**
   - Code mentions IndexedDB in comments but doesn't use it
   - No persistent storage layer exists

4. **Mobile Browser Kills Uploads**
   - Screen lock suspends network activity
   - `fetch()` requests terminated mid-upload
   - Only first TCP packet (5 bytes) reaches S3

---

## Solution: Implement Robust Mobile Recording

### Phase 1: IndexedDB Persistence Layer (Week 1) ✅ COMPLETED

**Goal:** Store audio chunks locally before uploading

**Tasks:**
1. ✅ Create `ui-source/lib/audio-storage.js` - IndexedDB wrapper (24KB)
2. ✅ Design database schema (see schema below)
3. ✅ Implement chunk save/retrieve/update/delete operations
4. ✅ Add session management
5. ✅ Write test page: `ui-source/lib/test-audio-storage.html`

**Completed:** 2025-11-17

**Files Created:**
- `ui-source/lib/audio-storage.js` - Full IndexedDB implementation with 20+ methods
- `ui-source/lib/test-audio-storage.html` - Interactive test page

**What Works:**
- Database initialization with automatic schema migration
- Save/retrieve audio chunks with Blob storage
- Session management (create, update, get, delete)
- Upload status tracking (pending, uploading, uploaded, failed)
- Retry attempt tracking
- Failed chunk recovery
- Storage statistics and quota monitoring
- Automatic cleanup of old sessions
- Comprehensive error handling and logging

**Database Schema:**

```javascript
// ObjectStore: audio_chunks
{
  sessionId: string,
  chunkNumber: number,
  audioBlob: Blob,              // The actual audio data
  mimeType: string,
  size: number,
  duration: number,
  recordedAt: ISOString,

  // Upload tracking
  uploadStatus: 'pending' | 'uploading' | 'uploaded' | 'failed',
  uploadAttempts: number,
  lastUploadAttempt: ISOString,
  lastError: string,
  s3Key: string,
  uploadedAt: ISOString
}

// ObjectStore: sessions
{
  sessionId: string,
  userId: string,
  createdAt: ISOString,
  status: 'recording' | 'stopped' | 'completed',
  totalChunks: number,
  uploadedChunks: number,
  failedChunks: number
}
```

### Phase 2: Upload Queue with Retry Logic (Week 2)

**Goal:** Automatic retry with exponential backoff

**Tasks:**
1. Create `ui-source/lib/upload-queue.js` - Upload queue manager
2. Implement exponential backoff (1s, 2s, 4s, 8s, 60s max)
3. Add max concurrent uploads limit (3)
4. Add network online/offline detection
5. Integrate with IndexedDB
6. Write unit tests

**Retry Strategy:**
- Max 5 attempts per chunk
- Base delay: 1 second
- Exponential factor: 2x
- Max delay: 60 seconds

### Phase 3: Mobile Resilience Features (Week 3)

**Goal:** Handle screen lock, backgrounding, network changes

**Tasks:**
1. Implement Wake Lock API (prevent screen sleep)
2. Add Page Visibility API handling (pause/resume on background)
3. Add network change detection
4. Add connection quality detection (throttle on 2G)
5. Test on iOS Safari and Android Chrome

### Phase 4: UI & Recovery (Week 4)

**Goal:** User visibility and manual retry

**Tasks:**
1. Build upload status dashboard
2. Show pending/uploading/failed chunk counts
3. Add manual retry button
4. Session recovery on page load
5. Storage usage indicator
6. User warnings (keep screen on, etc.)

### Phase 5: Documentation (Week 5)

**Tasks:**
1. Update `CLAUDE.md` with new architecture
2. Create `docs/audio-recorder-architecture.md`
3. Create `docs/mobile-recording-best-practices.md`
4. Add architecture diagrams
5. Update README troubleshooting section

---

## File Locations

### Files to Modify
- `ui-source/audio.html.template` - Integrate IndexedDB and retry logic

### Files to Create
- `ui-source/lib/audio-storage.js` - IndexedDB wrapper
- `ui-source/lib/upload-queue.js` - Upload queue manager
- `ui-source/lib/network-monitor.js` - Network state detection
- `docs/audio-recorder-architecture.md` - Technical documentation
- `docs/mobile-recording-best-practices.md` - User guide

---

## Implementation Priority Order

1. **Week 1:** IndexedDB persistence (critical - prevents data loss)
2. **Week 2:** Upload retry logic (critical - handles network failures)
3. **Week 3:** Mobile resilience (important - prevents browser suspension)
4. **Week 4:** UI & recovery (important - user visibility)
5. **Week 5:** Documentation (important - maintainability)

---

## Key Technical Decisions

### Why IndexedDB?
- Persists across page reloads and crashes
- Can store Blob objects (audio data)
- Async API doesn't block UI
- ~50MB+ quota (enough for hours of recording)
- Works offline

### Why Upload Queue?
- Decouples recording from upload
- Handles concurrent uploads efficiently
- Easy to pause/resume
- Retries automatically

### Why Exponential Backoff?
- Prevents thundering herd on network restore
- Respects server rate limits
- Handles transient failures gracefully

---

## Success Criteria

### Before (Current State)
- ❌ 66% failure rate on mobile (83/127 chunks lost)
- ❌ No recovery after failures
- ❌ No user visibility

### After (Target)
- ✅ 0% data loss (all chunks persisted locally)
- ✅ >99% upload success rate (with retries)
- ✅ 100% recovery after app restart
- ✅ Clear upload status in UI

---

## Testing Checklist

Must test on mobile devices:

- [ ] Record while screen locks mid-session
- [ ] Record while switching apps (backgrounding)
- [ ] Record while network switches (WiFi → Cellular)
- [ ] Record while network disconnects
- [ ] Record then force-close app
- [ ] Record then reload page
- [ ] Record with slow network (2G simulation)
- [ ] Fill IndexedDB quota (error handling)
- [ ] Multiple concurrent sessions

---

## Commands to Get Started

```bash
# Navigate to project
cd /home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4

# Create new files
mkdir -p ui-source/lib
touch ui-source/lib/audio-storage.js
touch ui-source/lib/upload-queue.js
touch ui-source/lib/network-monitor.js

# Create documentation
mkdir -p docs
touch docs/audio-recorder-architecture.md
touch docs/mobile-recording-best-practices.md

# Start with Phase 1: IndexedDB implementation
# Edit: ui-source/lib/audio-storage.js
```

---

## Immediate Next Step

**Start with:** Implementing `audio-storage.js` - the IndexedDB wrapper

**Prompt for next Claude instance:**

```
Please implement the IndexedDB persistence layer for the audio recorder to fix mobile recording failures.

Context:
- 83 out of 127 audio chunks were lost during mobile recording due to app backgrounding
- Audio chunks are currently stored only in React state (memory)
- Need IndexedDB to persist chunks locally before uploading

Task:
1. Create ui-source/lib/audio-storage.js with the IndexedDB wrapper class
2. Implement the database schema from NEXT-TASK.md
3. Add methods: saveChunk, getChunk, updateChunkStatus, getAllPendingChunks
4. Write comprehensive error handling

See NEXT-TASK.md for full context and detailed schema.
```

---

## Related Files to Review

**Current audio recorder:**
- `ui-source/audio.html.template` - Main recording UI
- `cognito-stack/api/audio.js` - Lambda functions for upload URLs

**Batch transcription (to understand upload failures):**
- `scripts/515-run-batch-transcribe.sh` - Shows corrupted file evidence
- Latest commit: 92907ec "Add GPU error logging and fix IP resolution"

**Documentation:**
- `CLAUDE.md` - Project overview and architecture
- This file: `NEXT-TASK.md` - Complete implementation plan

---

## Questions to Clarify

None - plan is complete and ready to implement.

---

**End of Task Brief**

*Last Updated: 2025-11-17*
*Created by: Claude Code*
