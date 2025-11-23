# Uploaded Audio Feature - Design Document

**Version:** 1.0
**Date:** 2025-11-22
**Status:** Design Phase

---

## Overview

This feature extends CloudDrive to support user-uploaded audio files (.aac, .m4a, .wav, .mp3) alongside existing session recordings. Uploaded files are treated as "lightweight sessions" using the same transcription pipeline but kept logically separate in storage and metadata.

---

## Architecture

### Design Philosophy

**Reuse Session Code, Separate Storage**
- Uploaded files use the same S3 paths, metadata structure, and transcription pipeline as sessions
- They are stored in a parallel path structure to avoid mixing with live recordings
- The frontend treats them as session-like objects using existing session loading code

### S3 Storage Structure

```
s3://{BUCKET}/users/{userId}/audio/
├── sessions/                        # Live recording sessions
│   └── {sessionId}/
│       ├── chunk-001.webm
│       ├── chunk-002.webm
│       ├── metadata.json
│       └── ...
│
└── uploads/                         # User-uploaded audio files
    └── {uploadId}/                  # uploadId = timestamp-uuid
        ├── original.{ext}           # Original uploaded file (.aac, .m4a, etc.)
        ├── metadata.json            # Metadata (same structure as sessions)
        └── ...                      # Future: preprocessed chunks if needed
```

### Metadata Schema

Uploaded files use **the same metadata.json structure** as sessions:

```json
{
  "sessionId": "20251122-143022-abc123def456",
  "type": "upload",
  "createdAt": "2025-11-22T14:30:22.345Z",
  "originalFilename": "meeting-recording.m4a",
  "mimeType": "audio/m4a",
  "fileSize": 1234567,
  "duration": null,
  "userId": "cognito-sub-uuid",
  "status": "pending",
  "transcription": {
    "status": "pending",
    "jobId": null,
    "completedAt": null,
    "error": null
  },
  "s3Path": "users/{userId}/audio/uploads/20251122-143022-abc123def456/original.m4a"
}
```

**Key Fields:**
- `sessionId`: Same format as live sessions (timestamp-uuid), used as uploadId
- `type`: "upload" (vs "live" for recordings)
- `originalFilename`: User's original filename
- `mimeType`: Content type (.aac, .m4a, .wav, .mp3, etc.)
- `transcription.status`: "pending" | "processing" | "complete" | "error"

---

## Implementation Strategy

### 1. Backend Changes

#### A. New Lambda Function: `uploadAudioFile`

**Purpose:** Generate presigned S3 URL for direct upload

**Location:** `cognito-stack/api/audio.js`

**Function:** `module.exports.uploadAudioFile`

**Flow:**
1. Validate user is authenticated (Cognito authorizer)
2. Extract userId from JWT claims
3. Generate uploadId: `${timestamp}-${uuid}`
4. Validate file extension (.aac, .m4a, .wav, .mp3, .webm)
5. Create S3 key: `users/${userId}/audio/uploads/${uploadId}/original.${ext}`
6. Generate presigned PUT URL (15 min expiry)
7. Return: `{ uploadUrl, uploadId, s3Key, expiresIn }`

**Serverless.yml Addition:**
```yaml
uploadAudioFile:
  handler: api/audio.uploadAudioFile
  environment:
    S3_BUCKET_NAME: ${self:custom.s3Bucket}
    CLOUDFRONT_URL: ${env:COGNITO_CLOUDFRONT_URL}
  events:
    - http:
        path: api/audio/upload-file
        method: post
        cors: true
        authorizer:
          type: COGNITO_USER_POOLS
          authorizerId:
            Ref: ApiGatewayAuthorizer
```

#### B. New Lambda Function: `saveUploadMetadata`

**Purpose:** Save metadata.json after successful upload

**Location:** `cognito-stack/api/audio.js`

**Function:** `module.exports.saveUploadMetadata`

**Request Body:**
```json
{
  "uploadId": "20251122-143022-abc123def456",
  "originalFilename": "meeting.m4a",
  "mimeType": "audio/m4a",
  "fileSize": 1234567
}
```

**Flow:**
1. Validate uploadId format
2. Create metadata.json object (same structure as sessions)
3. Write to: `users/${userId}/audio/uploads/${uploadId}/metadata.json`
4. Return success

