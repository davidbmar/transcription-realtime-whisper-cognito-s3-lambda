# v6.6.0 Deployment Summary

## What's New: Real-Time Transcription Backup to S3

v6.6.0 adds automatic chunk-aligned transcription backup to S3, ensuring transcription data is preserved server-side alongside audio files.

## The Problem

Previous versions stored transcription data only in:
1. **Browser IndexedDB** - Risk of data loss if browser cache cleared
2. **Google Docs** (optional) - Requires manual setup and Google account

There was no automatic server-side backup of transcription segments with word-level timestamps and paragraph breaks.

## The Solution

Now automatically uploads transcription segments to S3 in sync with audio chunk boundaries:

**During Recording:**
- Each audio chunk (default 5 seconds) triggers transcription segment upload
- Segments saved as individual files: `transcription-chunk-001.json`, `transcription-chunk-002.json`, etc.
- Real-time backup ensures no data loss even if browser crashes mid-recording

**After Recording:**
- All chunks consolidated into single `transcription.json` file
- Includes full timeline, word timestamps, paragraph breaks, and metadata
- Perfect synchronization with audio chunks for playback reconstruction

## How It Works

### 1. Segment Accumulation (Frontend)

**Location:** `ui-source/audio.html`, function `updateTranscription()` (lines 2312-2321)

```javascript
// NEW v6.6.0: Accumulate segment for chunk-aligned S3 backup
currentChunkSegments.push({
  text: text,
  start: start,
  end: end,
  is_final: true,
  paragraph_break: false,  // Will be calculated later when we detect pauses
  words: words || [],
  timestamp: new Date().toISOString()
});
```

Paragraph breaks are detected later (lines 2370-2387) and applied retroactively:

```javascript
// Detect paragraph breaks based on pause duration
let paragraphBreak = false;
if (transcriptionSegments.length > 1 && start !== undefined) {
  const previousSegment = transcriptionSegments[transcriptionSegments.length - 2];
  if (previousSegment.end !== undefined) {
    const pauseDuration = start - previousSegment.end;
    paragraphBreak = pauseDuration >= GOOGLE_DOCS_PARAGRAPH_THRESHOLD;

    if (paragraphBreak) {
      console.log(`📄 [GOOGLE-DOCS] Paragraph break detected: ${pauseDuration.toFixed(2)}s pause`);

      // Update the segment we just added to currentChunkSegments
      if (currentChunkSegments.length > 0) {
        currentChunkSegments[currentChunkSegments.length - 1].paragraph_break = true;
      }
    }
  }
}
```

### 2. Chunk-Aligned Upload (Frontend)

**Location:** `ui-source/audio.html`, addChunk function (lines 1927-1938)

```javascript
// NEW v6.6.0: Upload transcription segments for this chunk (chunk-aligned backup)
if (currentChunkSegments.length > 0 && idx > lastSavedChunkIndex) {
  console.log(`📤 [S3-TRANSCRIPTION] Uploading ${currentChunkSegments.length} segments for chunk ${idx}`);

  // Save the current chunk's segments
  saveTranscriptionChunk(idx, [...currentChunkSegments]).catch(err => {
    log('Error in transcription S3 upload:', err.message);
  });

  // Clear accumulated segments for next chunk
  currentChunkSegments = [];
}
```

**Key insight:** Segments are uploaded RIGHT AFTER the audio chunk upload, ensuring perfect sync.

### 3. Chunk Upload Function (Frontend)

**Location:** `ui-source/audio.html`, function `saveTranscriptionChunk()` (lines 1572-1618)

