# Processing Pipeline Orchestration Design

## Problem Statement

The current batch processing system only detects sessions missing **raw transcription**. It doesn't support:
- Re-diarization requests (session has transcription but needs new diarization)
- AI analysis jobs (summarization, action items, etc.)
- Speaker identification (LLM-based speaker naming)
- Custom reprocessing flows

**Example Gap:** User clicks "Re-Diarize" button → metadata updated → but scheduler never picks it up because raw transcription exists.

---

## Design Goals

1. **Flow-based Processing** - Define reusable processing flows (diarize, analyze, tag-speakers)
2. **Job Queue** - Queue jobs at session level with priority and retry logic
3. **Extensible** - Easy to add new flows without modifying core orchestration
4. **Visibility** - Track job status, progress, and history
5. **Efficient** - Only start GPU when needed, batch similar jobs

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           PROCESSING PIPELINE                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   ┌──────────┐     ┌──────────┐     ┌──────────┐     ┌──────────┐          │
│   │   UI     │     │  API     │     │ Scanner  │     │Dispatcher│          │
│   │ Buttons  │────▶│ Lambdas  │────▶│  (540)   │────▶│  (545)   │          │
│   └──────────┘     └──────────┘     └──────────┘     └──────────┘          │
│                          │                                 │                 │
│                          ▼                                 ▼                 │
│                    ┌──────────┐                     ┌──────────────┐        │
│                    │ S3       │                     │  Processors  │        │
│                    │ metadata │                     ├──────────────┤        │
│                    │ .json    │                     │ 515-runpod   │        │
│                    └──────────┘                     │ 561-speakers │        │
│                                                     │ 570-ai-anal  │        │
│                                                     │ 518-postproc │        │
│                                                     └──────────────┘        │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Core Concepts

### 1. Job

A unit of work for a session. Stored in `metadata.json`.

```json
{
  "jobs": {
    "queue": [
      {
        "id": "job-abc123",
        "flow": "rediarize",
        "priority": 1,
        "createdAt": "2025-12-19T01:33:25Z",
        "createdBy": "user@example.com",
        "params": {
          "minSpeakers": 2,
          "maxSpeakers": 2
        },
        "status": "pending",
        "attempts": 0,
        "maxAttempts": 3
      }
    ],
    "history": [
      {
        "id": "job-xyz789",
        "flow": "transcribe",
        "status": "completed",
        "completedAt": "2025-12-18T21:04:20Z",
        "duration": 45
      }
    ]
  }
}
```

### 2. Flow

A named sequence of processing steps. Defined in `flows.json`.

```json
{
  "flows": {
    "transcribe": {
      "name": "Full Transcription",
      "description": "Transcribe audio with diarization",
      "steps": ["merge-audio", "transcribe-gpu", "postprocess"],
      "requiresGpu": true,
      "estimatedMinutes": 5
    },
    "rediarize": {
      "name": "Re-Diarization",
      "description": "Re-run speaker diarization with hints",
      "steps": ["diarize-only", "postprocess"],
      "requiresGpu": true,
      "estimatedMinutes": 3
    },
    "ai-analysis": {
      "name": "AI Analysis",
      "description": "Generate summary, action items, key points",
      "steps": ["ai-summarize", "ai-extract-actions", "ai-key-points"],
      "requiresGpu": false,
      "estimatedMinutes": 2
    },
    "speaker-identify": {
      "name": "Speaker Identification",
      "description": "Use LLM to identify speakers by context",
      "steps": ["llm-speaker-id", "update-speaker-names"],
      "requiresGpu": false,
      "estimatedMinutes": 1
    },
    "reformat": {
      "name": "Reformat Transcript",
      "description": "Regenerate processed transcript with new rules",
      "steps": ["postprocess"],
      "requiresGpu": false,
      "estimatedMinutes": 0.5
    }
  }
}
```

### 3. Step

An atomic processing operation. Maps to a script or function.

| Step ID | Script/Function | GPU? | Description |
|---------|-----------------|------|-------------|
| `merge-audio` | `516-merge-chunks-worker.sh` | No | Merge WebM chunks to WAV |
| `transcribe-gpu` | `515-runpod--batch-transcribe.sh` | Yes | WhisperX transcription |
| `diarize-only` | `515-runpod--batch-transcribe.sh --diarize-only` | Yes | Diarization without re-transcribing |
| `postprocess` | `518-postprocess-transcripts.sh` | No | Convert to editor format |
| `ai-summarize` | `570-ai-analysis.sh --summarize` | No | Claude API summarization |
| `ai-extract-actions` | `570-ai-analysis.sh --actions` | No | Extract action items |
| `llm-speaker-id` | `561-identify-speakers-llm.py` | No | Identify speakers by context |
| `update-speaker-names` | `562-merge-speaker-turns.py` | No | Apply speaker names |

---

## Enhanced Metadata Schema