#### C. Extend Existing Function: `listSessions`

**Modification:** `cognito-stack/api/audio.js` → `module.exports.listSessions`

**Current Behavior:**
- Lists only `users/${userId}/audio/sessions/`

**New Behavior:**
- Accept optional query parameter: `?type=all|sessions|uploads`
- Default: `type=all` (both sessions and uploads)
- List from both prefixes:
  - `users/${userId}/audio/sessions/`
  - `users/${userId}/audio/uploads/`
- Return combined list with `type` field in each item

**Response:**
```json
{
  "sessions": [
    {
      "sessionId": "...",
      "type": "live",
      "folder": "...",
      "metadata": { ... }
    },
    {
      "sessionId": "...",
      "type": "upload",
      "folder": "...",
      "metadata": { ... }
    }
  ]
}
```

---

### 2. Frontend Changes

#### A. Dashboard Panel: "Uploaded Audio"

**File:** `ui-source/index.html`

**Location:** Add new panel after existing file manager sections

**Features:**
- Upload button with file input (accept: .aac, .m4a, .wav, .mp3, .webm)
- File size validation (max 500MB)
- Progress indicator during upload
- List of uploaded files with:
  - Filename
  - Upload date
  - File size
  - Transcription status badge
  - Actions: View in Editor | Delete

**Upload Flow:**
1. User selects audio file
2. Validate file type and size
3. Call `/api/audio/upload-file` to get presigned URL
4. Upload file directly to S3 using presigned URL
5. Call `/api/audio/save-upload-metadata` to register upload
6. Show success message
7. Refresh list

**Example UI:**
```html
<div class="panel uploaded-audio-panel">
  <div class="panel-header">
    <h2>Uploaded Audio Files</h2>
    <button class="btn-upload" onclick="triggerFileUpload()">
      <i class="fa fa-upload"></i> Upload Audio
    </button>
  </div>

  <input type="file" id="audioFileInput" accept=".aac,.m4a,.wav,.mp3,.webm" style="display:none">

  <div class="upload-list">
    <!-- Populated dynamically -->
  </div>
</div>
```

#### B. Transcript Editor: Dual-Source Selector

**File:** `ui-source/transcript-editor.html.template`

**Current:**
```
Session: [Dropdown with sessions]
```

**New Design:**
```
Source Type: [Live Sessions ▼] [Uploaded Files ▼]
Items: [List based on selected source]
```

**Implementation:**
- Add two dropdown buttons side-by-side
- First dropdown: Source Type (Sessions | Uploads)
- Second dropdown: List of items from selected source
- Clicking an item loads its audio and transcript
- Both sources use the **same loading code** (`loadSession(sessionId, type)`)

**Example:**
```html
<div class="session-selector">
  <div class="selector-group">
    <label>Source</label>
    <div class="dual-selector">
      <button class="source-btn active" data-source="sessions">
        Live Sessions ▼
      </button>
      <button class="source-btn" data-source="uploads">
        Uploaded Files ▼
      </button>
    </div>
  </div>

  <div class="items-dropdown" id="itemsList">
    <!-- Populated based on selected source -->
  </div>
</div>
```

**JavaScript Changes:**
```javascript
let currentSourceType = 'sessions'; // or 'uploads'
let allSessions = [];
let allUploads = [];

async function loadSessions() {
  const data = await apiCall('/api/audio/sessions?type=all');
  allSessions = data.sessions.filter(s => s.type === 'live');
  allUploads = data.sessions.filter(s => s.type === 'upload');
  populateItemsList();
}

function switchSource(sourceType) {
  currentSourceType = sourceType;
  populateItemsList();
}

function populateItemsList() {
  const items = currentSourceType === 'sessions' ? allSessions : allUploads;
  // Render items...
}

function loadItem(sessionId, type) {
  // Load audio from S3
  // Load transcript (if exists)
  // Uses SAME code for both sessions and uploads
}
```

---

### 3. Batch Transcription Integration

#### A. Extend Script: `512-scan-missing-chunks.sh`

**Current:** Scans `users/*/audio/sessions/*/`

**New:** Also scan `users/*/audio/uploads/*/`

