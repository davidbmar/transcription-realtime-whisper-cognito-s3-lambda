# WhisperLive Patches

This document describes patches applied to WhisperLive to enable word-level timestamps for karaoke-style highlighting in the browser client.

## Overview

Three patches are required to enable word-level timestamps:

1. **Enable word_timestamps in transcribe() call** - Request word data from faster-whisper
2. **Update format_segment() to accept words** - Allow word data to be included in segments
3. **Extract and pass word data** - Override update_segments() to extract words from faster-whisper and pass to format_segment()

## Patch 1: Enable Word-Level Timestamps in Transcribe

**File**: `whisper_live/backend/faster_whisper_backend.py`

**Issue**: The default WhisperLive installation does not request word-level timestamps from faster-whisper.

**Solution**: Modified the `transcribe()` call to include `word_timestamps=True` parameter.

### Change Details

**Original Code** (line ~120):
```python
result, info = self.transcriber.transcribe(
    input_sample,
    initial_prompt=self.initial_prompt,
    language=self.language,
    task=self.task,
    vad_filter=self.use_vad,
    vad_parameters=self.vad_parameters if self.use_vad else None)
```

**Patched Code**:
```python
result, info = self.transcriber.transcribe(
    input_sample,
    initial_prompt=self.initial_prompt,
    language=self.language,
    task=self.task,
    vad_filter=self.use_vad,
    vad_parameters=self.vad_parameters if self.use_vad else None,
    word_timestamps=True)
```

## Patch 2: Update format_segment() to Accept Words

**File**: `whisper_live/backend/base.py`

**Issue**: The `format_segment()` method only returns start, end, text, and completed - it doesn't include word-level data even if available.

**Solution**: Updated the method signature to accept an optional `words` parameter and include it in the returned segment if provided.

### Change Details

**Original Code**:
```python
def format_segment(self, start, end, text, completed=False):
    return {
        'start': "{:.3f}".format(start),
        'end': "{:.3f}".format(end),
        'text': text,
        'completed': completed
    }
```

**Patched Code**:
```python
def format_segment(self, start, end, text, completed=False, words=None):
    segment = {
        'start': "{:.3f}".format(start),
        'end': "{:.3f}".format(end),
        'text': text,
        'completed': completed
    }
    if words:
        segment['words'] = words
    return segment
```

## Patch 3: Extract and Pass Word Data with Absolute Timestamps

**File**: `whisper_live/backend/faster_whisper_backend.py`

**Issue**: Even with `word_timestamps=True`, the word data from faster-whisper segments is not being extracted and passed to `format_segment()`. Additionally, word timestamps from faster-whisper are **segment-relative** (starting from 0.0 for each segment), but must be converted to **absolute timestamps** for correct highlighting across multiple segments.

**Solution**:
1. Add `extract_words_from_segment(segment, segment_start_time)` helper method to extract word data
2. Convert segment-relative timestamps to absolute by adding `segment_start_time`
3. Override `update_segments()` to call this helper and pass words to `format_segment()`

### Change Details

**Added Helper Method**:
```python
def extract_words_from_segment(self, segment, segment_start_time):
    """
    Extract word-level timestamps from faster-whisper segment.

    IMPORTANT: Word timestamps from faster-whisper are segment-relative (start from 0.0),
    so we must add segment_start_time to convert them to absolute session timestamps.
    """
    if not hasattr(segment, 'words') or not segment.words:
        return None

    words_list = []
    for word in segment.words:
        words_list.append({
            'start': float(word.start) + segment_start_time,  # Convert to absolute
            'end': float(word.end) + segment_start_time,      # Convert to absolute
            'word': word.word,
            'probability': float(word.probability)
        })
    return words_list if words_list else None
```

**Override update_segments()**:
Overrides the base class method to extract words from segments and pass them to format_segment with absolute timestamps:
```python
# For completed segments
start = self.timestamp_offset + self.get_segment_start(s)
end = self.timestamp_offset + min(duration, self.get_segment_end(s))
words = self.extract_words_from_segment(s, start)  # Pass absolute start time
completed_segment = self.format_segment(start, end, text_, completed=True, words=words)

# For incomplete/last segment
segment_start = self.timestamp_offset + self.get_segment_start(segments[-1])
words = self.extract_words_from_segment(segments[-1], segment_start)
last_segment = self.format_segment(segment_start, segment_end, text, completed=False, words=words)
```