```json
{
  "sessionId": "session_2025-12-18T20_02_26_251Z",
  "userId": "512b3590-30b1-707d-ed46-bf68df7b52d5",
  "createdAt": "2025-12-18T20:02:26Z",

  "processing": {
    "status": "idle",
    "currentJob": null,

    "queue": [
      {
        "id": "job-rediarize-001",
        "flow": "rediarize",
        "priority": 1,
        "createdAt": "2025-12-19T01:33:25Z",
        "createdBy": "david.bryan.mar@gmail.com",
        "params": {
          "minSpeakers": 2,
          "maxSpeakers": 2
        },
        "status": "pending",
        "attempts": 0
      }
    ],

    "completed": [
      {
        "id": "job-transcribe-001",
        "flow": "transcribe",
        "completedAt": "2025-12-18T21:04:20Z",
        "result": "success"
      }
    ],

    "capabilities": {
      "hasRawTranscription": true,
      "hasDiarization": false,
      "hasAiAnalysis": false,
      "hasSpeakerNames": false
    }
  },

  "diarization": {
    "minSpeakers": 2,
    "maxSpeakers": 2
  }
}
```

---

## New Scripts

### 540-scan-job-queue.sh

Replaces/enhances 512. Scans for ALL pending work, not just missing transcription.

```bash
#!/bin/bash
# 540-scan-job-queue.sh
# Scan all sessions for pending jobs

# Output: /tmp/pending-jobs.json
{
  "timestamp": "2025-12-19T04:00:00Z",
  "jobs": [
    {
      "sessionPath": "users/512b.../audio/sessions/session_2025-12-18T20_02_26_251Z",
      "jobId": "job-rediarize-001",
      "flow": "rediarize",
      "priority": 1,
      "requiresGpu": true
    },
    {
      "sessionPath": "users/017b.../audio/sessions/session_2025-12-18T23_02_22_193Z",
      "jobId": "job-ai-analysis-001",
      "flow": "ai-analysis",
      "priority": 2,
      "requiresGpu": false
    }
  ],
  "summary": {
    "totalJobs": 2,
    "gpuJobs": 1,
    "cpuJobs": 1
  }
}
```

**Logic:**
1. List all sessions
2. For each session, fetch `metadata.json`
3. Check `processing.queue` for pending jobs
4. Also check for "implicit" jobs:
   - Has audio chunks but no transcription → implicit `transcribe` job
   - Has `diarization` settings but no `transcription-diarized.json` → implicit `rediarize` job
5. Output consolidated job list

### 545-dispatch-jobs.sh

Routes jobs to appropriate processors.

```bash
#!/bin/bash
# 545-dispatch-jobs.sh
# Dispatch pending jobs to processors

# 1. Read job queue from 540 output
# 2. Group by GPU requirement
# 3. If GPU jobs exist:
#    a. Start RunPod (850)
#    b. Process all GPU jobs
#    c. Stop RunPod (855)
# 4. Process CPU jobs (can run in parallel)
# 5. Update job status in metadata
```

### 546-process-flow.sh

Execute a specific flow for a session.

```bash
#!/bin/bash
# 546-process-flow.sh <session-path> <flow-name> [params-json]
# Execute a processing flow

SESSION_PATH=$1
FLOW=$2
PARAMS=$3

case $FLOW in
  "transcribe")
    ./scripts/516-merge-chunks-worker.sh "$SESSION_PATH"
    ./scripts/515-runpod--batch-transcribe.sh --session "$SESSION_PATH"
    ./scripts/518-postprocess-transcripts.sh "$SESSION_PATH"
    ;;
  "rediarize")
    # Extract speaker hints from params
    MIN=$(echo "$PARAMS" | jq -r '.minSpeakers // empty')
    MAX=$(echo "$PARAMS" | jq -r '.maxSpeakers // empty')
    ./scripts/515-runpod--batch-transcribe.sh --session "$SESSION_PATH" \
      --diarize-only --min-speakers "$MIN" --max-speakers "$MAX"
    ./scripts/518-postprocess-transcripts.sh "$SESSION_PATH"
    ;;
  "ai-analysis")
    ./scripts/570-ai-analysis.sh "$SESSION_PATH"
    ;;
  "speaker-identify")
    ./scripts/561-identify-speakers-llm.py "$SESSION_PATH"
    ./scripts/562-merge-speaker-turns.py "$SESSION_PATH"
    ;;
  "reformat")
    ./scripts/518-postprocess-transcripts.sh "$SESSION_PATH"
    ;;
esac
```

---

## API Endpoints

### Existing (Enhanced)

**POST /api/rediarize** - Already implemented, needs minor update to use new schema

### New Endpoints

**POST /api/jobs/queue**
```json
Request:
{
  "sessionId": "session_2025-12-18T20_02_26_251Z",
  "flow": "ai-analysis",
  "priority": 1,
  "params": {}
}

Response:
{
  "jobId": "job-ai-analysis-001",
  "status": "queued",
  "position": 3
}
```

