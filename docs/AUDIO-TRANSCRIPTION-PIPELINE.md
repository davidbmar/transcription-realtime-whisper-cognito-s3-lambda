# Audio Transcription Pipeline Documentation

> **Version:** 1.0
> **Last Updated:** 2025-12-17
> **Purpose:** Complete technical reference for the CloudDrive audio upload, transcription, and display pipeline.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture Diagram](#2-architecture-diagram)
3. [Phase 1: Audio Upload](#3-phase-1-audio-upload)
4. [Phase 2: Batch Transcription](#4-phase-2-batch-transcription)
5. [Phase 3: Postprocessing](#5-phase-3-postprocessing)
6. [Phase 4: Editor Display](#6-phase-4-editor-display)
7. [Data Formats](#7-data-formats)
8. [S3 Storage Structure](#8-s3-storage-structure)
9. [API Reference](#9-api-reference)
10. [Scripts Reference](#10-scripts-reference)
11. [Known Gaps & Future Improvements](#11-known-gaps--future-improvements)

---

## 1. Overview

### What This System Does

CloudDrive is a real-time audio transcription platform that:
1. Accepts audio file uploads from users
2. Transcribes audio using GPU-powered speech recognition (WhisperX/Faster-Whisper)
3. Processes transcriptions with speaker diarization (who said what)
4. Displays interactive transcripts with word-level highlighting and playback sync

### Key Components

| Component | Technology | Purpose |
|-----------|------------|---------|
| Frontend | Vanilla JS, HTML | User interface for upload and viewing |
| Backend API | AWS Lambda (Node.js) | File operations, auth, metadata |
| Storage | AWS S3 | Audio files, transcriptions, metadata |
| Auth | AWS Cognito | User authentication and authorization |
| Transcription | WhisperX on RunPod GPU | Speech-to-text with diarization |
| CDN | AWS CloudFront | Fast global content delivery |

### Data Flow Summary

```
User Upload → S3 Storage → GPU Transcription → Postprocessing → Editor Display
     │            │              │                   │              │
     │            │              │                   │              │
  [Browser]    [AWS S3]     [RunPod/EC2]      [Node.js Scripts]  [Browser]
```

---

## 2. Architecture Diagram

### High-Level Flow

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                              USER'S BROWSER                                   │
│                                                                               │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐   │
│  │   Upload    │    │  Dashboard  │    │  Transcript │    │   Audio     │   │
│  │   Panel     │    │   (index)   │    │   Editor    │    │  Recorder   │   │
│  └──────┬──────┘    └─────────────┘    └──────┬──────┘    └─────────────┘   │
│         │                                      │                             │
└─────────┼──────────────────────────────────────┼─────────────────────────────┘
          │                                      │
          ▼                                      ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                              AWS INFRASTRUCTURE                               │
│                                                                               │
│  ┌─────────────────────────────────────────────────────────────────────────┐ │
│  │                         API GATEWAY + LAMBDA                             │ │
│  │                                                                          │ │
│  │  /api/audio/upload-file     → Generate presigned upload URL             │ │
│  │  /api/audio/session-metadata → Save/update session metadata             │ │
│  │  /api/audio/sessions        → List user's audio sessions                │ │
│  │  /api/s3/download/{key}     → Generate presigned download URL           │ │
│  │  /api/s3/list               → List files in user's S3 path              │ │
│  └─────────────────────────────────────────────────────────────────────────┘ │
│                                      │                                        │
│                                      ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────────┐ │
│  │                              AWS S3 BUCKET                               │ │
│  │                                                                          │ │
│  │  users/{userId}/audio/sessions/{sessionId}/                             │ │
│  │    ├── chunk-001.mp3                    (original audio)                │ │
│  │    ├── metadata.json                    (session metadata)              │ │
│  │    ├── transcription-chunk-001.json     (raw transcription)             │ │
│  │    ├── transcription-processed.json     (editor-ready format)           │ │
│  │    └── .transcription-complete          (completion marker)             │ │
│  └─────────────────────────────────────────────────────────────────────────┘ │
│                                                                               │
└──────────────────────────────────────────────────────────────────────────────┘
          │
          │ (Batch job downloads audio, uploads transcription)
          ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                              GPU INFRASTRUCTURE                               │
│                                                                               │
│  ┌────────────────────────────┐    ┌────────────────────────────┐           │
│  │     RunPod (Primary)       │    │    AWS EC2 (Fallback)      │           │
│  │                            │    │                            │           │
│  │  • WhisperX + Diarization  │    │  • Faster-Whisper          │           │
│  │  • $0.13-0.20/hr           │    │  • $0.52/hr                │           │
│  │  • HTTP API                │    │  • SSH access              │           │
│  │  • Auto GPU selection      │    │  • g4dn.xlarge             │           │
│  └────────────────────────────┘    └────────────────────────────┘           │
│                                                                               │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Detailed Component Interaction

```
┌─────────┐     ┌─────────┐     ┌─────────┐     ┌─────────┐     ┌─────────┐
│ Browser │     │   API   │     │   S3    │     │   GPU   │     │ Scripts │
└────┬────┘     └────┬────┘     └────┬────┘     └────┬────┘     └────┬────┘
     │               │               │               │               │
     │ 1. Request    │               │               │               │
     │   upload URL  │               │               │               │
     │──────────────>│               │               │               │
     │               │               │               │               │
     │ 2. Presigned  │               │               │               │
     │    URL        │               │               │               │
     │<──────────────│               │               │               │
     │               │               │               │               │
     │ 3. Upload file directly       │               │               │
     │───────────────────────────────>               │               │
     │               │               │               │               │
     │ 4. Save       │               │               │               │
     │   metadata    │               │               │               │
     │──────────────>│ 5. Write     │               │               │
     │               │───────────────>               │               │
     │               │               │               │               │
     │               │               │               │  6. Trigger   │
     │               │               │               │<──────────────│
     │               │               │               │  batch job    │
     │               │               │               │               │
     │               │               │ 7. Download   │               │
     │               │               │    audio      │               │
     │               │               │<──────────────│               │
     │               │               │               │               │
     │               │               │ 8. Upload     │               │
     │               │               │    transcript │               │
     │               │               │<──────────────│               │
     │               │               │               │               │
     │               │               │               │  9. Run       │
     │               │               │               │  postprocess  │
     │               │               │<─────────────────────────────│
     │               │               │               │               │
     │ 10. Load      │               │               │               │
     │    editor     │               │               │               │
     │──────────────>│ 11. Get file │               │               │
     │               │───────────────>               │               │
     │               │               │               │               │
     │ 12. Display   │               │               │               │
     │    transcript │               │               │               │
     │<──────────────────────────────│               │               │
     │               │               │               │               │
```

---

## 3. Phase 1: Audio Upload

### 3.1 User Interface

**Location:** `ui-source/index.html` (lines 2240-2582)

**Entry Point:** User clicks "Upload Audio Files" card on dashboard, triggering `showUploadAudio()` function.

**Supported Formats:**
- Audio: `.mp3`, `.m4a`, `.aac`, `.wav`, `.ogg`, `.flac`
- Video (audio extracted): `.mp4`, `.mov`, `.webm`
- Maximum file size: Limited by S3 presigned URL (typically 5GB)

### 3.2 Upload Flow - Step by Step

#### Step 1: User Selects File

```javascript
// User interaction
// - Drag and drop onto upload zone, OR
// - Click to open file picker
// - Select one or more audio files
```

**User can also configure:**
- Minimum speakers (1-5, default: 1)
- Maximum speakers (1-10, default: 2)

These settings are stored in metadata for diarization.

#### Step 2: Request Presigned Upload URL

**API Call:**
```http
POST /api/audio/upload-file
Content-Type: application/json
Authorization: Bearer {cognito_id_token}

{
  "filename": "meeting-recording.mp3",
  "mimeType": "audio/mpeg",
  "fileSize": 15728640
}
```

**Response:**
```json
{
  "uploadUrl": "https://s3.us-east-2.amazonaws.com/clouddrive-app-bucket/users/...",
  "sessionId": "20251217-143022-upload-a1b2c3d4e5f6",
  "s3Key": "users/017bf540-.../audio/sessions/20251217-143022-upload-a1b2c3d4e5f6/chunk-001.mp3",
  "expiresIn": 900
}
```

**Backend Handler:** `cognito-stack/api/audio.js` - `uploadAudioFile()` (lines 443-567)

**Session ID Format:**
```
{YYYYMMDD}-{HHMMSS}-upload-{UUID_FIRST_12_CHARS}
Example: 20251217-143022-upload-a1b2c3d4e5f6
```

#### Step 3: Direct Upload to S3

**Browser uploads directly to S3 using presigned URL:**
```javascript
const response = await fetch(uploadUrl, {
  method: 'PUT',
  body: file,
  headers: {
    'Content-Type': mimeType
  }
});
```

**Benefits of Direct Upload:**
- Bypasses API Gateway 10MB limit
- Faster upload (direct to S3)
- Reduces Lambda execution time and cost

#### Step 4: Save Session Metadata

**API Call:**
```http
POST /api/audio/session-metadata
Content-Type: application/json
Authorization: Bearer {cognito_id_token}

{
  "sessionId": "20251217-143022-upload-a1b2c3d4e5f6",
  "metadata": {
    "source": "upload",
    "originalFilename": "meeting-recording.mp3",
    "createdAt": "2025-12-17T14:30:22.000Z",
    "status": "uploaded",
    "chunkCount": 1,
    "chunks": [
      {
        "chunkNumber": 1,
        "filename": "chunk-001.mp3",
        "size": 15728640,
        "uploadedAt": "2025-12-17T14:30:22.000Z"
      }
    ],
    "diarization": {
      "minSpeakers": 1,
      "maxSpeakers": 4
    },
    "transcription": {
      "status": "pending",
      "jobId": null
    }
  }
}
```

**Backend Handler:** `cognito-stack/api/audio.js` - `updateSessionMetadata()` (lines 135-229)

### 3.3 S3 State After Upload

```
s3://clouddrive-app-bucket/
└── users/
    └── {userId}/
        └── audio/
            └── sessions/
                └── {sessionId}/
                    ├── chunk-001.mp3      # Original audio file
                    └── metadata.json       # Session metadata
```

### 3.4 Error Handling

| Error | Cause | Resolution |
|-------|-------|------------|
| 413 Payload Too Large | File exceeds limit | Use chunked upload |
| 403 Forbidden | Presigned URL expired | Request new URL (15min expiry) |
| Network Error | Connection lost | Retry with exponential backoff |
| Invalid Format | Unsupported file type | Convert to supported format |

---

## 4. Phase 2: Batch Transcription

### 4.1 Overview

Batch transcription is a **manually triggered** process that:
1. Scans S3 for sessions with audio but no transcription
2. Starts a GPU instance (RunPod or AWS EC2)
3. Downloads audio, runs speech recognition
4. Uploads transcription results back to S3

### 4.2 Trigger Methods

**Option A: RunPod (Recommended - Cheaper)**
```bash
./scripts/515-runpod--batch-transcribe.sh --all
```

**Option B: AWS EC2**
```bash
./scripts/515-aws--batch-transcribe.sh --all
```

### 4.3 RunPod Transcription Flow

**Script:** `scripts/515-runpod--batch-transcribe.sh`

#### Step 1: Scan for Missing Transcriptions

```bash
# Script 512 scans S3 for sessions needing transcription
./scripts/512-scan-missing-chunks.sh
```

**Logic:**
- List all session folders in `users/*/audio/sessions/`
- Check if `.transcription-complete` marker exists
- If no marker, session needs transcription

#### Step 2: Start RunPod Instance

```bash
# Start pod with auto GPU selection
./scripts/850-runpod--start.sh
```

**GPU Selection Priority:**
1. RTX 4090 ($0.13/hr) - Fastest
2. RTX 3090 ($0.14/hr) - Good balance
3. RTX A5000 ($0.16/hr) - Reliable
4. Any available ($0.13-0.20/hr)

#### Step 3: Process Each Session

For each session needing transcription:

**3a. Generate Presigned URLs**
```bash
# GET URL for downloading audio
aws s3 presign "s3://${BUCKET}/${session_path}/chunk-001.mp3" --expires-in 3600

# PUT URL for uploading transcription
aws s3 presign "s3://${BUCKET}/${session_path}/transcription-chunk-001.json" \
    --expires-in 3600 --method PUT
```

**3b. Submit Transcription Job**
```http
POST https://{runpod-id}-8000.proxy.runpod.net/transcribe
Content-Type: application/json

{
  "audio_url": "https://s3...presigned-get-url",
  "output_url": "https://s3...presigned-put-url",
  "language": "en",
  "task": "transcribe",
  "diarize": true,
  "min_speakers": 1,
  "max_speakers": 4,
  "word_timestamps": true
}
```

**3c. Poll for Completion**
```bash
while [ "$status" != "completed" ]; do
  response=$(curl -s "https://${RUNPOD_URL}/status/${job_id}")
  status=$(echo "$response" | jq -r '.status')
  sleep 5
done
```

#### Step 4: Create Completion Marker

```bash
# Mark session as transcribed
echo "" | aws s3 cp - "s3://${BUCKET}/${session_path}/.transcription-complete"
```

#### Step 5: Stop RunPod Instance

```bash
./scripts/855-runpod--stop.sh
```

### 4.4 WhisperX Processing Details

**Model:** WhisperX (based on OpenAI Whisper large-v3)

**Features:**
- Word-level timestamps with high accuracy
- Speaker diarization via pyannote.audio
- VAD (Voice Activity Detection) for silence handling
- Batch processing for efficiency

**Processing Speed:** ~35x real-time (1 hour audio ≈ 2 minutes processing)

### 4.5 Transcription Output Format

**File:** `transcription-chunk-001.json`

```json
{
  "segments": [
    {
      "id": 0,
      "start": 0.0,
      "end": 5.84,
      "text": " Hello everyone, welcome to the meeting.",
      "speaker": "SPEAKER_00",
      "words": [
        {
          "word": "Hello",
          "start": 0.0,
          "end": 0.48,
          "score": 0.92
        },
        {
          "word": "everyone",
          "start": 0.52,
          "end": 1.12,
          "score": 0.95
        },
        {
          "word": "welcome",
          "start": 1.28,
          "end": 1.76,
          "score": 0.89
        },
        {
          "word": "to",
          "start": 1.80,
          "end": 1.92,
          "score": 0.97
        },
        {
          "word": "the",
          "start": 1.96,
          "end": 2.08,
          "score": 0.98
        },
        {
          "word": "meeting",
          "start": 2.12,
          "end": 2.64,
          "score": 0.94
        }
      ]
    },
    {
      "id": 1,
      "start": 3.20,
      "end": 8.96,
      "text": " Thank you for joining. Let's get started.",
      "speaker": "SPEAKER_01",
      "words": [...]
    }
  ],
  "language": "en",
  "duration": 3600.0,
  "speakers": ["SPEAKER_00", "SPEAKER_01"],
  "diarization_metadata": {
    "num_speakers": 2,
    "model": "pyannote/speaker-diarization-3.1"
  }
}
```

### 4.6 S3 State After Transcription

```
s3://clouddrive-app-bucket/
└── users/
    └── {userId}/
        └── audio/
            └── sessions/
                └── {sessionId}/
                    ├── chunk-001.mp3                    # Original audio
                    ├── metadata.json                    # Session metadata
                    ├── transcription-chunk-001.json     # Raw transcription (SEGMENTS FORMAT)
                    └── .transcription-complete          # Completion marker
```

---

## 5. Phase 3: Postprocessing

### 5.1 Overview

Postprocessing converts raw transcription output into an editor-optimized format:
- **Input:** `segments` format (array of timestamped text segments)
- **Output:** `paragraphs` format (structured for editor display)

### 5.2 Trigger: AUTOMATIC (as of 2025-12-17)

Postprocessing is **automatically triggered** at the end of batch transcription scripts:
- `515-runpod--batch-transcribe.sh` - calls 518 after transcription completes
- `515-aws--batch-transcribe.sh` - has Phase 4 for postprocessing

**Manual trigger (if needed):**
```bash
./scripts/518-postprocess-transcripts.sh
```

### 5.3 Postprocessing Steps

**Script:** `scripts/518-postprocess-transcripts.sh`

#### Step 1: Scan for Sessions Needing Postprocessing

```bash
# Find sessions with transcription but no processed file
for session in $(aws s3 ls "s3://${BUCKET}/users/" --recursive | grep transcription-chunk); do
  # Check if transcription-processed.json exists
  # If not, add to processing queue
done
```

#### Step 2: Download Transcription Chunks

```bash
aws s3 cp "s3://${BUCKET}/${session}/transcription-chunk-001.json" /tmp/chunks/
```

#### Step 3: Deduplicate Boundaries

**Script:** `scripts/lib/deduplicate-transcript-boundaries.js`

**Purpose:** When audio is split into chunks, words at boundaries may be duplicated. This script removes duplicates.

**Algorithm:**
```javascript
// Compare last N words of chunk N with first N words of chunk N+1
// Remove duplicates based on word similarity and timing overlap

function deduplicateBoundaries(chunks) {
  const OVERLAP_WINDOW = 5; // words to compare

  for (let i = 0; i < chunks.length - 1; i++) {
    const currentEnd = getLastNWords(chunks[i], OVERLAP_WINDOW);
    const nextStart = getFirstNWords(chunks[i + 1], OVERLAP_WINDOW);

    // Find matching words and remove duplicates
    const duplicates = findDuplicates(currentEnd, nextStart);
    removeDuplicates(chunks[i + 1], duplicates);
  }
}
```

#### Step 4: Convert Segments to Paragraphs

**Transformation:**

```javascript
// INPUT: Segments format
{
  "segments": [
    { "text": "Hello", "start": 0.0, "end": 0.5, "speaker": "SPEAKER_00", "words": [...] },
    { "text": "World", "start": 0.6, "end": 1.0, "speaker": "SPEAKER_00", "words": [...] }
  ]
}

// OUTPUT: Paragraphs format
{
  "paragraphs": [
    {
      "id": "para-chunk-001",
      "text": "Hello World",
      "start": 0.0,
      "end": 1.0,
      "speaker": "SPEAKER_00",
      "words": [
        { "word": "Hello", "start": 0.0, "end": 0.5 },
        { "word": "World", "start": 0.6, "end": 1.0 }
      ]
    }
  ],
  "speakers": ["SPEAKER_00"],
  "stats": {
    "paragraphCount": 1,
    "totalWords": 2,
    "totalDuration": 1.0,
    "wordsPerMinute": 120
  }
}
```

#### Step 5: Apply Formatting Rules

**Script:** `scripts/lib/format-transcript-rules.js`

**Rules Applied:**
- Capitalize sentence beginnings
- Capitalize proper nouns (GPT, Claude, AWS, etc.)
- Fix punctuation spacing
- Insert paragraph breaks on long pauses (>2 seconds)
- Remove filler words (optional: "um", "uh", "like")

#### Step 6: Upload Processed File

```bash
aws s3 cp /tmp/transcription-processed.json \
  "s3://${BUCKET}/${session}/transcription-processed.json"
```

#### Step 7: Update Metadata

**Script:** `scripts/lib/update-session-metadata.js`

```json
{
  "transcription": {
    "status": "complete",
    "completedAt": "2025-12-17T15:45:00.000Z",
    "processedAt": "2025-12-17T15:45:30.000Z"
  }
}
```

### 5.4 S3 State After Postprocessing

```
s3://clouddrive-app-bucket/
└── users/
    └── {userId}/
        └── audio/
            └── sessions/
                └── {sessionId}/
                    ├── chunk-001.mp3                    # Original audio
                    ├── metadata.json                    # Updated status
                    ├── transcription-chunk-001.json     # Raw (segments)
                    ├── transcription-processed.json     # Processed (paragraphs) ← NEW
                    └── .transcription-complete          # Completion marker
```

---

## 6. Phase 4: Editor Display

### 6.1 Overview

The transcript editor loads and displays processed transcriptions with:
- Word-level highlighting during playback
- Speaker labels and color coding
- Editable text with save functionality
- Audio playback sync

### 6.2 File Location

**Template:** `ui-source/transcript-editor-v2.html.template`
**Deployed:** `cognito-stack/web/transcript-editor-v2.html`

### 6.3 Load Sequence

```javascript
async function loadAndProcessTranscript() {
  // Priority 1: Try transcription-processed.json (fastest)
  try {
    const processed = await loadFile('transcription-processed.json');
    if (processed.paragraphs) {
      return renderParagraphs(processed);
    }
  } catch (e) { /* not found */ }

  // Priority 2: Try transcription-diarized.json
  try {
    const diarized = await loadFile('transcription-diarized.json');
    if (diarized.segments) {
      return renderSegments(diarized); // Convert on-the-fly
    }
  } catch (e) { /* not found */ }

  // Priority 3: Load raw chunks (slowest)
  const chunks = await loadAllChunks();
  return processAndRender(chunks);
}
```

### 6.4 Format Handling

The editor now handles both formats:

**Paragraphs Format (preferred):**
```javascript
// Direct rendering - fast
processedData = savedData;
renderEditor();
```

**Segments Format (fallback):**
```javascript
// Convert on-the-fly - adds ~100ms
const paragraphs = savedData.segments.map((seg, idx) => ({
  text: seg.text,
  start: seg.start,
  end: seg.end,
  speaker: seg.speaker || 'Speaker',
  words: seg.words || [],
  id: `p-${idx}`
}));

processedData = {
  paragraphs: paragraphs,
  speakers: [...new Set(paragraphs.map(p => p.speaker))],
  stats: calculateStats(paragraphs)
};

renderEditor();
```

### 6.5 Rendering Process

```javascript
function renderEditor() {
  const container = document.querySelector('.editor-content');

  processedData.paragraphs.forEach((para, index) => {
    // Create paragraph container
    const paraDiv = createParagraphElement(para, index);

    // Add speaker label
    const speakerLabel = createSpeakerLabel(para.speaker);
    paraDiv.appendChild(speakerLabel);

    // Add words with timestamps
    const textDiv = createTextWithTimestamps(para);
    paraDiv.appendChild(textDiv);

    container.appendChild(paraDiv);
  });

  // Initialize playback sync
  initializePlaybackSync();
}
```

### 6.6 Word-Level Highlighting

```javascript
function highlightWordAtTime(currentTime) {
  // Find word at current playback time
  const word = findWordAtTime(currentTime);

  if (word) {
    // Remove previous highlight
    document.querySelectorAll('.word-highlight').forEach(el =>
      el.classList.remove('word-highlight')
    );

    // Add highlight to current word
    word.element.classList.add('word-highlight');

    // Scroll into view if needed
    word.element.scrollIntoViewIfNeeded();
  }
}
```

---

## 7. Data Formats

### 7.1 Segments Format (Raw Transcription Output)

**Source:** WhisperX / Faster-Whisper output
**Files:** `transcription-chunk-*.json`

```json
{
  "segments": [
    {
      "id": 0,
      "start": 0.0,
      "end": 5.84,
      "text": " Hello everyone, welcome to the meeting.",
      "speaker": "SPEAKER_00",
      "words": [
        {
          "word": "Hello",
          "start": 0.0,
          "end": 0.48,
          "score": 0.92
        }
      ]
    }
  ],
  "language": "en",
  "duration": 3600.0
}
```

**Field Definitions:**

| Field | Type | Description |
|-------|------|-------------|
| `segments` | array | List of transcribed segments |
| `segments[].id` | number | Segment index |
| `segments[].start` | number | Start time in seconds |
| `segments[].end` | number | End time in seconds |
| `segments[].text` | string | Transcribed text |
| `segments[].speaker` | string | Speaker ID (SPEAKER_00, etc.) |
| `segments[].words` | array | Word-level timestamps |
| `language` | string | Detected language code |
| `duration` | number | Total audio duration |

### 7.2 Paragraphs Format (Editor-Ready)

**Source:** Postprocessing script output
**Files:** `transcription-processed.json`

```json
{
  "paragraphs": [
    {
      "id": "para-chunk-001",
      "text": "Hello everyone, welcome to the meeting.",
      "start": 0.0,
      "end": 5.84,
      "speaker": "Speaker 1",
      "words": [
        {
          "word": "Hello",
          "start": 0.0,
          "end": 0.48
        }
      ],
      "chunkIds": ["chunk-001"],
      "chunkIndex": 0
    }
  ],
  "speakers": ["Speaker 1", "Speaker 2"],
  "stats": {
    "paragraphCount": 45,
    "totalWords": 1250,
    "totalDuration": 3600.0,
    "wordsPerMinute": 125
  },
  "metadata": {
    "processedAt": "2025-12-17T15:45:30.000Z",
    "version": "2.0"
  }
}
```

**Field Definitions:**

| Field | Type | Description |
|-------|------|-------------|
| `paragraphs` | array | List of paragraphs for display |
| `paragraphs[].id` | string | Unique paragraph identifier |
| `paragraphs[].text` | string | Full paragraph text |
| `paragraphs[].start` | number | Start time (absolute) |
| `paragraphs[].end` | number | End time (absolute) |
| `paragraphs[].speaker` | string | Human-readable speaker name |
| `paragraphs[].words` | array | Word timestamps |
| `speakers` | array | List of speaker names (strings) |
| `stats` | object | Computed statistics |

### 7.3 Metadata Format

**File:** `metadata.json`

```json
{
  "sessionId": "20251217-143022-upload-a1b2c3d4e5f6",
  "userId": "017bf540-7071-7065-c0ac-6f0a40f4c031",
  "userEmail": "user@example.com",
  "createdAt": "2025-12-17T14:30:22.000Z",
  "updatedAt": "2025-12-17T15:45:30.000Z",
  "source": "upload",
  "originalFilename": "meeting-recording.mp3",
  "status": "complete",
  "chunkCount": 1,
  "chunks": [
    {
      "chunkNumber": 1,
      "filename": "chunk-001.mp3",
      "size": 15728640,
      "uploadedAt": "2025-12-17T14:30:22.000Z"
    }
  ],
  "diarization": {
    "minSpeakers": 1,
    "maxSpeakers": 4
  },
  "transcription": {
    "status": "complete",
    "jobId": "job-abc123",
    "completedAt": "2025-12-17T15:30:00.000Z",
    "processedAt": "2025-12-17T15:45:30.000Z"
  }
}
```

---

## 8. S3 Storage Structure

### 8.1 Complete Session Structure

```
s3://clouddrive-app-bucket/
└── users/
    └── {userId}/                                    # Cognito user ID
        └── audio/
            └── sessions/
                └── {sessionId}/                     # Unique session ID
                    │
                    │   # Core Files
                    ├── metadata.json                # Session metadata
                    ├── chunk-001.mp3                # Original audio (upload)
                    │   (or chunk-001.webm)          # Original audio (recording)
                    │
                    │   # Transcription Files
                    ├── transcription-chunk-001.json # Raw transcription (segments)
                    ├── transcription-chunk-002.json # (if multiple chunks)
                    ├── transcription-processed.json # Processed (paragraphs)
                    ├── transcription-diarized.json  # With speaker labels
                    │
                    │   # Markers
                    ├── .transcription-complete      # Transcription done marker
                    │
                    │   # Optional: Layer Architecture
                    └── layers/
                        ├── layer-0-raw-transcription/
                        │   └── chunk-001.json
                        ├── layer-1-diarization/
                        │   └── data.json
                        └── layer-3-topic-segments/
                            └── data.json
```

### 8.2 Naming Conventions

| Pattern | Description | Example |
|---------|-------------|---------|
| `{sessionId}` | Timestamp + type + UUID | `20251217-143022-upload-a1b2c3d4e5f6` |
| `chunk-{NNN}` | Zero-padded chunk number | `chunk-001`, `chunk-012` |
| `transcription-chunk-{NNN}.json` | Raw transcription | `transcription-chunk-001.json` |
| `.{marker}` | Hidden marker files | `.transcription-complete` |

---

## 9. API Reference

### 9.1 Audio Upload APIs

#### POST /api/audio/upload-file

Generate presigned URL for direct S3 upload.

**Request:**
```json
{
  "filename": "meeting.mp3",
  "mimeType": "audio/mpeg",
  "fileSize": 15728640
}
```

**Response:**
```json
{
  "uploadUrl": "https://s3...",
  "sessionId": "20251217-143022-upload-...",
  "s3Key": "users/.../chunk-001.mp3",
  "expiresIn": 900
}
```

#### POST /api/audio/session-metadata

Create or update session metadata.

**Request:**
```json
{
  "sessionId": "20251217-143022-upload-...",
  "metadata": {
    "source": "upload",
    "originalFilename": "meeting.mp3",
    ...
  }
}
```

#### GET /api/audio/sessions

List all audio sessions for current user.

**Response:**
```json
{
  "sessions": [
    {
      "sessionId": "20251217-143022-upload-...",
      "createdAt": "2025-12-17T14:30:22.000Z",
      "status": "complete",
      "transcription": { "status": "complete" }
    }
  ]
}
```

### 9.2 File Access APIs

#### GET /api/s3/download/{key}

Generate presigned download URL.

**Response:**
```json
{
  "downloadUrl": "https://s3...",
  "expiresIn": 900
}
```

#### GET /api/s3/list

List files in user's S3 path.

**Query Parameters:**
- `prefix`: S3 prefix to list
- `userScope`: If true, prepends user's path

**Response:**
```json
{
  "files": [
    {
      "key": "users/.../file.json",
      "displayKey": "file.json",
      "size": 12345,
      "lastModified": "2025-12-17T14:30:22.000Z"
    }
  ]
}
```

---

## 10. Scripts Reference

### 10.1 Batch Transcription Scripts

| Script | Purpose | Provider |
|--------|---------|----------|
| `515-runpod--batch-transcribe.sh` | Batch transcription | RunPod GPU |
| `515-aws--batch-transcribe.sh` | Batch transcription | AWS EC2 GPU |
| `512-scan-missing-chunks.sh` | Find sessions needing transcription | N/A |

### 10.2 Postprocessing Scripts

| Script | Purpose |
|--------|---------|
| `518-postprocess-transcripts.sh` | Main postprocessing orchestrator |
| `scripts/lib/deduplicate-transcript-boundaries.js` | Remove duplicate words |
| `scripts/lib/format-transcript-rules.js` | Apply formatting rules |
| `scripts/lib/update-session-metadata.js` | Update metadata status |

### 10.3 GPU Management Scripts

| Script | Purpose |
|--------|---------|
| `850-runpod--start.sh` | Start RunPod instance |
| `851-runpod--status.sh` | Check RunPod status |
| `855-runpod--stop.sh` | Stop RunPod instance |
| `820-aws--startup-restore.sh` | Start AWS EC2 GPU |
| `810-aws--shutdown-gpu.sh` | Stop AWS EC2 GPU |

### 10.4 UI Deployment

| Script | Purpose |
|--------|---------|
| `425-deploy-recorder-ui.sh` | Deploy UI to S3/CloudFront |

---

## 11. Known Gaps & Future Improvements

### 11.1 RESOLVED: Automatic Postprocessing (Fixed 2025-12-17)

**Previous Problem:** Postprocessing had to be run manually after batch transcription.

**Solution Implemented:**
- Added automatic 518 script call at end of `515-runpod--batch-transcribe.sh`
- `515-aws--batch-transcribe.sh` already had this in Phase 4

**Additional Safety:** Browser-side conversion handles both `segments` and `paragraphs` formats as a fallback.

### 11.2 Future Improvements

#### Automatic Pipeline Orchestration
- EventBridge events for each stage
- Step Functions for workflow management
- Automatic retry on failures

#### Real-Time Processing
- Stream transcription during upload
- Progressive display as processing completes

#### Enhanced Diarization
- Custom speaker names
- Speaker voice profiles
- Cross-session speaker identification

#### Quality Improvements
- Confidence scores displayed
- Manual correction interface
- Feedback loop to improve accuracy

---

## Appendix A: Glossary

| Term | Definition |
|------|------------|
| **Chunk** | A segment of audio, typically 2 minutes for recordings |
| **Diarization** | Process of identifying who spoke when |
| **Segment** | A continuous speech segment with timestamps |
| **Paragraph** | Editor-ready grouping of segments |
| **Presigned URL** | Temporary S3 URL with embedded authentication |
| **WhisperX** | Enhanced Whisper with word-level timestamps |

## Appendix B: Troubleshooting

### Editor Shows "Loading..." Forever

1. Check browser console for errors
2. Verify transcription files exist in S3
3. Check file format (segments vs paragraphs)
4. Run postprocessing if needed

### Transcription Missing

1. Check `.transcription-complete` marker exists
2. Run `512-scan-missing-chunks.sh` to find gaps
3. Re-run batch transcription for missing sessions

### Speaker Labels Wrong

1. Check diarization settings (min/max speakers)
2. Verify audio quality (clear speech, low noise)
3. Re-run transcription with adjusted settings

---

*Document generated for CloudDrive Audio Transcription Platform*