**Logic:**
1. Scan sessions (existing)
2. Scan uploads (new)
   - Look for `original.*` files without corresponding transcript
   - Check `metadata.json` for `transcription.status !== 'complete'`
3. Return combined list of pending jobs

#### B. Extend Script: `batch-transcribe-audio.py`

**Current:** Processes session chunks (.webm files)

**New:** Also process uploaded files (.aac, .m4a, .wav, .mp3)

**Changes:**
- Accept file path as argument (already does)
- Detect file type from extension
- Transcribe using faster-whisper (already does)
- Output transcript JSON (already does)

**No changes needed!** Script is already file-type agnostic.

#### C. Extend Script: `515-run-batch-transcribe.sh`

**Modification:** Process uploads after sessions

**Flow:**
1. Check batch lock (existing)
2. Scan for missing session transcripts (existing)
3. **NEW:** Scan for missing upload transcripts
4. Start GPU if work exists (existing)
5. Process session chunks (existing)
6. **NEW:** Process uploaded files
7. Update metadata.json with transcription status
8. Stop GPU if started (existing)

**Transcript Storage:**
- Sessions: `users/${userId}/audio/sessions/${sessionId}/transcription-chunk-*.json`
- Uploads: `users/${userId}/audio/uploads/${uploadId}/transcript.json`

---

## File-by-File Changes

### Backend

| File | Changes | Complexity |
|------|---------|------------|
| `cognito-stack/api/audio.js` | Add `uploadAudioFile()`, `saveUploadMetadata()`, extend `listSessions()` | Medium |
| `cognito-stack/serverless.yml` | Add 2 new Lambda function definitions | Low |

### Frontend

| File | Changes | Complexity |
|------|---------|------------|
| `ui-source/index.html` | Add "Uploaded Audio" panel with upload UI | Medium |
| `ui-source/transcript-editor.html.template` | Add dual-source selector, modify session loading | Medium |

### Scripts

| File | Changes | Complexity |
|------|---------|------------|
| `scripts/512-scan-missing-chunks.sh` | Add upload scanning logic | Low |
| `scripts/515-run-batch-transcribe.sh` | Add upload processing after sessions | Medium |
| `scripts/batch-transcribe-audio.py` | **No changes needed** | None |

---

## API Endpoints Summary

### New Endpoints

| Method | Path | Purpose | Request | Response |
|--------|------|---------|---------|----------|
| POST | `/api/audio/upload-file` | Get presigned upload URL | `{ filename, mimeType }` | `{ uploadUrl, uploadId, s3Key }` |
| POST | `/api/audio/save-upload-metadata` | Save metadata after upload | `{ uploadId, originalFilename, mimeType, fileSize }` | `{ success: true }` |

### Modified Endpoints

| Method | Path | Changes |
|--------|------|---------|
| GET | `/api/audio/sessions` | Add `?type=all\|sessions\|uploads` query param |

---

## Metadata Lifecycle

### Upload Flow

1. **User uploads file** → Frontend calls `/api/audio/upload-file`
2. **Presigned URL returned** → Frontend uploads to S3 directly
3. **Upload complete** → Frontend calls `/api/audio/save-upload-metadata`
4. **Metadata saved** with `transcription.status = "pending"`

### Transcription Flow

1. **Cron triggers** `515-run-batch-transcribe.sh` every 2 hours
2. **Script scans** for pending uploads (metadata.json with `status = "pending"`)
3. **GPU started** (if not running)
4. **File transcribed** using `batch-transcribe-audio.py`
5. **Transcript saved** to S3: `uploads/${uploadId}/transcript.json`
6. **Metadata updated** with `transcription.status = "complete"`

### View Flow

1. **User opens transcript editor**
2. **Switches to "Uploaded Files"** source
3. **Selects file** from dropdown
4. **Editor loads** audio from S3 + transcript (if exists)
5. **Playback works** same as sessions

---

## Security Considerations

### S3 Bucket Policies

**Already Configured:**
- Users can only access `users/${theirUserId}/`
- Cognito Identity Pool provides scoped credentials

**No Changes Needed** - uploads go to `users/${userId}/audio/uploads/`

### File Validation