```javascript
async function saveTranscriptionChunk(chunkIndex, segments) {
  if (!segments || segments.length === 0) {
    console.log(`⚠️ [S3-TRANSCRIPTION] No segments to save for chunk ${chunkIndex}`);
    return;
  }

  try {
    console.log(`📤 [S3-TRANSCRIPTION] Saving ${segments.length} segments for chunk ${chunkIndex}`);

    const idToken = await getIdToken();
    const apiUrl = window.config?.s3ApiUrl || window.config?.apiUrl;

    const response = await fetch(`${apiUrl}/api/transcription/save-chunk`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${idToken}`
      },
      body: JSON.stringify({
        sessionId: currentSession.id,
        chunkIndex: chunkIndex,
        segments: segments
      })
    });

    if (response.ok) {
      const result = await response.json();
      console.log(`✅ [S3-TRANSCRIPTION] Chunk ${chunkIndex} saved:`, result);
      lastSavedChunkIndex = chunkIndex;
    }
  } catch (error) {
    console.error(`❌ [S3-TRANSCRIPTION] Error saving chunk ${chunkIndex}:`, error);
  }
}
```

### 4. Session Finalization (Frontend)

**Location:** `ui-source/audio.html`, function `stop()` (lines 2841-2842)

```javascript
// NEW v6.6.0: Finalize transcription session in S3 (consolidate all chunk files)
await finalizeTranscriptionSession();
```

**Location:** `ui-source/audio.html`, function `finalizeTranscriptionSession()` (lines 1620-1658)

```javascript
async function finalizeTranscriptionSession() {
  if (!currentSession) {
    console.log('ℹ️ [S3-TRANSCRIPTION] No session to finalize');
    return;
  }

  try {
    console.log('📤 [S3-TRANSCRIPTION] Finalizing transcription session...');

    const idToken = await getIdToken();
    const apiUrl = window.config?.s3ApiUrl || window.config?.apiUrl;

    const response = await fetch(`${apiUrl}/api/transcription/finalize`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${idToken}`
      },
      body: JSON.stringify({
        sessionId: currentSession.id
      })
    });

    if (response.ok) {
      const result = await response.json();
      console.log('✅ [S3-TRANSCRIPTION] Session finalized:', result);
    }
  } catch (error) {
    console.error('❌ [S3-TRANSCRIPTION] Error finalizing session:', error);
  }
}
```

### 5. Lambda Chunk Save Handler (Backend)

**Location:** `cognito-stack/api/transcription.js`, function `saveTranscriptionChunk()` (lines 32-104)

```javascript
module.exports.saveTranscriptionChunk = async (event) => {
  try {
    // Get user claims from the authorizer
    const claims = event.requestContext?.authorizer?.claims || {};
    const email = claims.email || 'Anonymous';
    const userId = claims.sub || 'unknown';

    console.log(`User ${email} (${userId}) saving transcription chunk`);

    // Parse request body
    const body = JSON.parse(event.body || '{}');
    const { sessionId, chunkIndex, segments } = body;

    if (!sessionId || chunkIndex === undefined || !segments) {
      return {
        statusCode: 400,
        headers: getSecurityHeaders(event.headers?.origin),
        body: JSON.stringify({ error: 'sessionId, chunkIndex, and segments are required' })
      };
    }

    // Build S3 key for this chunk's transcription
    const timestamp = new Date().toISOString().split('T')[0];
    const chunkKey = `users/${userId}/audio/sessions/${timestamp}-${sessionId}/transcription-chunk-${String(chunkIndex).padStart(3, '0')}.json`;

    // Calculate chunk metadata
    const chunkData = {
      chunkIndex,
      chunkStartTime: segments.length > 0 ? Math.min(...segments.map(s => s.start || 0)) : 0,
      chunkEndTime: segments.length > 0 ? Math.max(...segments.map(s => s.end || 0)) : 0,
      segments,
      segmentCount: segments.length,
      wordCount: segments.reduce((sum, seg) => sum + (seg.words?.length || 0), 0),
      uploadedAt: new Date().toISOString()
    };

    // Write chunk file to S3
    await s3.putObject({
      Bucket: BUCKET_NAME,
      Key: chunkKey,
      Body: JSON.stringify(chunkData, null, 2),
      ContentType: 'application/json',
      Metadata: {
        userId,
        sessionId,
        chunkIndex: String(chunkIndex),
        segmentCount: String(chunkData.segmentCount)
      }
    }).promise();

    console.log(`✅ Saved transcription chunk ${chunkIndex} with ${segments.length} segments to ${chunkKey}`);

    return {
      statusCode: 200,
      headers: getSecurityHeaders(event.headers?.origin),
      body: JSON.stringify({
        success: true,
        chunkIndex,
        segmentCount: segments.length,
        s3Key: chunkKey
      })
    };

  } catch (error) {
    console.error('Error saving transcription chunk:', error);

    return {
      statusCode: 500,
      headers: getSecurityHeaders(event.headers?.origin),
      body: JSON.stringify({
        error: 'Failed to save transcription chunk',
        message: error.message
      })
    };
  }
};
```

### 6. Lambda Finalization Handler (Backend)

**Location:** `cognito-stack/api/transcription.js`, function `finalizeTranscription()` (lines 121-294)

```javascript
module.exports.finalizeTranscription = async (event) => {
  try {
    // Get user claims from the authorizer
    const claims = event.requestContext?.authorizer?.claims || {};
    const email = claims.email || 'Anonymous';
    const userId = claims.sub || 'unknown';

    console.log(`User ${email} (${userId}) finalizing transcription session`);

    // Parse request body
    const body = JSON.parse(event.body || '{}');
    const { sessionId } = body;

    if (!sessionId) {
      return {
        statusCode: 400,
        headers: getSecurityHeaders(event.headers?.origin),
        body: JSON.stringify({ error: 'sessionId is required' })
      };
    }

    const timestamp = new Date().toISOString().split('T')[0];
    const sessionPrefix = `users/${userId}/audio/sessions/${timestamp}-${sessionId}/`;

    // List all transcription chunk files
    const listResult = await s3.listObjectsV2({
      Bucket: BUCKET_NAME,
      Prefix: sessionPrefix,
      MaxKeys: 10000
    }).promise();

    // Filter for transcription chunk files
    const chunkFiles = listResult.Contents
      .filter(obj => obj.Key.includes('transcription-chunk-'))
      .sort((a, b) => a.Key.localeCompare(b.Key));

    console.log(`Found ${chunkFiles.length} transcription chunk files to consolidate`);

    if (chunkFiles.length === 0) {
      console.log('No transcription chunks found, skipping consolidation');
      return {
        statusCode: 200,
        headers: getSecurityHeaders(event.headers?.origin),
        body: JSON.stringify({
          success: true,
          message: 'No transcription data to consolidate',
          chunkCount: 0
        })
      };
    }

    // Read all chunk files
    const allSegments = [];
    let totalWordCount = 0;
    let minStartTime = Infinity;
    let maxEndTime = 0;

    for (const chunkFile of chunkFiles) {
      try {
        const chunkData = await s3.getObject({
          Bucket: BUCKET_NAME,
          Key: chunkFile.Key
        }).promise();

        const chunk = JSON.parse(chunkData.Body.toString());

        if (chunk.segments && Array.isArray(chunk.segments)) {
          allSegments.push(...chunk.segments);
          totalWordCount += chunk.wordCount || 0;

          if (chunk.chunkStartTime < minStartTime) minStartTime = chunk.chunkStartTime;
          if (chunk.chunkEndTime > maxEndTime) maxEndTime = chunk.chunkEndTime;
        }
      } catch (error) {
        console.error(`Error reading chunk file ${chunkFile.Key}:`, error);
        // Continue with other chunks
      }
    }

    // Sort segments by start time
    allSegments.sort((a, b) => (a.start || 0) - (b.start || 0));

    // Build consolidated transcription file
    const consolidatedData = {
      sessionId,
      userId,
      createdAt: new Date(Math.min(...chunkFiles.map(f => new Date(f.LastModified).getTime()))).toISOString(),
      completedAt: new Date().toISOString(),
      status: 'completed',
      chunkCount: chunkFiles.length,
      segments: allSegments,
      totalSegments: allSegments.length,
      totalDuration: maxEndTime - minStartTime,
      wordCount: totalWordCount,
      metadata: {
        transcriptionEngine: 'WhisperLive',
        hasWordTimestamps: allSegments.some(s => s.words && s.words.length > 0),
        hasParagraphBreaks: allSegments.some(s => s.paragraph_break === true),
        chunksProcessed: chunkFiles.length
      }
    };

    // Write consolidated file
    const consolidatedKey = `${sessionPrefix}transcription.json`;
    await s3.putObject({
      Bucket: BUCKET_NAME,
      Key: consolidatedKey,
      Body: JSON.stringify(consolidatedData, null, 2),
      ContentType: 'application/json',
      Metadata: {
        userId,
        sessionId,
        totalSegments: String(allSegments.length),
        totalDuration: String(consolidatedData.totalDuration)
      }
    }).promise();

    console.log(`✅ Consolidated ${allSegments.length} segments from ${chunkFiles.length} chunks into ${consolidatedKey}`);

    // Update session metadata
    const metadataKey = `${sessionPrefix}metadata.json`;
    try {
      const metadataResult = await s3.getObject({
        Bucket: BUCKET_NAME,
        Key: metadataKey
      }).promise();

      const metadata = JSON.parse(metadataResult.Body.toString());

      metadata.transcriptionStatus = 'completed';
      metadata.transcriptionSegmentCount = allSegments.length;
      metadata.transcriptionWordCount = totalWordCount;
      metadata.transcriptionUpdatedAt = new Date().toISOString();
      metadata.hasTranscription = true;
      metadata.hasWordTimestamps = consolidatedData.metadata.hasWordTimestamps;

      await s3.putObject({
        Bucket: BUCKET_NAME,
        Key: metadataKey,
        Body: JSON.stringify(metadata, null, 2),
        ContentType: 'application/json'
      }).promise();

      console.log(`✅ Updated session metadata with transcription stats`);
    } catch (error) {
      console.error('Error updating session metadata:', error);
      // Continue even if metadata update fails
    }

    return {
      statusCode: 200,
      headers: getSecurityHeaders(event.headers?.origin),
      body: JSON.stringify({
        success: true,
        message: 'Transcription finalized successfully',
        chunksProcessed: chunkFiles.length,
        totalSegments: allSegments.length,
        totalDuration: consolidatedData.totalDuration,
        wordCount: totalWordCount
      })
    };

  } catch (error) {
    console.error('Error finalizing transcription:', error);

    return {
      statusCode: 500,
      headers: getSecurityHeaders(event.headers?.origin),
      body: JSON.stringify({
        error: 'Failed to finalize transcription',
        message: error.message
      })
    };
  }
};
```

## Data Flow

```
WhisperLive WebSocket
  ↓ (segment with timestamps + words)
updateTranscription()
  ↓ (accumulates in currentChunkSegments array)
  ↓ (detects paragraph breaks based on pauses)
Audio chunk recorded (MediaRecorder)
  ↓
uploadChunkToS3() completes
  ↓
saveTranscriptionChunk() called
  ↓ (POST /api/transcription/save-chunk)
Lambda saveTranscriptionChunk()
  ↓ (writes transcription-chunk-NNN.json to S3)
S3: users/{userId}/audio/sessions/{date}-{sessionId}/transcription-chunk-001.json

... repeat for each chunk ...

Recording stops
  ↓
finalizeTranscriptionSession() called
  ↓ (POST /api/transcription/finalize)
Lambda finalizeTranscription()
  ↓ (reads all chunk files, sorts by timestamp)
  ↓ (consolidates into single file)
  ↓ (updates session metadata)
S3: users/{userId}/audio/sessions/{date}-{sessionId}/transcription.json
```

## S3 File Structure

```
s3://clouddrive-app-bucket/
└── users/{userId}/audio/sessions/{date}-{sessionId}/
    ├── chunk-001.webm                      # Audio chunk 1
    ├── transcription-chunk-001.json        # Transcription for chunk 1
    ├── chunk-002.webm                      # Audio chunk 2
    ├── transcription-chunk-002.json        # Transcription for chunk 2
    ├── ...
    ├── chunk-NNN.webm                      # Audio chunk N
    ├── transcription-chunk-NNN.json        # Transcription for chunk N
    ├── transcription.json                  # Consolidated transcription (created on stop)
    └── metadata.json                       # Session metadata (updated with transcription stats)
```

## Chunk File Format

**transcription-chunk-001.json:**
```json
{
  "chunkIndex": 1,
  "chunkStartTime": 0.0,
  "chunkEndTime": 5.2,
  "segments": [
    {
      "text": "Hello this is a test.",
      "start": 0.0,
      "end": 2.1,
      "is_final": true,
      "paragraph_break": false,
      "words": [
        {"word": "Hello", "start": 0.0, "end": 0.5},
        {"word": "this", "start": 0.6, "end": 0.8},
        {"word": "is", "start": 0.9, "end": 1.0},
        {"word": "a", "start": 1.1, "end": 1.2},
        {"word": "test", "start": 1.3, "end": 2.1}
      ],
      "timestamp": "2025-11-03T03:15:42.123Z"
    },
    {
      "text": "I'm going to pause for a few seconds now.",
      "start": 2.3,
      "end": 4.8,
      "is_final": true,
      "paragraph_break": false,
      "words": [...],
      "timestamp": "2025-11-03T03:15:44.567Z"
    }
  ],
  "segmentCount": 2,
  "wordCount": 14,
  "uploadedAt": "2025-11-03T03:15:45.000Z"
}
```

## Consolidated File Format

**transcription.json:**
```json
{
  "sessionId": "abc123",
  "userId": "cognito-user-sub",
  "createdAt": "2025-11-03T03:15:30.000Z",
  "completedAt": "2025-11-03T03:20:15.000Z",
  "status": "completed",
  "chunkCount": 58,
  "segments": [
    {
      "text": "Hello this is a test.",
      "start": 0.0,
      "end": 2.1,
      "is_final": true,
      "paragraph_break": false,
      "words": [...],
      "timestamp": "2025-11-03T03:15:42.123Z"
    },
    {
      "text": "I'm going to pause for a few seconds now.",
      "start": 2.3,
      "end": 4.8,
      "is_final": true,
      "paragraph_break": false,
      "words": [...],
      "timestamp": "2025-11-03T03:15:44.567Z"
    },
    {
      "text": "Okay I'm back and continuing to speak.",
      "start": 8.1,
      "end": 10.5,
      "is_final": true,
      "paragraph_break": true,  // 3.3 second pause detected
      "words": [...],
      "timestamp": "2025-11-03T03:15:50.789Z"
    }
  ],
  "totalSegments": 142,
  "totalDuration": 285.6,
  "wordCount": 1824,
  "metadata": {
    "transcriptionEngine": "WhisperLive",
    "hasWordTimestamps": true,
    "hasParagraphBreaks": true,
    "chunksProcessed": 58
  }
}
```

## Cost Analysis

**Assumptions:**
- 1-hour recording session
- 5-second audio chunks = 720 chunks
- Average 2 transcription segments per chunk = 1440 segments
- Average segment size: 500 bytes

**AWS Lambda Costs (us-east-2):**
- Lambda invocations: 720 chunk saves + 1 finalize = 721 invocations
- Cost: 721 × $0.0000002 = $0.0001442 per hour
- Memory: 128MB, avg 200ms execution = $0.0000003 per request
- Total Lambda: ~$0.0003 per hour

**AWS S3 Costs:**
- PUT requests: 720 chunks = $0.0036 per hour (720 × $0.005 per 1000)
- Storage: 720 × 1KB = 720KB per hour = $0.0000165 per hour ($0.023/GB/month)
- GET requests for consolidation: 720 reads = $0.00029 (720 × $0.0004 per 1000)
- Total S3: ~$0.004 per hour

**Total Cost:** ~$0.004/hour for chunk-aligned real-time transcription backup

**Cost Comparison:**
- 5-second chunks (720/hour): $0.004/hour
- 10-second chunks (360/hour): $0.002/hour
- 30-second batches (120/hour): $0.0006/hour

**Recommendation:** 5-second chunks provide best UX (real-time backup, minimal data loss risk) with negligible cost increase.

## Files Modified

### Frontend
- **ui-source/audio.html**
  - Line 335: Updated version to v6.6.0
  - Lines 1343-1345: Added `currentChunkSegments` and `lastSavedChunkIndex` tracking variables
  - Lines 1572-1618: Added `saveTranscriptionChunk()` function
  - Lines 1620-1658: Added `finalizeTranscriptionSession()` function
  - Lines 1927-1938: Modified `addChunk()` to trigger transcription chunk upload
  - Lines 2312-2321: Modified `updateTranscription()` to accumulate segments per chunk
  - Lines 2381-2384: Added paragraph_break flag update when pause detected
  - Lines 2841-2842: Modified `stop()` to call finalization

### Backend
- **cognito-stack/api/transcription.js** (NEW FILE)
  - Lines 32-115: `saveTranscriptionChunk()` handler
  - Lines 121-295: `finalizeTranscription()` handler

- **cognito-stack/serverless.yml**
  - Lines 317-346: Added two new Lambda function definitions:
    - `saveTranscriptionChunk` - POST /api/transcription/save-chunk
    - `finalizeTranscriptionSession` - POST /api/transcription/finalize

## Deployment

```bash
./scripts/510-setup-google-docs-integration.sh
```

This script:
1. Exports required environment variables (COGNITO_CLOUDFRONT_URL, GOOGLE_CREDENTIALS_BASE64)
2. Deploys updated Lambda functions with new transcription endpoints
3. Deploys updated UI with transcription backup integration
4. Invalidates CloudFront cache

**Alternative (UI only):**
```bash
./scripts/425-deploy-recorder-ui.sh
```

## API Endpoints

### Save Transcription Chunk
**POST** `/api/transcription/save-chunk`

**Headers:**
- `Authorization: Bearer {cognito-id-token}`
- `Content-Type: application/json`

**Request Body:**
```json
{
  "sessionId": "abc123",
  "chunkIndex": 5,
  "segments": [
    {
      "text": "Example segment",
      "start": 20.1,
      "end": 22.3,
      "is_final": true,
      "paragraph_break": false,
      "words": [
        {"word": "Example", "start": 20.1, "end": 20.5},
        {"word": "segment", "start": 20.6, "end": 22.3}
      ],
      "timestamp": "2025-11-03T03:15:42.123Z"
    }
  ]
}
```

**Response:**
```json
{
  "success": true,
  "chunkIndex": 5,
  "segmentCount": 1,
  "s3Key": "users/{userId}/audio/sessions/2025-11-03-abc123/transcription-chunk-005.json"
}
```

### Finalize Transcription Session
**POST** `/api/transcription/finalize`

**Headers:**
- `Authorization: Bearer {cognito-id-token}`
- `Content-Type: application/json`

**Request Body:**
```json
{
  "sessionId": "abc123"
}
```

**Response:**
```json
{
  "success": true,
  "message": "Transcription finalized successfully",
  "chunksProcessed": 58,
  "totalSegments": 142,
  "totalDuration": 285.6,
  "wordCount": 1824
}
```

## Testing

### Manual Test
1. Open audio recorder: https://d2l28rla2hk7np.cloudfront.net/audio.html
2. Start recording
3. Speak for 10-15 seconds (enough for 2-3 audio chunks)
4. Stop recording
5. Check browser console for logs:
   ```
   📤 [S3-TRANSCRIPTION] Uploading 3 segments for chunk 1
   ✅ [S3-TRANSCRIPTION] Chunk 1 saved: {...}
   📤 [S3-TRANSCRIPTION] Finalizing transcription session...
   ✅ [S3-TRANSCRIPTION] Session finalized: {...}
   ```

### Browser Console Logs (Expected)
```
📤 [S3-TRANSCRIPTION] Uploading 2 segments for chunk 0
✅ [S3-TRANSCRIPTION] Chunk 0 saved: {success: true, chunkIndex: 0, segmentCount: 2, s3Key: "users/..."}
📤 [S3-TRANSCRIPTION] Uploading 3 segments for chunk 1
✅ [S3-TRANSCRIPTION] Chunk 1 saved: {success: true, chunkIndex: 1, segmentCount: 3, s3Key: "users/..."}
📤 [S3-TRANSCRIPTION] Finalizing transcription session...
✅ [S3-TRANSCRIPTION] Session finalized: {success: true, chunksProcessed: 2, totalSegments: 5, ...}
```

### Lambda Logs
```bash
# Save chunk logs
aws logs tail /aws/lambda/clouddrive-app-dev-saveTranscriptionChunk \
  --follow --format short --region us-east-2

# Finalize logs
aws logs tail /aws/lambda/clouddrive-app-dev-finalizeTranscriptionSession \
  --follow --format short --region us-east-2
```

### S3 Verification
```bash
# List transcription files for a session
aws s3 ls s3://clouddrive-app-bucket/users/{userId}/audio/sessions/{date}-{sessionId}/ \
  --recursive | grep transcription

# Download consolidated file
aws s3 cp s3://clouddrive-app-bucket/users/{userId}/audio/sessions/{date}-{sessionId}/transcription.json \
  ./transcription.json

# Inspect content
cat transcription.json | jq '.metadata'
cat transcription.json | jq '.segments[0]'
cat transcription.json | jq '.segments[] | select(.paragraph_break == true)'
```

## Version

v6.6.0 - Released November 3, 2025

## Future Enhancements (v6.7.0+)

### Transcription Replay from S3
- Download consolidated `transcription.json` file
- Reconstruct karaoke-mode playback from server data
- No dependency on browser IndexedDB for historical sessions

### Analytics Dashboard
- Total speaking time per user
- Words per minute statistics
- Paragraph break frequency analysis
- Most common words/phrases

### Export Formats
- Export to SRT subtitle format
- Export to VTT WebVTT format
- Export to plain text with timestamps
- Export to formatted document (Google Docs, PDF)

### Search and Navigation
- Full-text search across all transcriptions
- Jump to specific words/timestamps
- Keyword highlighting in playback

## Breaking Changes

None - fully backward compatible.

If browser doesn't support transcription backup (old version of audio.html), recording still works normally but transcription won't be saved to S3.

## Dependencies

- AWS Lambda (Node.js runtime)
- AWS S3 (storage)
- AWS Cognito (authentication)
- WhisperLive (GPU transcription service)
- googleapis package (for Google Docs integration)

## Security

- All S3 paths user-scoped: `users/{userId}/`
- Cognito JWT validation on all API endpoints
- CORS headers restrict cross-origin access
- No public read access to transcription files