**Why Absolute Timestamps Matter**:
- faster-whisper returns word timestamps relative to each segment (e.g., Segment 1: words at 0.0-0.5s, 0.5-1.0s; Segment 2: words at 0.0-0.5s, 0.5-1.0s)
- Without conversion, the second segment's words would highlight at times 0.0-1.0s instead of their actual times (e.g., 3.0-4.0s)
- Adding `segment_start_time` converts segment-relative to session-absolute timestamps for correct multi-segment highlighting

### Automatic Application

All three patches are **automatically applied** during deployment by `scripts/310-configure-whisperlive-gpu.sh` at step 7/8.

The script:
1. Backs up original files (`*.backup`)
2. Applies all three patches using Python scripts
3. Verifies patches were applied successfully
4. Skips if already applied (idempotent)

### Manual Application

If you need to apply this patch manually on an existing WhisperLive installation:

```bash
cd ~/whisperlive/WhisperLive

# Backup the original
cp whisper_live/backend/faster_whisper_backend.py \
   whisper_live/backend/faster_whisper_backend.py.backup

# Apply the patch
sed -i 's/vad_parameters=self.vad_parameters if self.use_vad else None)/vad_parameters=self.vad_parameters if self.use_vad else None,\n            word_timestamps=True)/' \
   whisper_live/backend/faster_whisper_backend.py

# Restart the service
sudo systemctl restart whisperlive
```

### Verification

After applying the patch:

1. **Server-side**: Check the patched file
   ```bash
   grep "word_timestamps=True" ~/whisperlive/WhisperLive/whisper_live/backend/faster_whisper_backend.py
   ```
   Should output: `            word_timestamps=True)`

2. **Client-side**: Record audio in the browser and check console logs
   - Look for `📊 WhisperLive Segment:` logs
   - Should show `hasWords: true` and `wordCount > 0`
   - Individual words should highlight yellow during playback

### Related Changes

**Browser Client Fixes** (`site/index.html`):
- Added `word_timestamps: true` to WhisperLive config (line ~1526)
- **CRITICAL FIX**: Removed double-adding of segment start time to word timestamps (line ~1885-1896)
  - Server already sends absolute timestamps, browser was incorrectly adding segment time again
  - This caused highlighting to fail on chunk 2+ (progressively worse timing)
- Implemented word-by-word highlighting during audio playback (lines ~1762-1916)
- Added karaoke-style highlighting with `.word.active` class for yellow highlight

## Why This Patch is Needed

The upstream WhisperLive repository focuses on real-time transcription but doesn't enable word timestamps by default. This patch enables word-level granularity required for:

1. **Karaoke-style highlighting**: Words highlight as they're spoken during playback
2. **Better timing accuracy**: Word-level timestamps allow precise synchronization
3. **Enhanced UX**: Users can see exactly which word is being spoken

## Maintenance Notes

- This patch may need to be reapplied if WhisperLive is upgraded
- Monitor the upstream WhisperLive repository for word timestamp support
- If upstream adds word timestamp configuration, update this patch accordingly
- The `310-configure-whisperlive-gpu.sh` script checks if patch is already applied (idempotent)

## Version Info

- **WhisperLive**: Collabora/WhisperLive (GitHub)
- **faster-whisper**: Supports word timestamps natively
- **Patches applied**: 2025-10-27
- **Browser client version**: v5.1.0-word-highlighting
- **Total patches**: 3 (transcribe call + format_segment + word extraction)
- **Status**: Production ready - full karaoke word highlighting operational

## Testing

After applying patches and restarting WhisperLive:

1. **Server-side**: Check logs show word data being processed
   ```bash
   sudo journalctl -u whisperlive -f
   ```

2. **Client-side**: Record audio and check browser console
   - Look for `📊 WhisperLive Segment:` logs
   - Should show `hasWords: true` and `wordCount > 0`
   - Words should highlight yellow during playback

3. **Verify patch status**:
   ```bash
   cd ~/whisperlive/WhisperLive
   grep "word_timestamps=True" whisper_live/backend/faster_whisper_backend.py
   grep "extract_words_from_segment" whisper_live/backend/faster_whisper_backend.py
   grep "words=None" whisper_live/backend/base.py
   ```