- **Frontend:** Validate file extension before upload
- **Backend:** Validate MIME type in `uploadAudioFile`
- **Size Limit:** Enforce max 500MB

### Content-Type Enforcement

```javascript
// In uploadAudioFile Lambda
const allowedTypes = [
  'audio/aac', 'audio/x-m4a', 'audio/m4a',
  'audio/wav', 'audio/x-wav',
  'audio/mpeg', 'audio/mp3',
  'audio/webm'
];

if (!allowedTypes.includes(mimeType)) {
  return { statusCode: 400, body: { error: 'Invalid audio format' } };
}
```

---

## Cost Analysis

### Storage Costs

**Uploads:**
- Average file: ~50MB
- S3 Standard: $0.023/GB/month
- 100 files: ~$0.12/month
- Negligible

### Transcription Costs

**GPU Usage:**
- Batch runs every 2 hours (12x/day)
- If uploads exist: ~5 min GPU time
- Cost: 12 × (5/60) × $0.526 = **$0.53/day** = **$16/month**
- **Optimization:** Only start GPU if pending jobs exist (already implemented)

---

## Testing Checklist

### Backend Tests

- [ ] Upload .m4a file → verify presigned URL generated
- [ ] Save metadata → verify JSON in S3
- [ ] List sessions with `?type=all` → verify both types returned
- [ ] List sessions with `?type=uploads` → verify only uploads returned

### Frontend Tests

- [ ] Upload file via dashboard → verify success message
- [ ] View uploaded files list → verify correct metadata displayed
- [ ] Switch to "Uploaded Files" in editor → verify list populated
- [ ] Select uploaded file → verify audio plays
- [ ] Upload invalid file type → verify error message

### Transcription Tests

- [ ] Upload file → wait for cron → verify transcript created
- [ ] Check metadata.json → verify `transcription.status = "complete"`
- [ ] View in editor → verify transcript displays correctly
- [ ] Test with .aac, .m4a, .wav, .mp3 files

### Edge Cases

- [ ] Upload during active transcription session → verify batch lock works
- [ ] Upload 500MB file → verify size limit enforced
- [ ] Upload with special characters in filename → verify sanitization
- [ ] Multiple concurrent uploads → verify no conflicts

---

## Future Enhancements

### Phase 2 Features (Not in Scope)

1. **Drag & Drop Upload** - UI enhancement
2. **Batch Upload** - Multiple files at once
3. **Upload Progress** - Real-time progress bar
4. **Chunk Processing** - Split large files into smaller chunks
5. **Format Conversion** - Auto-convert to .webm for consistency
6. **Direct Transcription** - Trigger transcription immediately after upload
7. **Shared Uploads** - Allow sharing uploaded files with other users

---

## Migration Strategy

### Deployment Steps

1. **Deploy Backend**
   ```bash
   cd cognito-stack
   serverless deploy function -f uploadAudioFile
   serverless deploy function -f saveUploadMetadata
   serverless deploy function -f listAudioSessions  # updated
   ```

2. **Deploy Frontend**
   ```bash
   ./scripts/425-deploy-recorder-ui.sh
   ```

3. **Update Scripts**
   ```bash
   # Test batch transcription with uploads
   ./scripts/515-run-batch-transcribe.sh
   ```

4. **Verify**
   - Upload test file via dashboard
   - Wait for cron or manually run `515-run-batch-transcribe.sh`
   - Check transcript in editor

### Rollback Plan

If issues occur:
1. Remove new Lambda functions from `serverless.yml`
2. Revert frontend changes
3. Redeploy: `serverless deploy`
4. Uploaded files remain in S3 (no data loss)

---

## Summary

This design **reuses existing session infrastructure** with minimal new code:

**Reused:**
- ✅ Same metadata.json structure
- ✅ Same S3 path pattern (`users/${userId}/audio/...`)
- ✅ Same transcription pipeline (`batch-transcribe-audio.py`)
- ✅ Same transcript editor loading code

**New:**
- 🆕 Parallel storage path (`uploads/` instead of `sessions/`)
- 🆕 Upload UI in dashboard
- 🆕 Dual-source selector in editor
- 🆕 2 new Lambda functions

**Result:** Uploaded files appear as "lightweight sessions" with minimal code duplication.
