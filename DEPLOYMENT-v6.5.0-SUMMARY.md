# v6.5.0 Deployment Summary

## What's New: Intelligent Paragraph Breaks

v6.5.0 adds automatic paragraph formatting to Google Docs transcriptions based on natural speech pauses.

## The Problem

Previous versions concatenated all finalized text with single spaces, resulting in one long paragraph:

```
Hello this is a test. I'm going to pause for a few seconds now. Okay I'm back and continuing to speak. This should be a new paragraph but it's not.
```

## The Solution

Now detects speech pauses and automatically inserts paragraph breaks when pauses exceed 2.0 seconds:

```
Hello this is a test. I'm going to pause for a few seconds now.

Okay I'm back and continuing to speak. This should be a new paragraph and now it is!
```

## How It Works

### 1. Pause Detection (Frontend)

**Location:** `ui-source/audio.html`, function `updateTranscription()` (lines 2261-2273)

```javascript
// Calculate pause from previous segment
let paragraphBreak = false;
if (transcriptionSegments.length > 1 && start !== undefined) {
  const previousSegment = transcriptionSegments[transcriptionSegments.length - 2];
  if (previousSegment.end !== undefined) {
    const pauseDuration = start - previousSegment.end;
    paragraphBreak = pauseDuration >= GOOGLE_DOCS_PARAGRAPH_THRESHOLD; // 2.0 seconds

    if (paragraphBreak) {
      console.log(`📄 [GOOGLE-DOCS] Paragraph break detected: ${pauseDuration.toFixed(2)}s pause`);
    }
  }
}
```

### 2. Parameter Forwarding (Frontend)

**Location:** `ui-source/audio.html`

- `updateGoogleDocsLive()` extracts `paragraph_break` flag (line 1425)
- `finalizeGoogleDocsSegment()` includes it in API request (line 1514)

### 3. Formatting Logic (Backend)

**Location:** `cognito-stack/api/google-docs.js`, function `finalizeTranscription()` (lines 399-402)

```javascript
// Use paragraph break (\n\n) if pause exceeded threshold, otherwise just space
const separator = paragraph_break ? '\n\n' : ' ';
const finalizedText = text + separator;
```

## Configuration

### Default Threshold

```javascript
var GOOGLE_DOCS_PARAGRAPH_THRESHOLD = 2.0;  // seconds
```

**Location:** `ui-source/audio.html` (line 1341)

### Why 2.0 Seconds?

- **Research-based:** Industry standard for transcription paragraph breaks
- **Natural pauses:** Catches intentional speaker pauses
- **Avoids false positives:** Ignores normal speech rhythm pauses (< 2s)
- **Reliable detection:** 2s is long enough to be clearly intentional

### Future: Adjustable Threshold

Could be made user-configurable in Phase 2:
- Settings panel in UI
- Per-user preferences stored in localStorage or S3
- Typical range: 1.0s (aggressive) to 5.0s (conservative)

## Implementation Details

### Data Flow

```
WhisperLive WebSocket
  ↓ (segment with timestamps)
updateTranscription()
  ↓ (calculates pause, sets paragraph_break flag)
updateGoogleDocsLive()
  ↓ (forwards paragraph_break)
finalizeGoogleDocsSegment()
  ↓ (includes in API request)
Lambda finalizeTranscription()
  ↓ (inserts \n\n or ' ')
Google Docs API
  ↓
Document with paragraph breaks!
```

### Edge Cases Handled

1. **First segment:** No previous segment to compare, no paragraph break applied
2. **Missing timestamps:** Falls back to no paragraph break (safe default)
3. **Array index bounds:** Checks `transcriptionSegments.length > 1` before accessing
4. **Undefined checks:** Validates `start !== undefined` and `previousSegment.end !== undefined`

### Logging

Frontend logs (browser console):
```
📄 [GOOGLE-DOCS] Paragraph break detected: 3.45s pause
📤 [GOOGLE-DOCS-FINALIZE] Paragraph break: true
```

Backend logs (Lambda CloudWatch):
```
📄 Paragraph break requested for segment: "Okay I'm back and continuing to speak..."
```

## Files Modified

### Frontend
- **ui-source/audio.html**
  - Line 1341: Added `GOOGLE_DOCS_PARAGRAPH_THRESHOLD` constant
  - Lines 2261-2273: Pause detection logic in `updateTranscription()`
  - Lines 1422-1425: Extract `paragraph_break` in `updateGoogleDocsLive()`
  - Lines 1492-1495: Accept and forward in `finalizeGoogleDocsSegment()`

### Backend
- **cognito-stack/api/google-docs.js**
  - Line 323: Extract `paragraph_break` from request body
  - Lines 333-336: Log paragraph break events
  - Lines 399-402: Format with `\n\n` or ` ` based on flag

## Testing

### Manual Test
1. Open audio recorder: https://d2l28rla2hk7np.cloudfront.net/audio.html
2. Start recording
3. Speak a sentence, then pause for 3+ seconds
4. Speak another sentence
5. Check Google Doc - should show paragraph break

### Browser Console Logs
```
📄 [GOOGLE-DOCS] Paragraph break detected: 3.12s pause
```

### Lambda Logs
```bash
aws logs tail /aws/lambda/clouddrive-app-dev-finalizeGoogleDocsTranscription \
  --follow --format short --region us-east-2 | grep "Paragraph break"
```

### check-formatting.py
```bash
cd google-docs-test
./check-formatting.py
```

Should show multiple finalized text blocks separated by newlines.

## Deployment

```bash
./scripts/510-setup-google-docs-integration.sh
```

This script:
1. Deploys updated Lambda functions with paragraph break logic
2. Deploys updated UI with pause detection
3. Invalidates CloudFront cache

## Version

v6.5.0 - Released November 2, 2025

## Future Enhancements (v6.6.0+)

### Multi-Tier Thresholds
```javascript
const PAUSE_THRESHOLDS = {
  SENTENCE: 0.7,   // Add period
  PARAGRAPH: 2.0,  // Add \n\n
  SECTION: 5.0     // Add \n\n[5.2s pause]\n\n with annotation
};
```

### User Controls
- Settings panel in UI
- Slider to adjust threshold
- Preview mode showing where breaks will occur
- Per-user preference storage

### Visual Indicators
- Show paragraph break markers in frontend transcript
- Real-time preview of formatting
- Color coding for different pause durations

### Analytics
- Track average pause durations per user
- Suggest optimal threshold based on speaking style
- UX improvements based on usage patterns

## Breaking Changes

None - fully backward compatible. If frontend doesn't send `paragraph_break`, backend defaults to single space (original behavior).