**GET /api/jobs/status/{sessionId}**
```json
Response:
{
  "sessionId": "session_...",
  "processing": {
    "status": "running",
    "currentJob": {
      "id": "job-rediarize-001",
      "flow": "rediarize",
      "step": "diarize-only",
      "progress": 45
    },
    "queue": [...],
    "completed": [...]
  }
}
```

**GET /api/jobs/queue**
```json
Response:
{
  "jobs": [...],
  "summary": {
    "pending": 5,
    "running": 1,
    "gpuRequired": 2
  }
}
```

---

## UI Integration

### Session Actions Menu

```
┌─────────────────────────────┐
│ Session: Dec 18, 8:02 PM    │
├─────────────────────────────┤
│ [▶] Re-Diarize              │
│ [▶] AI Analysis             │
│ [▶] Identify Speakers       │
│ [▶] Reformat Transcript     │
├─────────────────────────────┤
│ Status: 1 job queued        │
│ ├─ rediarize (pending)      │
└─────────────────────────────┘
```

### Job Status Badge

```html
<span class="job-badge pending">1 pending</span>
<span class="job-badge running">Processing...</span>
<span class="job-badge complete">Ready</span>
```

---

## Scheduler Integration

### Updated 535-smart-batch-scheduler.sh

```bash
# Old: Only checked for missing transcription
./scripts/512-scan-missing-chunks.sh

# New: Check full job queue
./scripts/540-scan-job-queue.sh
JOBS=$(cat /tmp/pending-jobs.json)

GPU_JOBS=$(echo "$JOBS" | jq '[.jobs[] | select(.requiresGpu == true)]')
CPU_JOBS=$(echo "$JOBS" | jq '[.jobs[] | select(.requiresGpu == false)]')

# Process GPU jobs (batch together)
if [ $(echo "$GPU_JOBS" | jq 'length') -gt 0 ]; then
  ./scripts/850-runpod--start.sh
  ./scripts/545-dispatch-jobs.sh --gpu-only
  ./scripts/855-runpod--stop.sh
fi

# Process CPU jobs (can run without GPU)
if [ $(echo "$CPU_JOBS" | jq 'length') -gt 0 ]; then
  ./scripts/545-dispatch-jobs.sh --cpu-only
fi
```

---

## Implementation Phases

### Phase 1: Core Infrastructure (MVP)
1. Update `metadata.json` schema with `processing.queue`
2. Create `540-scan-job-queue.sh` - scan for queued jobs
3. Update `535-smart-batch-scheduler.sh` to use 540
4. Fix immediate issue: re-diarize jobs get picked up

### Phase 2: Flow Framework
1. Create `flows.json` definition file
2. Create `546-process-flow.sh` - generic flow executor
3. Create `545-dispatch-jobs.sh` - job dispatcher
4. Add `POST /api/jobs/queue` endpoint

### Phase 3: New Flows
1. `570-ai-analysis.sh` - Claude API integration
2. Update `561-identify-speakers-llm.py` for flow integration
3. Add UI buttons for each flow
4. Add `GET /api/jobs/status` endpoint

### Phase 4: Monitoring & Polish
1. Job progress tracking
2. Retry logic with exponential backoff
3. Admin dashboard for queue visibility
4. Webhook notifications on completion

---

## File Structure

```
scripts/
├── 540-scan-job-queue.sh        # NEW: Scan for all pending jobs
├── 545-dispatch-jobs.sh         # NEW: Route jobs to processors
├── 546-process-flow.sh          # NEW: Execute a flow
├── 512-scan-missing-chunks.sh   # KEEP: Still useful for raw detection
├── 515-runpod--batch-transcribe.sh  # ENHANCE: Add --diarize-only flag
├── 518-postprocess-transcripts.sh   # KEEP: Unchanged
├── 535-smart-batch-scheduler.sh     # UPDATE: Use 540 instead of 512
├── 570-ai-analysis.sh           # NEW: AI analysis flow
└── lib/
    └── flow-definitions.json    # NEW: Flow configurations

cognito-stack/api/
├── jobs.js                      # NEW: Job queue API
├── rediarize.js                 # UPDATE: Use new schema
└── ...
```

---

## Migration Path

1. **Backwards Compatible**: New schema fields are additive
2. **Gradual Rollout**: 540 falls back to 512 behavior if no queue
3. **No Data Loss**: Existing sessions continue to work
4. **Opt-in Flows**: New flows only trigger when explicitly requested

---

## Success Metrics

- Re-diarize jobs processed within 1 hour of request
- AI analysis available for all transcribed sessions
- Zero manual intervention for standard flows
- < 5% job failure rate
- Clear visibility into queue status

---

## Open Questions

1. **Job Persistence**: S3 metadata vs DynamoDB for job tracking?
2. **Concurrency**: How many CPU jobs can run in parallel?
3. **Notifications**: Email/webhook when job completes?
4. **Quotas**: Limit jobs per user per day?
5. **Priority**: How to handle rush jobs vs background processing?

---

## Next Steps

1. Review and approve this design
2. Implement Phase 1 (fix immediate re-diarize gap)
3. Test with real sessions
4. Iterate on Phases 2-4
