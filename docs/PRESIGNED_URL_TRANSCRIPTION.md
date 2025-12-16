# S3 Presigned URL Transcription

## Overview

This feature enables RunPod GPU workers to download audio and upload results directly from/to S3, bypassing the Cloudflare proxy timeout limitation (~100s).

## Architecture

```
                                    PRESIGNED URL FLOW
┌──────────────────────────────────────────────────────────────────────────┐
│                                                                          │
│  Edge Box                     RunPod GPU                   S3 Bucket    │
│      │                            │                           │          │
│      │  1. Generate presigned URLs                            │          │
│      │     - GET for audio.wav                                │          │
│      │     - PUT for transcription.json                       │          │
│      │                            │                           │          │
│      ├──[POST /transcribe]───────►│                           │          │
│      │  { audio_url, result_url } │                           │          │
│      │  (tiny JSON, <2KB)         │                           │          │
│      │                            │                           │          │
│      │                            ├───[GET audio.wav]────────►│          │
│      │                            │   (direct from S3)        │          │
│      │                            │                           │          │
│      │                            │   [TRANSCRIBE 15+ min]    │          │
│      │                            │                           │          │
│      │                            ├───[PUT transcription.json]►          │
│      │                            │   (direct to S3)          │          │
│      │                            │                           │          │
│      │◄──[{"status": "ok"}]──────┤                           │          │
│      │   (tiny response, <1KB)    │                           │          │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

## Repositories Involved

### 1. transcription-realtime-whisper-cognito-s3-lambda-ver4 (this repo)

**Files modified:**
- `scripts/515-runpod--batch-transcribe.sh` - Generates presigned URLs and calls RunPod API

**What it does:**
- Generates presigned GET URL for `audio.wav` (using `aws s3 presign`)
- Generates presigned PUT URL for `transcription.json` (using boto3)
- POSTs tiny JSON payload to RunPod `/transcribe` endpoint
- Receives summary response (not full transcription)

### 2. whisperX-runpod (`~/event-b/whisperX-runpod`)

**Files modified:**
- `src/handler_pod.py` - Added `result_url` parameter and S3 upload logic

**What it does:**
- Accepts `result_url` parameter in `/transcribe` endpoint
- Downloads audio from presigned GET URL
- Transcribes with WhisperX + speaker diarization
- Uploads result directly to S3 using presigned PUT URL
- Returns summary instead of full result

## API Contract

### Request: POST /transcribe

```json
{
    "audio_url": "https://bucket.s3.region.amazonaws.com/.../audio.wav?X-Amz-Signature=...",
    "result_url": "https://bucket.s3.region.amazonaws.com/.../transcription.json?X-Amz-Signature=...",
    "diarize": true
}
```

### Response (when result_url provided)

```json
{
    "status": "ok",
    "message": "Transcription uploaded to S3",
    "segments_count": 1117,
    "speakers_count": 2,
    "duration_seconds": 4447.5,
    "processing_time_seconds": 892.3,
    "total_time_seconds": 920.1
}
```

## Timeout Comparison

### Before (Proxy Upload) - BROKEN for large files

| Audio Duration | File Size | Upload Time | Transcription | Total | Proxy Limit | Result |
|---------------|-----------|-------------|---------------|-------|-------------|--------|
| 5 min | 9 MB | 5s | 30s | 35s | 100s | OK |
| 30 min | 57 MB | 30s | 180s | 210s | 100s | TIMEOUT |
| 74 min | 142 MB | 90s | 450s | 540s | 100s | TIMEOUT |

### After (Presigned URLs) - WORKS for any size

| Audio Duration | Request Size | Transcription | Response Size | Proxy Limit | Result |
|---------------|--------------|---------------|---------------|-------------|--------|
| 5 min | <2 KB | 30s | <1 KB | 100s | OK |
| 74 min | <2 KB | 450s | <1 KB | 100s | OK |
| 4 hours | <2 KB | 1800s | <1 KB | 100s | OK |

## Usage

```bash
# 1. Start RunPod GPU
./scripts/850-runpod--start.sh

# 2. Run batch transcription (uses presigned URLs automatically for audio.wav)
./scripts/515-runpod--batch-transcribe.sh

# 3. Stop RunPod when done
./scripts/855-runpod--stop.sh
```

## Configuration

```bash
# .env settings
PRESIGNED_URL_EXPIRY=3600  # URL validity in seconds (default: 1 hour)
```

## Security

Presigned URLs provide:
- **Time-limited access** - URLs expire after configured time
- **Single-file scoped** - Each URL only accesses one S3 object
- **Operation-scoped** - GET URLs can only read, PUT URLs can only write
- **No credential exposure** - RunPod never sees AWS credentials

## Fallback Mode

If no pre-merged `audio.wav` exists, the script falls back to legacy mode:
1. Downloads audio chunks locally
2. Merges with ffmpeg
3. POSTs file to `/transcribe/upload` endpoint
4. Uploads result to S3

This legacy mode still has the timeout limitation for large files.

## Pre-requisites

For presigned URL mode to work:
1. Audio must be pre-merged to `audio.wav` in S3 (use `516-merge-chunks-worker.sh`)
2. Edge Box must have IAM permissions to generate presigned URLs
3. whisperX-runpod Docker image must include the updated `handler_pod.py`
