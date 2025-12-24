# CloudDrive Actions System - First Principles Design

## Core Philosophy

**Actions are pure transformations on session data.**

An action takes a session as input and produces output files. That's it.

```
┌─────────────────────────────────────────────────────────────────┐
│                     THE SIMPLEST MODEL                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   Session (S3)  ──►  Action  ──►  Output Files (S3)            │
│                                                                 │
│   That's it. Everything else is just triggering actions.       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## First Principles

### Principle 1: Actions are Stateless Functions

```
action(session_path, parameters) → output_files
```

- **Input:** Session path in S3 + optional parameters
- **Output:** Files written to S3 in the session folder
- **No side effects** beyond S3 writes
- **Idempotent:** Running twice produces same result

### Principle 2: State Lives in S3

No database. Session folder IS the state:

```
users/{userId}/audio/sessions/{sessionId}/
├── chunk-001.webm              # Input: audio
├── transcription.json          # Output: transcription action
├── transcription-ai-analysis.json  # Output: ai-analysis action
├── layers/
│   ├── layer-0-raw-transcription/  # Output: transcribe action
│   ├── layer-1-diarization/        # Output: diarize action
│   └── layer-3-topic-segments/     # Output: topics action
└── metadata.json               # Tracks what's been done
```

**Completion = output file exists.** No need for status flags.

### Principle 3: Triggers are Separate from Actions

An action doesn't care HOW it was started:

| Trigger Type | Mechanism | Example |
|--------------|-----------|---------|
| **Manual** | API call | User clicks "Generate Summary" |
| **Timer** | Cron/EventBridge Schedule | "Run diarization daily at 2am" |
| **Event** | S3 event / EventBridge | "When transcription completes, run AI analysis" |
| **Chain** | Action output triggers next | "After diarize → topics → summary" |

### Principle 4: Convention Over Configuration

Standard interface = easy extension:

```python
# actions/summarize.py
def run(session_path: str, params: dict) -> dict:
    """Every action has the same signature."""
    transcript = load_transcript(session_path)
    summary = call_claude(transcript)
    save_output(session_path, 'summary.json', summary)
    return {'output': 'summary.json'}
```

### Principle 5: Humans and AI Use the Same System

Claude Code, human developers, and the UI all trigger actions the same way:

```bash
# Human runs from command line
./run-action.sh summarize --session users/123/audio/sessions/abc

# AI runs from Claude Code
# (same command)

# UI calls API that runs same action
POST /api/actions/summarize { sessionId: "abc" }
```

---

## System Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        ACTIONS SYSTEM                               │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  TRIGGERS                      ACTION RUNNER            ACTIONS     │
│  ────────                      ─────────────            ───────     │
│                                                                     │
│  ┌────────────┐                                    ┌─────────────┐ │
│  │ UI Button  │────┐                               │  summarize  │ │
│  └────────────┘    │                               ├─────────────┤ │
│                    │      ┌──────────────────┐     │  topics     │ │
│  ┌────────────┐    │      │                  │     ├─────────────┤ │
│  │ Cron Timer │────┼─────►│  run-action.sh   │────►│  diarize    │ │
│  └────────────┘    │      │                  │     ├─────────────┤ │
│                    │      │  (or Lambda)     │     │  ai-analysis│ │
│  ┌────────────┐    │      │                  │     ├─────────────┤ │
│  │ S3 Event   │────┤      └──────────────────┘     │  reformat   │ │
│  └────────────┘    │              │                ├─────────────┤ │
│                    │              │                │  (your own) │ │
│  ┌────────────┐    │              ▼                └─────────────┘ │
│  │ Chain      │────┘      ┌──────────────────┐                     │
│  └────────────┘           │     S3 Output    │                     │
│                           └──────────────────┘                     │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Action Interface

### Standard Action Contract

Every action follows this contract:

```python
# actions/{action_name}.py

def run(session_path: str, params: dict = None) -> ActionResult:
    """
    Args:
        session_path: S3 path like "users/123/audio/sessions/abc"
        params: Optional parameters specific to this action

    Returns:
        ActionResult with output file paths

    Raises:
        ActionError on failure
    """
    pass

# Metadata (optional, for UI/discovery)
ACTION_META = {
    'name': 'summarize',
    'description': 'Generate AI summary of transcript',
    'requires': ['transcription.json'],  # Dependencies
    'produces': ['summary.json'],         # Outputs
    'params_schema': {                    # Optional params
        'style': {'type': 'string', 'default': 'bullet-points'}
    }
}
```

### Action Result

```python
@dataclass
class ActionResult:
    success: bool
    outputs: List[str]  # Files created
    duration_seconds: float
    metadata: dict = None  # Optional extra info
```

---

## Built-in Actions

| Action | Input | Output | Backend |
|--------|-------|--------|---------|
| `transcribe` | audio chunks | `layer-0-raw-transcription/` | GPU (Whisper) |
| `diarize` | audio + transcript | `layer-1-diarization/` | GPU (pyannote) |
| `ai-analysis` | transcript | `transcription-ai-analysis.json` | Claude API |
| `topics` | transcript | `layer-3-topic-segments/` | Bedrock embeddings |
| `summarize` | transcript | `summary.json` | Claude API |
| `action-items` | transcript | `action-items.json` | Claude API |
| `reformat` | transcript + diarization | `transcription-processed.json` | Local |

---

## How to Add a New Action

### Step 1: Create the Action File

```python
# actions/my-custom-action.py

import boto3
from actions.base import ActionBase, ActionResult

class MyCustomAction(ActionBase):
    name = 'my-custom-action'
    description = 'Does something cool with transcripts'
    requires = ['transcription.json']
    produces = ['my-output.json']

    def run(self, session_path: str, params: dict = None) -> ActionResult:
        # 1. Load input
        transcript = self.load_file(session_path, 'transcription.json')

        # 2. Do your processing
        result = my_custom_logic(transcript, params)

        # 3. Save output
        self.save_file(session_path, 'my-output.json', result)

        return ActionResult(
            success=True,
            outputs=['my-output.json'],
            duration_seconds=self.elapsed()
        )
```

### Step 2: Register (Optional, for Discovery)

```python
# actions/__init__.py
from .my_custom_action import MyCustomAction

ACTIONS = {
    'my-custom-action': MyCustomAction,
    # ... other actions
}
```

### Step 3: Run It

```bash
# From command line
./run-action.sh my-custom-action --session users/123/audio/sessions/abc

# From UI (if registered)
POST /api/actions/my-custom-action { sessionId: "abc" }

# From Claude Code
# Just run the command above!
```

---

## Trigger Mechanisms

### 1. Manual (UI/CLI)

```bash
# CLI
./run-action.sh summarize --session $SESSION_PATH

# API (from UI)
POST /api/actions/summarize
{ "sessionId": "abc", "params": { "style": "detailed" } }
```

### 2. Timer (Cron/Scheduled)

```bash
# crontab entry
0 2 * * * /path/to/run-action.sh batch-process --all-pending

# Or systemd timer
[Timer]
OnCalendar=*-*-* 02:00:00
Unit=batch-process.service
```

### 3. Event (S3/EventBridge)

```yaml
# EventBridge rule (pseudo-code)
rule:
  source: aws.s3
  detail-type: Object Created
  detail:
    bucket: clouddrive-app-bucket
    key:
      prefix: users/
      suffix: transcription.json
  target:
    lambda: run-action
    input:
      action: ai-analysis
      session_path: $.detail.key  # Extract from event
```

### 4. Chain (Action Pipelines)

```yaml
# pipelines/full-analysis.yaml
name: full-analysis
description: Complete transcript analysis pipeline
steps:
  - action: diarize
  - action: ai-analysis
    depends_on: diarize
  - action: topics
    depends_on: diarize
  - action: summarize
    depends_on: ai-analysis
```

```bash
./run-pipeline.sh full-analysis --session $SESSION_PATH
```

---

## File Structure

```
actions/
├── __init__.py           # Action registry
├── base.py               # ActionBase class
├── transcribe.py         # GPU transcription
├── diarize.py            # GPU speaker diarization
├── ai_analysis.py        # Claude AI analysis
├── topics.py             # Bedrock topic segmentation
├── summarize.py          # Claude summary
├── action_items.py       # Claude action items
├── reformat.py           # Transcript reformatting
└── YOUR_ACTION.py        # Add your own!

pipelines/
├── full-analysis.yaml    # Chained action definitions
└── batch-daily.yaml      # Daily batch pipeline

scripts/
├── run-action.sh         # Universal action runner
├── run-pipeline.sh       # Pipeline runner
└── list-actions.sh       # Show available actions

cognito-stack/api/
├── actions.js            # API endpoint for UI triggers
└── ...
```

---

## Example: Adding "Meeting Notes" Action

```python
# actions/meeting_notes.py
"""Generate structured meeting notes from a transcript."""

from actions.base import ActionBase, ActionResult
import anthropic

class MeetingNotesAction(ActionBase):
    name = 'meeting-notes'
    description = 'Generate structured meeting notes with attendees, decisions, and next steps'
    requires = ['transcription-diarized.json']
    produces = ['meeting-notes.json']

    def run(self, session_path: str, params: dict = None) -> ActionResult:
        # Load diarized transcript
        transcript = self.load_file(session_path, 'transcription-diarized.json')

        # Call Claude
        client = anthropic.Anthropic()
        response = client.messages.create(
            model='claude-3-5-haiku-20241022',
            max_tokens=4000,
            messages=[{
                'role': 'user',
                'content': f"""Analyze this meeting transcript and create structured notes.

TRANSCRIPT:
{self.format_transcript(transcript)}

Create a JSON document with:
1. attendees: List of speakers identified
2. agenda: Topics discussed (with timestamps)
3. decisions: Key decisions made
4. action_items: Tasks assigned (with owner if identifiable)
5. next_steps: Follow-up items
6. summary: 2-3 sentence overview

Return ONLY valid JSON."""
            }]
        )

        notes = json.loads(response.content[0].text)

        # Save output
        self.save_file(session_path, 'meeting-notes.json', notes)

        return ActionResult(
            success=True,
            outputs=['meeting-notes.json'],
            duration_seconds=self.elapsed()
        )
```

Now it works everywhere:

```bash
# CLI
./run-action.sh meeting-notes --session users/123/audio/sessions/abc

# UI button (after adding to UI)
POST /api/actions/meeting-notes { sessionId: "abc" }

# Chain after diarization
./run-pipeline.sh post-diarize --session $PATH  # includes meeting-notes
```

---

## What Already Exists (Migrate to Actions)

```
┌─────────────────────────────────────────────────────────────────────┐
│                    SIMPLIFIED JOB ARCHITECTURE                       │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   ┌────────────┐     ┌─────────────────┐     ┌──────────────────┐   │
│   │  Browser   │────>│  Job API        │────>│  S3 metadata.json │   │
│   │  (UI)      │     │  (Lambda)       │     │  (per-session)    │   │
│   └────────────┘     └─────────────────┘     └──────────────────┘   │
│         │                    │                                       │
│         │                    │ Direct invoke                         │
│         │                    ▼                                       │
│         │    ┌───────────────────────────────────┐                  │
│         │    │         PROCESSOR LAMBDAS         │                  │
│         │    ├───────────────────────────────────┤                  │
│         │    │  summary.js      │ Claude API     │                  │
│         │    │  action-items.js │ Claude API     │                  │
│         │    │  topics.js       │ Claude API     │                  │
│         │    │  rediarize.js    │ Queue→RunPod   │                  │
│         │    └───────────────────────────────────┘                  │
│         │                    │                                       │
│         │                    ▼                                       │
│         │         ┌──────────────────┐                              │
│         │         │  Update metadata │                              │
│         │         │  + Store results │                              │
│         │         └──────────────────┘                              │
│         │                    │                                       │
│   ┌─────▼────┐               │                                       │
│   │ Poll API │◀──────────────┘                                       │
│   │(5-10 sec)│                                                       │
│   └──────────┘                                                       │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Data Model

### Session metadata.json (Extended)

```json
{
  "sessionId": "20251224-session-abc123",
  "userId": "cognito-sub-xxx",
  "createdAt": "2025-12-24T10:00:00Z",
  "duration": 3600,
  "chunkCount": 30,
  "status": "completed",

  "jobs": {
    "summary": {
      "status": "completed",
      "createdAt": "2025-12-24T11:00:00Z",
      "completedAt": "2025-12-24T11:00:15Z",
      "resultKey": "layers/layer-2-ai-analysis/summary.json"
    },
    "action-items": {
      "status": "processing",
      "createdAt": "2025-12-24T11:01:00Z",
      "startedAt": "2025-12-24T11:01:02Z"
    },
    "topics": {
      "status": "pending",
      "createdAt": "2025-12-24T11:02:00Z"
    },
    "diarization": {
      "status": "failed",
      "createdAt": "2025-12-24T10:30:00Z",
      "error": "RunPod timeout after 30 minutes",
      "retryCount": 1
    }
  }
}
```

### Job Status Values
- `pending` - Queued, waiting to process
- `processing` - Currently running
- `completed` - Successfully finished
- `failed` - Error occurred (can retry)

---

## Implementation Plan (Simplified - Leveraging Existing Code)

### Phase 1: Jobs API Lambda (`cognito-stack/api/jobs.js`)

**Single file that handles all job operations. Reuses existing Python scripts.**

**Endpoints:**

| Method | Path | Description |
|--------|------|-------------|
| POST | /api/jobs | Create and start a job |
| GET | /api/jobs?sessionId=xxx | List jobs for session |

**Job Types (mapped to existing scripts):**

| Type | Existing Script | Lambda Timeout |
|------|-----------------|----------------|
| `ai-analysis` | `scripts/lib/ai-analysis.py` | 60s |
| `topics` | `scripts/524-segment-transcripts-by-topic.py` | 120s |
| `diarization` | Existing `/api/rediarize` + batch | N/A (batch) |

**createJob Logic:**
```javascript
// POST /api/jobs
// Body: { sessionId, type: "ai-analysis"|"topics"|"diarization", parameters: {} }

async function createJob(event) {
  const { sessionId, type, parameters } = JSON.parse(event.body);
  const userId = event.requestContext.authorizer.claims.sub;
  const sessionPath = `users/${userId}/audio/sessions/${sessionId}`;

  // 1. Load metadata.json
  const metadata = await loadMetadata(sessionPath);

  // 2. Check if job already running
  if (metadata.jobs?.[type]?.status === 'processing') {
    return { statusCode: 409, body: 'Job already in progress' };
  }

  // 3. Update job status to processing
  metadata.jobs = metadata.jobs || {};
  metadata.jobs[type] = {
    status: 'processing',
    createdAt: new Date().toISOString(),
    startedAt: new Date().toISOString(),
    parameters
  };
  await saveMetadata(sessionPath, metadata);

  // 4. Route to appropriate handler
  if (type === 'diarization') {
    // Delegate to existing rediarize API logic
    return await queueDiarization(sessionPath, parameters);
  } else {
    // Invoke processor Lambda async
    await lambda.invoke({
      FunctionName: `${SERVICE_NAME}-${STAGE}-processJob`,
      InvocationType: 'Event',
      Payload: JSON.stringify({ userId, sessionId, sessionPath, type, parameters })
    });
  }

  return { statusCode: 201, body: JSON.stringify({ status: 'processing', type }) };
}

// GET /api/jobs?sessionId=xxx
async function getJobs(event) {
  const sessionId = event.queryStringParameters?.sessionId;
  const userId = event.requestContext.authorizer.claims.sub;
  const sessionPath = `users/${userId}/audio/sessions/${sessionId}`;

  const metadata = await loadMetadata(sessionPath);

  // Also check for completed outputs (in case job finished but metadata not updated)
  const jobs = metadata.jobs || {};

  // Check if AI analysis exists
  if (!jobs['ai-analysis']?.status) {
    const exists = await checkFileExists(sessionPath, 'transcription-ai-analysis.json');
    if (exists) jobs['ai-analysis'] = { status: 'completed', resultKey: 'transcription-ai-analysis.json' };
  }

  // Check if topics exist
  if (!jobs['topics']?.status) {
    const exists = await checkFileExists(sessionPath, 'layers/layer-3-topic-segments/data.json');
    if (exists) jobs['topics'] = { status: 'completed', resultKey: 'layers/layer-3-topic-segments/data.json' };
  }

  return { statusCode: 200, body: JSON.stringify({ jobs }) };
}
```

### Phase 2: Job Processor Lambda (`cognito-stack/api/job-processor.js`)

**Async Lambda that runs existing Python scripts via child_process or SDK calls.**

```javascript
const { spawn } = require('child_process');

async function processJob(event) {
  const { userId, sessionId, sessionPath, type, parameters } = event;

  try {
    let result;

    switch (type) {
      case 'ai-analysis':
        // Call Claude API directly (port existing ai-analysis.py logic)
        result = await runAiAnalysis(sessionPath);
        break;

      case 'topics':
        // Call Bedrock API for embeddings (port existing 524 logic)
        result = await runTopicSegmentation(sessionPath, parameters);
        break;
    }

    // Update job status to completed
    await updateJobStatus(sessionPath, type, 'completed', {
      completedAt: new Date().toISOString(),
      resultKey: result.outputKey
    });

  } catch (error) {
    // Update job status to failed
    await updateJobStatus(sessionPath, type, 'failed', {
      error: error.message,
      failedAt: new Date().toISOString()
    });
  }
}

// Port of scripts/lib/ai-analysis.py
async function runAiAnalysis(sessionPath) {
  // 1. Load transcript
  const transcript = await loadTranscript(sessionPath);

  // 2. Call Claude API (same prompt as ai-analysis.py)
  const anthropic = new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY });
  const response = await anthropic.messages.create({
    model: 'claude-3-5-haiku-20241022',
    max_tokens: 8000,
    messages: [{ role: 'user', content: buildAnalysisPrompt(transcript) }]
  });

  // 3. Parse and save
  const analysis = JSON.parse(response.content[0].text);
  await saveToS3(sessionPath, 'transcription-ai-analysis.json', analysis);

  return { outputKey: 'transcription-ai-analysis.json' };
}

// Port of scripts/524-segment-transcripts-by-topic.py
async function runTopicSegmentation(sessionPath, params) {
  // 1. Load transcript
  const transcript = await loadTranscript(sessionPath);

  // 2. Extract sentences
  const sentences = extractSentences(transcript);

  // 3. Generate embeddings via Bedrock
  const embeddings = await generateEmbeddings(sentences);

  // 4. Detect topic boundaries
  const { boundaries, similarities } = detectTopicBoundaries(
    embeddings,
    params.threshold || 0.20
  );

  // 5. Build output and save
  const output = formatTopicSegments(transcript, sentences, boundaries, similarities);
  await saveToS3(sessionPath, 'layers/layer-3-topic-segments/data.json', output);

  return { outputKey: 'layers/layer-3-topic-segments/data.json' };
}
```

### Phase 3: UI Integration

**Add to `ui-source/transcript-editor-v2.html.template`:**

```html
<!-- AI Analysis Panel (add to Actions section) -->
<div class="ai-jobs-panel">
  <h4>AI Processing</h4>

  <button id="btn-ai-analysis" class="job-btn" onclick="triggerJob('ai-analysis')">
    Generate AI Analysis
    <span class="job-status"></span>
  </button>

  <button id="btn-topics" class="job-btn" onclick="triggerJob('topics')">
    Detect Topics
    <span class="job-status"></span>
  </button>

  <button id="btn-rediarize" class="job-btn" onclick="showRediarizeModal()">
    Re-diarize Speakers
    <span class="job-status"></span>
  </button>
</div>
```

**JavaScript (add to existing script):**

```javascript
// Job management
let jobPollInterval = null;

async function triggerJob(type, parameters = {}) {
  const btn = document.getElementById(`btn-${type}`);
  const status = btn.querySelector('.job-status');

  status.textContent = 'Starting...';
  btn.disabled = true;

  try {
    const response = await fetch(`${API_ENDPOINT}/jobs`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${await getIdToken()}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({ sessionId: currentSessionId, type, parameters })
    });

    if (response.ok) {
      status.textContent = 'Processing...';
      startJobPolling();
    } else {
      const error = await response.json();
      status.textContent = 'Failed';
      showError(error.message || 'Job failed to start');
      btn.disabled = false;
    }
  } catch (error) {
    status.textContent = 'Error';
    showError(error.message);
    btn.disabled = false;
  }
}

function startJobPolling() {
  if (jobPollInterval) return;

  jobPollInterval = setInterval(async () => {
    const jobs = await fetchJobStatus();
    updateJobButtons(jobs);

    // Stop polling if no active jobs
    const hasActiveJobs = Object.values(jobs).some(
      j => j.status === 'processing' || j.status === 'pending'
    );
    if (!hasActiveJobs) {
      clearInterval(jobPollInterval);
      jobPollInterval = null;
    }
  }, 5000);
}

async function fetchJobStatus() {
  const response = await fetch(
    `${API_ENDPOINT}/jobs?sessionId=${currentSessionId}`,
    { headers: { 'Authorization': `Bearer ${await getIdToken()}` } }
  );
  return (await response.json()).jobs;
}

function updateJobButtons(jobs) {
  for (const [type, job] of Object.entries(jobs)) {
    const btn = document.getElementById(`btn-${type}`);
    if (!btn) continue;

    const status = btn.querySelector('.job-status');

    switch (job.status) {
      case 'processing':
        status.textContent = 'Processing...';
        btn.disabled = true;
        break;
      case 'completed':
        status.textContent = 'Done ✓';
        btn.disabled = false;
        loadJobResult(type, job.resultKey);
        break;
      case 'failed':
        status.textContent = 'Failed ✗';
        btn.disabled = false;
        break;
      default:
        status.textContent = '';
        btn.disabled = false;
    }
  }
}
```

---

## Files to Create/Modify

### New Files
| File | Purpose |
|------|---------|
| `cognito-stack/api/jobs.js` | Job create/list API |
| `cognito-stack/api/job-processor.js` | Async job processor (ports Python logic) |

### Files to Modify
| File | Changes |
|------|---------|
| `cognito-stack/serverless.yml` | Add `createJob`, `listJobs`, `processJob` functions |
| `cognito-stack/api/rediarize.js` | Add `jobs.diarization` to metadata (minor) |
| `ui-source/transcript-editor-v2.html.template` | Add job buttons and polling JS |

---

## Cost Estimates (Using Existing Scripts)

| Job Type | Backend | Cost per Job |
|----------|---------|--------------|
| AI Analysis | Claude Haiku | ~$0.01-0.02 |
| Topic Segmentation | Bedrock Titan Embeddings | ~$0.001-0.002 |
| Re-diarization | RunPod GPU (batch) | ~$0.05-0.15 |

**Much cheaper than original estimate because existing scripts use Haiku, not Sonnet.**

---

## Implementation Plan

### Phase 1: Create Actions Framework

**Create `actions/` directory with base infrastructure:**

```
actions/
├── __init__.py           # Action registry
├── base.py               # ActionBase class with S3 helpers
├── run_action.py         # CLI entry point
└── config.py             # S3 bucket, region config
```

**`actions/base.py` - ~50 lines:**
```python
class ActionBase:
    def load_file(self, session_path, filename): ...
    def save_file(self, session_path, filename, data): ...
    def file_exists(self, session_path, filename): ...
    def elapsed(self): ...
```

### Phase 2: Migrate Existing Scripts to Actions

| Current Script | New Action |
|----------------|------------|
| `scripts/lib/ai-analysis.py` | `actions/ai_analysis.py` |
| `scripts/524-segment-transcripts-by-topic.py` | `actions/topics.py` |

**Minimal changes - just wrap existing logic in ActionBase interface.**

### Phase 3: Create run-action.sh Runner

```bash
#!/bin/bash
# scripts/run-action.sh
ACTION=$1
shift
python3 -m actions.run_action $ACTION "$@"
```

### Phase 4: Add API Endpoint

**`cognito-stack/api/actions.js` - ~80 lines:**
- `POST /api/actions/{actionName}` - Run action
- `GET /api/actions` - List available actions
- Async invocation via Lambda

### Phase 5: UI Integration

Add action buttons to `transcript-editor-v2.html.template`

---

## Files to Create

| File | Lines | Purpose |
|------|-------|---------|
| `actions/__init__.py` | 20 | Action registry |
| `actions/base.py` | 60 | Base class with S3 helpers |
| `actions/config.py` | 10 | Configuration |
| `actions/run_action.py` | 40 | CLI runner |
| `actions/ai_analysis.py` | 50 | Wrap existing ai-analysis.py |
| `actions/topics.py` | 50 | Wrap existing 524 script |
| `scripts/run-action.sh` | 15 | Shell wrapper |
| `cognito-stack/api/actions.js` | 80 | API endpoint |

**Total: ~325 lines of new code**

## Files to Modify

| File | Changes |
|------|---------|
| `cognito-stack/serverless.yml` | Add `runAction`, `listActions` functions |
| `ui-source/transcript-editor-v2.html.template` | Add action buttons |

---

---

## Critical Questions Answered

### A) Is This Secure?

**Yes, with these built-in protections:**

1. **User Isolation (Already Exists)**
   - All S3 paths are scoped: `users/{userId}/audio/sessions/...`
   - Cognito auth extracts `userId` from JWT token
   - Actions can ONLY access the authenticated user's sessions

2. **No Code Injection**
   - Actions are pre-defined Python classes (not user-uploaded code)
   - Parameters are validated before use
   - No `eval()` or dynamic code execution

3. **API Authorization**
   - All `/api/actions/*` endpoints require Cognito auth
   - Same security model as existing APIs

4. **Credentials Management**
   - API keys (Anthropic, Bedrock) stored in environment variables
   - Never exposed to frontend
   - Lambda execution role has least-privilege S3 access

**Security Boundaries:**
```
Browser  ──(HTTPS)──►  API Gateway  ──(Cognito JWT)──►  Lambda
                                                           │
                                                           ▼
                                                     Action runs with
                                                     user-scoped S3 path
```

---

### B) Chained Operations (Dependencies)

**The Problem:**
```
Step 1: Segment text      → segments.json
Step 2: Format segments   → formatted.json (needs segments.json)
Step 3: Enhance formatting → enhanced.json (needs formatted.json)
```

**Solution 1: Explicit Dependencies (Simple)**

Each action declares what files it needs:

```python
class FormatAction(ActionBase):
    name = 'format'
    requires = ['segments.json']  # Won't run without this
    produces = ['formatted.json']

    def run(self, session_path, params):
        # ActionBase checks: does segments.json exist?
        # If not, raises DependencyError
        segments = self.load_file(session_path, 'segments.json')
        ...
```

**Solution 2: Pipelines (For Complex Chains)**

```yaml
# pipelines/full-format.yaml
name: full-format
steps:
  - action: segment
  - action: format
    requires: segment  # Explicit ordering
  - action: enhance
    requires: format
```

```bash
./run-pipeline.sh full-format --session $PATH
# Runs all 3 in order, stops if any fails
```

**Solution 3: Auto-Resolution (Most Elegant)**

The runner automatically runs prerequisites:

```python
# run-action.py with auto-resolve
def run_with_dependencies(action_name, session_path):
    action = ACTIONS[action_name]

    for required_file in action.requires:
        if not file_exists(session_path, required_file):
            # Find action that produces this file
            producer = find_action_that_produces(required_file)
            run_with_dependencies(producer, session_path)  # Recursive!

    action.run(session_path)
```

Example:
```bash
./run-action.sh enhance --session $PATH
# System realizes: enhance needs formatted.json
# formatted.json needs segments.json
# Runs: segment → format → enhance
```

**Recommended: Start with Solution 1 (explicit deps), add Solution 2 (pipelines) later.**

---

### C) Is This The Simplest Approach?

**Comparison of Alternatives:**

| Approach | Complexity | Flexibility | Learning Curve |
|----------|------------|-------------|----------------|
| **Current scripts** | Low | Low (hardcoded) | None |
| **Actions system** | Medium | High | Small |
| **AWS Step Functions** | High | Very High | Steep |
| **Airflow/Dagster** | Very High | Very High | Very Steep |
| **Custom workflow engine** | High | Custom | Medium |

**Why Actions System is the sweet spot:**

1. **Simpler than workflow engines**
   - No DAG configuration
   - No scheduler to maintain
   - No separate orchestration layer

2. **More flexible than scripts**
   - Standard interface
   - Multiple triggers
   - Easy to add new actions

3. **No new infrastructure**
   - Uses existing S3, Lambda, Cognito
   - Python + bash (already in use)
   - No database needed

4. **Progressive complexity**
   - Start simple: just actions
   - Add pipelines when needed
   - Add auto-resolution later

**Could it be simpler?**

The absolute simplest would be:
```bash
# Just run scripts directly
./scripts/525-generate-ai-analysis.sh --session-path $PATH
./scripts/524-segment-transcripts-by-topic.py --session $PATH
```

**Why actions are better:**

| Feature | Raw Scripts | Actions System |
|---------|-------------|----------------|
| Standard interface | ❌ Each different | ✓ Same for all |
| Dependency checking | ❌ Manual | ✓ Automatic |
| UI integration | ❌ Custom each | ✓ Generic API |
| Discovery | ❌ Read docs | ✓ `list-actions.sh` |
| New developer onboarding | Hard | Easy |

**Verdict: Actions system adds ~300 lines of infrastructure code to save hours of future development time and provide a foundation for extensibility.**

---

## Detailed Implementation Specifications

### ActionBase Class (Full Implementation)

```python
# actions/base.py
"""
Base class for all CloudDrive actions.
Provides S3 helpers, logging, timing, and dependency validation.
"""

import json
import time
import boto3
from dataclasses import dataclass
from typing import List, Dict, Any, Optional
from abc import ABC, abstractmethod

@dataclass
class ActionResult:
    """Result returned by every action."""
    success: bool
    outputs: List[str]           # Files created (relative to session)
    duration_seconds: float
    metadata: Optional[Dict] = None  # Action-specific data
    error: Optional[str] = None      # Error message if failed

class ActionError(Exception):
    """Raised when an action fails."""
    pass

class DependencyError(ActionError):
    """Raised when required input files are missing."""
    pass

class ActionBase(ABC):
    """
    Base class for all actions. Subclasses must implement:
    - name: str - Unique action identifier
    - run(session_path, params) -> ActionResult
    """

    # Class attributes (override in subclass)
    name: str = ''
    description: str = ''
    requires: List[str] = []      # Files that must exist before running
    produces: List[str] = []      # Files this action creates

    def __init__(self):
        self._start_time = None
        self._s3 = boto3.client('s3', region_name='us-east-2')
        self._bucket = os.getenv('COGNITO_S3_BUCKET', 'clouddrive-app-bucket')

    # ─────────────────────────────────────────────────────────────────
    # S3 Helpers
    # ─────────────────────────────────────────────────────────────────

    def load_file(self, session_path: str, filename: str) -> Dict:
        """Load JSON file from S3 session folder."""
        key = f"{session_path}/{filename}"
        try:
            response = self._s3.get_object(Bucket=self._bucket, Key=key)
            return json.loads(response['Body'].read().decode('utf-8'))
        except self._s3.exceptions.NoSuchKey:
            raise FileNotFoundError(f"File not found: s3://{self._bucket}/{key}")

    def save_file(self, session_path: str, filename: str, data: Dict) -> str:
        """Save JSON data to S3 session folder."""
        key = f"{session_path}/{filename}"
        self._s3.put_object(
            Bucket=self._bucket,
            Key=key,
            Body=json.dumps(data, indent=2).encode('utf-8'),
            ContentType='application/json',
            Metadata={
                'generated-by': f'action-{self.name}',
                'generated-at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
            }
        )
        return f"s3://{self._bucket}/{key}"

    def file_exists(self, session_path: str, filename: str) -> bool:
        """Check if file exists in S3."""
        key = f"{session_path}/{filename}"
        try:
            self._s3.head_object(Bucket=self._bucket, Key=key)
            return True
        except:
            return False

    def list_files(self, session_path: str, prefix: str = '') -> List[str]:
        """List files in session folder with optional prefix."""
        full_prefix = f"{session_path}/{prefix}" if prefix else session_path
        response = self._s3.list_objects_v2(
            Bucket=self._bucket,
            Prefix=full_prefix
        )
        return [obj['Key'].replace(f"{session_path}/", '')
                for obj in response.get('Contents', [])]

    # ─────────────────────────────────────────────────────────────────
    # Timing
    # ─────────────────────────────────────────────────────────────────

    def start_timer(self):
        """Start the action timer."""
        self._start_time = time.time()

    def elapsed(self) -> float:
        """Get elapsed time since start_timer()."""
        if self._start_time is None:
            return 0.0
        return round(time.time() - self._start_time, 2)

    # ─────────────────────────────────────────────────────────────────
    # Validation
    # ─────────────────────────────────────────────────────────────────

    def validate_dependencies(self, session_path: str):
        """Check that all required files exist. Raises DependencyError if not."""
        missing = []
        for required_file in self.requires:
            if not self.file_exists(session_path, required_file):
                missing.append(required_file)

        if missing:
            raise DependencyError(
                f"Action '{self.name}' requires files that don't exist: {missing}. "
                f"Run the actions that produce these files first."
            )

    # ─────────────────────────────────────────────────────────────────
    # Main Entry Point
    # ─────────────────────────────────────────────────────────────────

    def execute(self, session_path: str, params: Dict = None) -> ActionResult:
        """
        Execute the action with validation and error handling.
        This is the public method - calls the subclass run() method.
        """
        self.start_timer()

        try:
            # Validate dependencies
            self.validate_dependencies(session_path)

            # Run the actual action logic
            result = self.run(session_path, params or {})

            # Ensure proper return type
            if not isinstance(result, ActionResult):
                result = ActionResult(
                    success=True,
                    outputs=self.produces,
                    duration_seconds=self.elapsed()
                )

            return result

        except DependencyError as e:
            return ActionResult(
                success=False,
                outputs=[],
                duration_seconds=self.elapsed(),
                error=str(e)
            )
        except Exception as e:
            return ActionResult(
                success=False,
                outputs=[],
                duration_seconds=self.elapsed(),
                error=f"{type(e).__name__}: {str(e)}"
            )

    @abstractmethod
    def run(self, session_path: str, params: Dict) -> ActionResult:
        """
        Execute the action logic. Must be implemented by subclass.

        Args:
            session_path: S3 path like "users/123/audio/sessions/abc"
            params: Action-specific parameters

        Returns:
            ActionResult with success status and output files
        """
        pass
```

---

### Full Action Examples

#### AI Analysis Action (Wraps Existing Script)

```python
# actions/ai_analysis.py
"""
Generate AI analysis of transcript using Claude API.
Extracts: action items, key terms, themes, topic changes, highlights.
"""

import anthropic
from actions.base import ActionBase, ActionResult

class AiAnalysisAction(ActionBase):
    name = 'ai-analysis'
    description = 'Generate AI analysis with action items, themes, and highlights'
    requires = ['transcription-processed.json']
    produces = ['transcription-ai-analysis.json', 'transcription-enhanced.json']

    def run(self, session_path: str, params: dict) -> ActionResult:
        # 1. Load transcript
        transcript = self.load_file(session_path, 'transcription-processed.json')
        paragraphs = transcript.get('paragraphs', [])

        # 2. Format for Claude
        text = self._format_transcript(paragraphs)
        duration = transcript.get('stats', {}).get('totalDuration', 0)

        # 3. Call Claude API
        client = anthropic.Anthropic()
        response = client.messages.create(
            model='claude-3-5-haiku-20241022',
            max_tokens=8000,
            messages=[{
                'role': 'user',
                'content': self._build_prompt(text, duration)
            }]
        )

        # 4. Parse response
        import json
        analysis = json.loads(response.content[0].text)

        # 5. Add metadata
        analysis['_meta'] = {
            'version': '1.0',
            'generatedAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
            'model': 'claude-3-5-haiku-20241022',
            'action': self.name
        }

        # 6. Save standalone analysis
        self.save_file(session_path, 'transcription-ai-analysis.json', analysis)

        # 7. Save enhanced transcript (original + analysis)
        enhanced = {**transcript, 'aiAnalysis': analysis}
        self.save_file(session_path, 'transcription-enhanced.json', enhanced)

        return ActionResult(
            success=True,
            outputs=self.produces,
            duration_seconds=self.elapsed(),
            metadata={
                'actionItems': len(analysis.get('actionItems', [])),
                'keyTerms': len(analysis.get('keyTerms', [])),
                'highlights': len(analysis.get('highlights', []))
            }
        )

    def _format_transcript(self, paragraphs):
        lines = []
        for para in paragraphs:
            timestamp = self._format_time(para.get('start', 0))
            text = para.get('text', '')
            lines.append(f"[{timestamp}] {text}")
        return '\n\n'.join(lines)

    def _format_time(self, seconds):
        mins = int(seconds // 60)
        secs = int(seconds % 60)
        return f"{mins}:{secs:02d}"

    def _build_prompt(self, text, duration):
        return f"""Analyze this transcript and extract:
1. actionItems (5-10): tasks, recommendations, calls to action
2. keyTerms (8-15): technical terms, domain vocabulary
3. keyThemes (4-8): main topics discussed
4. topicChanges (6-12): where speaker shifts subjects
5. highlights (8-15): key insights, decisions, conclusions

Duration: {self._format_time(duration)}

TRANSCRIPT:
{text}

Return ONLY valid JSON."""
```

#### Topic Segmentation Action

```python
# actions/topics.py
"""
Segment transcript by topic using semantic embeddings.
Uses Amazon Bedrock Titan embeddings for similarity detection.
"""

import boto3
import math
from actions.base import ActionBase, ActionResult

class TopicsAction(ActionBase):
    name = 'topics'
    description = 'Detect topic boundaries using semantic embeddings'
    requires = ['transcription-processed.json']
    produces = ['layers/layer-3-topic-segments/data.json']

    def __init__(self):
        super().__init__()
        self._bedrock = boto3.client('bedrock-runtime', region_name='us-east-2')

    def run(self, session_path: str, params: dict) -> ActionResult:
        threshold = params.get('threshold', 0.20)
        window_size = params.get('window_size', 3)

        # 1. Load transcript
        transcript = self.load_file(session_path, 'transcription-processed.json')

        # 2. Extract sentences
        sentences = self._extract_sentences(transcript)
        if len(sentences) < 2:
            return ActionResult(
                success=True,
                outputs=[],
                duration_seconds=self.elapsed(),
                metadata={'message': 'Not enough sentences for topic detection'}
            )

        # 3. Generate embeddings
        embeddings = self._get_embeddings([s['text'] for s in sentences])

        # 4. Detect boundaries
        boundaries, similarities = self._detect_boundaries(
            embeddings, threshold, window_size
        )

        # 5. Build output
        output = self._build_output(
            transcript, sentences, boundaries, similarities, threshold
        )

        # 6. Save
        self.save_file(
            session_path,
            'layers/layer-3-topic-segments/data.json',
            output
        )

        return ActionResult(
            success=True,
            outputs=self.produces,
            duration_seconds=self.elapsed(),
            metadata={
                'sentenceCount': len(sentences),
                'topicCount': len(boundaries) + 1,
                'threshold': threshold
            }
        )

    def _extract_sentences(self, transcript):
        """Group words into sentences by punctuation and pauses."""
        # (Implementation from 524-segment-transcripts-by-topic.py)
        ...

    def _get_embeddings(self, texts):
        """Generate embeddings via Bedrock Titan."""
        embeddings = []
        for text in texts:
            response = self._bedrock.invoke_model(
                modelId='amazon.titan-embed-text-v2:0',
                body=json.dumps({
                    'inputText': text[:32000],
                    'dimensions': 1024,
                    'normalize': True
                }),
                contentType='application/json'
            )
            result = json.loads(response['body'].read())
            embeddings.append(result['embedding'])
        return embeddings

    def _detect_boundaries(self, embeddings, threshold, window_size):
        """Windowed cosine similarity to detect topic changes."""
        boundaries = []
        similarities = []

        for i in range(1, len(embeddings)):
            # Average embeddings in windows before/after point
            before = self._avg_embedding(embeddings[max(0, i-window_size):i])
            after = self._avg_embedding(embeddings[i:min(len(embeddings), i+window_size)])

            sim = self._cosine_similarity(before, after)
            similarities.append(sim)

            if sim < threshold:
                boundaries.append(i)

        return boundaries, similarities

    def _cosine_similarity(self, a, b):
        dot = sum(x*y for x, y in zip(a, b))
        norm_a = math.sqrt(sum(x*x for x in a))
        norm_b = math.sqrt(sum(x*x for x in b))
        return dot / (norm_a * norm_b) if norm_a and norm_b else 0

    def _avg_embedding(self, embeddings):
        if not embeddings:
            return []
        dims = len(embeddings[0])
        return [sum(e[i] for e in embeddings) / len(embeddings) for i in range(dims)]
```

---

### Action Registry

```python
# actions/__init__.py
"""
Action registry - maps action names to classes.
Enables discovery and dynamic invocation.
"""

from .ai_analysis import AiAnalysisAction
from .topics import TopicsAction
# from .summarize import SummarizeAction  # Add when ready
# from .action_items import ActionItemsAction

# Registry of all available actions
ACTIONS = {
    'ai-analysis': AiAnalysisAction,
    'topics': TopicsAction,
}

def get_action(name: str):
    """Get action class by name."""
    if name not in ACTIONS:
        raise ValueError(f"Unknown action: {name}. Available: {list(ACTIONS.keys())}")
    return ACTIONS[name]

def list_actions():
    """List all available actions with metadata."""
    return [
        {
            'name': action.name,
            'description': action.description,
            'requires': action.requires,
            'produces': action.produces
        }
        for action in ACTIONS.values()
    ]
```

---

### CLI Runner

```python
# actions/run_action.py
"""
CLI entry point for running actions.
Usage: python -m actions.run_action <action-name> --session <path> [--param key=value]
"""

import argparse
import json
import sys
from actions import get_action, list_actions

def main():
    parser = argparse.ArgumentParser(description='Run a CloudDrive action')
    parser.add_argument('action', nargs='?', help='Action name to run')
    parser.add_argument('--session', required=False, help='Session path in S3')
    parser.add_argument('--list', action='store_true', help='List available actions')
    parser.add_argument('--param', action='append', help='Parameters as key=value')

    args = parser.parse_args()

    # List actions
    if args.list or not args.action:
        print("Available actions:")
        for action in list_actions():
            print(f"\n  {action['name']}")
            print(f"    {action['description']}")
            print(f"    Requires: {action['requires']}")
            print(f"    Produces: {action['produces']}")
        return 0

    # Get action
    try:
        ActionClass = get_action(args.action)
    except ValueError as e:
        print(f"Error: {e}")
        return 1

    # Parse params
    params = {}
    if args.param:
        for p in args.param:
            key, value = p.split('=', 1)
            # Try to parse as JSON (for numbers, bools)
            try:
                params[key] = json.loads(value)
            except:
                params[key] = value

    # Run action
    action = ActionClass()
    print(f"Running action: {action.name}")
    print(f"Session: {args.session}")
    print(f"Params: {params}")
    print()

    result = action.execute(args.session, params)

    # Output result
    print(f"\nResult:")
    print(f"  Success: {result.success}")
    print(f"  Duration: {result.duration_seconds}s")
    print(f"  Outputs: {result.outputs}")
    if result.metadata:
        print(f"  Metadata: {json.dumps(result.metadata, indent=2)}")
    if result.error:
        print(f"  Error: {result.error}")

    return 0 if result.success else 1

if __name__ == '__main__':
    sys.exit(main())
```

---

### Shell Wrapper

```bash
#!/bin/bash
# scripts/run-action.sh
# Universal action runner

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load environment
source "$PROJECT_ROOT/.env"

# Activate virtual environment if exists
if [ -d "$PROJECT_ROOT/venv-ai-analysis" ]; then
    source "$PROJECT_ROOT/venv-ai-analysis/bin/activate"
fi

# Run action
cd "$PROJECT_ROOT"
python3 -m actions.run_action "$@"
```

---

### API Endpoint

```javascript
// cognito-stack/api/actions.js
'use strict';

const AWS = require('aws-sdk');
const lambda = new AWS.Lambda();
const s3 = new AWS.S3();

const BUCKET = process.env.S3_BUCKET_NAME;
const SERVICE = process.env.SERVICE_NAME || 'clouddrive-app';
const STAGE = process.env.STAGE || 'prod';

// Available actions and their Lambda functions
const ACTIONS = {
  'ai-analysis': `${SERVICE}-${STAGE}-runAiAnalysis`,
  'topics': `${SERVICE}-${STAGE}-runTopics`,
  // Add more as needed
};

/**
 * POST /api/actions/{actionName}
 * Body: { sessionId, params: {} }
 */
module.exports.runAction = async (event) => {
  const userId = event.requestContext.authorizer.claims.sub;
  const actionName = event.pathParameters.actionName;
  const body = JSON.parse(event.body || '{}');
  const { sessionId, params = {} } = body;

  // Validate action exists
  if (!ACTIONS[actionName]) {
    return response(400, {
      error: `Unknown action: ${actionName}`,
      available: Object.keys(ACTIONS)
    });
  }

  // Build session path
  const sessionPath = `users/${userId}/audio/sessions/${sessionId}`;

  // Verify session exists
  try {
    await s3.headObject({
      Bucket: BUCKET,
      Key: `${sessionPath}/metadata.json`
    }).promise();
  } catch (err) {
    return response(404, { error: 'Session not found' });
  }

  // Invoke action Lambda asynchronously
  await lambda.invoke({
    FunctionName: ACTIONS[actionName],
    InvocationType: 'Event',  // Async
    Payload: JSON.stringify({
      sessionPath,
      params,
      userId
    })
  }).promise();

  return response(202, {
    status: 'started',
    action: actionName,
    sessionId,
    message: 'Action started. Poll /api/actions/status for completion.'
  });
};

/**
 * GET /api/actions
 * List available actions
 */
module.exports.listActions = async (event) => {
  return response(200, {
    actions: [
      {
        name: 'ai-analysis',
        description: 'Generate AI analysis with action items, themes, and highlights',
        requires: ['transcription-processed.json'],
        produces: ['transcription-ai-analysis.json']
      },
      {
        name: 'topics',
        description: 'Detect topic boundaries using semantic embeddings',
        requires: ['transcription-processed.json'],
        produces: ['layers/layer-3-topic-segments/data.json']
      }
    ]
  });
};

/**
 * GET /api/actions/status?sessionId=xxx&action=yyy
 * Check if action output exists (simple completion check)
 */
module.exports.actionStatus = async (event) => {
  const userId = event.requestContext.authorizer.claims.sub;
  const sessionId = event.queryStringParameters?.sessionId;
  const actionName = event.queryStringParameters?.action;

  if (!sessionId || !actionName) {
    return response(400, { error: 'sessionId and action required' });
  }

  const sessionPath = `users/${userId}/audio/sessions/${sessionId}`;

  // Check if output file exists
  const outputFiles = {
    'ai-analysis': 'transcription-ai-analysis.json',
    'topics': 'layers/layer-3-topic-segments/data.json'
  };

  const outputFile = outputFiles[actionName];
  if (!outputFile) {
    return response(400, { error: 'Unknown action' });
  }

  try {
    await s3.headObject({
      Bucket: BUCKET,
      Key: `${sessionPath}/${outputFile}`
    }).promise();

    return response(200, {
      status: 'completed',
      outputFile
    });
  } catch (err) {
    return response(200, {
      status: 'pending_or_not_started'
    });
  }
};

function response(statusCode, body) {
  return {
    statusCode,
    headers: {
      'Content-Type': 'application/json',
      'Access-Control-Allow-Origin': '*'
    },
    body: JSON.stringify(body)
  };
}
```

---

### Error Handling Patterns

```python
# In action implementation:

def run(self, session_path, params):
    try:
        # Main logic here
        result = self._process(session_path)
        return ActionResult(success=True, outputs=self.produces, ...)

    except anthropic.APIError as e:
        # Claude API errors
        return ActionResult(
            success=False,
            outputs=[],
            error=f"Claude API error: {e.message}"
        )

    except self._s3.exceptions.NoSuchKey as e:
        # Missing file
        return ActionResult(
            success=False,
            outputs=[],
            error=f"Required file not found: {e}"
        )

    except json.JSONDecodeError as e:
        # Invalid JSON from Claude
        return ActionResult(
            success=False,
            outputs=[],
            error=f"Failed to parse Claude response as JSON"
        )

    # ActionBase.execute() catches all other exceptions
```

---

### Testing Actions

```python
# tests/test_actions.py

import pytest
from actions import get_action
from actions.base import ActionResult

# Mock S3 for testing
@pytest.fixture
def mock_s3(mocker):
    mock = mocker.patch('boto3.client')
    return mock

def test_ai_analysis_requires_transcript(mock_s3):
    """Action should fail if transcript doesn't exist."""
    mock_s3.return_value.head_object.side_effect = Exception("NoSuchKey")

    action = get_action('ai-analysis')()
    result = action.execute('users/test/audio/sessions/test123', {})

    assert not result.success
    assert 'transcription-processed.json' in result.error

def test_ai_analysis_success(mock_s3, mocker):
    """Action should succeed with valid transcript."""
    # Mock S3 to return transcript
    mock_s3.return_value.get_object.return_value = {
        'Body': io.BytesIO(json.dumps({
            'paragraphs': [{'text': 'Hello world', 'start': 0}],
            'stats': {'totalDuration': 60}
        }).encode())
    }

    # Mock Claude API
    mocker.patch('anthropic.Anthropic.messages.create', return_value=...)

    action = get_action('ai-analysis')()
    result = action.execute('users/test/audio/sessions/test123', {})

    assert result.success
    assert 'transcription-ai-analysis.json' in result.outputs
```

---

## Pipelines: Chaining Actions Together

### Pipeline Definition Format

```yaml
# pipelines/full-analysis.yaml
# Run a complete analysis pipeline on a session

name: full-analysis
description: Complete transcript processing with AI analysis
version: '1.0'

# Actions run in order, later steps can depend on earlier ones
steps:
  - name: preprocess
    action: preprocess
    description: Prepare transcript for analysis

  - name: ai-analysis
    action: ai-analysis
    depends_on: preprocess
    description: Generate AI insights with Claude

  - name: topics
    action: topics
    depends_on: preprocess
    description: Detect topic boundaries
    params:
      threshold: 0.20
      window_size: 3

  - name: summarize
    action: summarize
    depends_on: ai-analysis
    description: Generate executive summary

# Optional: what to do on failure
on_failure: stop  # Options: stop, continue, retry
```

### Pipeline Runner

```python
# actions/pipeline_runner.py
"""
Execute a pipeline of actions in sequence with dependency resolution.
"""

import yaml
from pathlib import Path
from actions import get_action

def run_pipeline(pipeline_name: str, session_path: str, params: dict = None):
    """
    Run a pipeline by name.

    Args:
        pipeline_name: Name of pipeline (without .yaml)
        session_path: S3 session path
        params: Override params for specific steps

    Returns:
        PipelineResult with success status and step results
    """
    # Load pipeline definition
    pipeline_file = Path(__file__).parent.parent / 'pipelines' / f'{pipeline_name}.yaml'
    with open(pipeline_file) as f:
        pipeline = yaml.safe_load(f)

    results = {}
    completed = set()

    # Run steps in order, respecting dependencies
    for step in pipeline['steps']:
        step_name = step['name']
        action_name = step['action']
        depends_on = step.get('depends_on', [])
        step_params = {**step.get('params', {}), **(params or {}).get(step_name, {})}

        # Check dependencies
        if isinstance(depends_on, str):
            depends_on = [depends_on]

        missing_deps = [d for d in depends_on if d not in completed]
        if missing_deps:
            print(f"  Skipping {step_name}: waiting for {missing_deps}")
            continue

        # Run action
        print(f"  Running step: {step_name} ({action_name})")
        action = get_action(action_name)()
        result = action.execute(session_path, step_params)

        results[step_name] = result

        if result.success:
            completed.add(step_name)
            print(f"    ✓ Completed in {result.duration_seconds}s")
        else:
            print(f"    ✗ Failed: {result.error}")
            if pipeline.get('on_failure') == 'stop':
                break

    return PipelineResult(
        success=all(r.success for r in results.values()),
        steps=results,
        completed=list(completed)
    )
```

### Pipeline CLI

```bash
#!/bin/bash
# scripts/run-pipeline.sh

set -euo pipefail

PIPELINE_NAME=$1
shift

python3 -m actions.pipeline_runner "$PIPELINE_NAME" "$@"
```

### Example: Daily Batch Pipeline

```yaml
# pipelines/daily-batch.yaml
# Run by cron every night at 2am

name: daily-batch
description: Process all pending sessions overnight

steps:
  - name: scan
    action: scan-pending
    description: Find sessions needing processing

  - name: transcribe
    action: batch-transcribe
    depends_on: scan
    params:
      provider: runpod  # Use cheaper GPU

  - name: diarize
    action: batch-diarize
    depends_on: transcribe

  - name: analyze-all
    action: batch-ai-analysis
    depends_on: diarize

on_failure: continue  # Keep processing other sessions
```

---

## Deployment: serverless.yml Configuration

### Add to cognito-stack/serverless.yml

```yaml
# Add these functions to the existing functions section:

functions:
  # ... existing functions ...

  # ─────────────────────────────────────────────────────────────────
  # Actions API
  # ─────────────────────────────────────────────────────────────────

  # List available actions
  listActions:
    handler: api/actions.listActions
    events:
      - http:
          path: /api/actions
          method: get
          cors: true
          authorizer:
            type: COGNITO_USER_POOLS
            authorizerId:
              Ref: ApiGatewayAuthorizer

  # Run an action
  runAction:
    handler: api/actions.runAction
    timeout: 30  # API Gateway timeout
    events:
      - http:
          path: /api/actions/{actionName}
          method: post
          cors: true
          authorizer:
            type: COGNITO_USER_POOLS
            authorizerId:
              Ref: ApiGatewayAuthorizer

  # Check action status
  actionStatus:
    handler: api/actions.actionStatus
    events:
      - http:
          path: /api/actions/status
          method: get
          cors: true
          authorizer:
            type: COGNITO_USER_POOLS
            authorizerId:
              Ref: ApiGatewayAuthorizer

  # ─────────────────────────────────────────────────────────────────
  # Action Processors (async, longer timeout)
  # ─────────────────────────────────────────────────────────────────

  runAiAnalysis:
    handler: api/action-processors/ai-analysis.handler
    timeout: 120  # 2 minutes for Claude API
    memorySize: 512
    environment:
      ANTHROPIC_API_KEY: ${env:ANTHROPIC_API_KEY}

  runTopics:
    handler: api/action-processors/topics.handler
    timeout: 300  # 5 minutes for Bedrock embeddings
    memorySize: 1024
    environment:
      AWS_REGION: ${self:provider.region}

  runSummarize:
    handler: api/action-processors/summarize.handler
    timeout: 60
    memorySize: 512
    environment:
      ANTHROPIC_API_KEY: ${env:ANTHROPIC_API_KEY}
```

### IAM Permissions

```yaml
# Add to provider.iamRoleStatements:

provider:
  iamRoleStatements:
    # ... existing statements ...

    # Allow invoking action processor Lambdas
    - Effect: Allow
      Action:
        - lambda:InvokeFunction
      Resource:
        - arn:aws:lambda:${self:provider.region}:${aws:accountId}:function:${self:service}-${self:provider.stage}-runAiAnalysis
        - arn:aws:lambda:${self:provider.region}:${aws:accountId}:function:${self:service}-${self:provider.stage}-runTopics
        - arn:aws:lambda:${self:provider.region}:${aws:accountId}:function:${self:service}-${self:provider.stage}-runSummarize

    # Allow Bedrock for embeddings
    - Effect: Allow
      Action:
        - bedrock:InvokeModel
      Resource:
        - arn:aws:bedrock:${self:provider.region}::foundation-model/amazon.titan-embed-text-v2:0
```

### Deployment Steps

```bash
# 1. Install dependencies
cd cognito-stack
npm install @anthropic-ai/sdk

# 2. Create action processor files
mkdir -p api/action-processors
# Copy code from plan into these files

# 3. Deploy
npx serverless deploy

# 4. Verify
curl -H "Authorization: Bearer $TOKEN" \
  https://your-api.execute-api.us-east-2.amazonaws.com/prod/api/actions

# 5. Test an action
curl -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"sessionId": "your-session-id"}' \
  https://your-api.execute-api.us-east-2.amazonaws.com/prod/api/actions/ai-analysis
```

---

## UI Integration: Transcript Editor

### Add Actions Panel to transcript-editor-v2.html.template

```html
<!-- Insert after existing controls, before transcript display -->

<!-- ═══════════════════════════════════════════════════════════════════ -->
<!-- AI ACTIONS PANEL -->
<!-- ═══════════════════════════════════════════════════════════════════ -->

<div id="actions-panel" class="actions-panel">
  <h3>AI Processing</h3>

  <div class="action-buttons">
    <!-- AI Analysis -->
    <button id="btn-ai-analysis" class="action-btn" onclick="runAction('ai-analysis')">
      <span class="action-icon">🔍</span>
      <span class="action-label">Generate AI Analysis</span>
      <span class="action-status" id="status-ai-analysis"></span>
    </button>

    <!-- Topic Detection -->
    <button id="btn-topics" class="action-btn" onclick="runAction('topics')">
      <span class="action-icon">📑</span>
      <span class="action-label">Detect Topics</span>
      <span class="action-status" id="status-topics"></span>
    </button>

    <!-- Summarize -->
    <button id="btn-summarize" class="action-btn" onclick="runAction('summarize')">
      <span class="action-icon">📝</span>
      <span class="action-label">Generate Summary</span>
      <span class="action-status" id="status-summarize"></span>
    </button>

    <!-- Re-diarize (existing) -->
    <button id="btn-diarize" class="action-btn" onclick="showDiarizeModal()">
      <span class="action-icon">👥</span>
      <span class="action-label">Re-diarize Speakers</span>
      <span class="action-status" id="status-diarize"></span>
    </button>
  </div>

  <!-- Results display -->
  <div id="action-results" class="action-results hidden">
    <div id="result-ai-analysis" class="result-section hidden">
      <h4>AI Analysis</h4>
      <div class="result-content"></div>
    </div>
    <div id="result-topics" class="result-section hidden">
      <h4>Topics</h4>
      <div class="result-content"></div>
    </div>
    <div id="result-summarize" class="result-section hidden">
      <h4>Summary</h4>
      <div class="result-content"></div>
    </div>
  </div>
</div>

<style>
.actions-panel {
  background: #f8f9fa;
  border-radius: 8px;
  padding: 16px;
  margin-bottom: 20px;
}

.actions-panel h3 {
  margin: 0 0 12px 0;
  font-size: 14px;
  color: #666;
  text-transform: uppercase;
  letter-spacing: 0.5px;
}

.action-buttons {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}

.action-btn {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 10px 16px;
  border: 1px solid #ddd;
  border-radius: 6px;
  background: white;
  cursor: pointer;
  transition: all 0.2s;
}

.action-btn:hover:not(:disabled) {
  background: #f0f0f0;
  border-color: #bbb;
}

.action-btn:disabled {
  opacity: 0.6;
  cursor: not-allowed;
}

.action-btn.running {
  border-color: #007bff;
  background: #e7f1ff;
}

.action-btn.completed {
  border-color: #28a745;
}

.action-btn.failed {
  border-color: #dc3545;
}

.action-icon {
  font-size: 18px;
}

.action-label {
  font-weight: 500;
}

.action-status {
  font-size: 12px;
  color: #666;
  margin-left: auto;
}

.action-status.running {
  color: #007bff;
}

.action-status.completed {
  color: #28a745;
}

.action-status.failed {
  color: #dc3545;
}

.action-results {
  margin-top: 16px;
  border-top: 1px solid #ddd;
  padding-top: 16px;
}

.result-section {
  margin-bottom: 16px;
}

.result-section h4 {
  margin: 0 0 8px 0;
  font-size: 13px;
  color: #333;
}

.result-content {
  background: white;
  border: 1px solid #eee;
  border-radius: 4px;
  padding: 12px;
  font-size: 14px;
  max-height: 200px;
  overflow-y: auto;
}
</style>
```

### JavaScript for Actions

```javascript
// Add to transcript-editor-v2.html.template <script> section

// ═══════════════════════════════════════════════════════════════════════
// ACTIONS SYSTEM
// ═══════════════════════════════════════════════════════════════════════

const ActionsManager = {
  pollInterval: null,
  pollFrequency: 3000,  // 3 seconds

  // Run an action
  async runAction(actionName) {
    const btn = document.getElementById(`btn-${actionName}`);
    const status = document.getElementById(`status-${actionName}`);

    // Update UI
    btn.disabled = true;
    btn.classList.add('running');
    status.textContent = 'Starting...';
    status.className = 'action-status running';

    try {
      const response = await fetch(`${API_ENDPOINT}/actions/${actionName}`, {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${await getIdToken()}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          sessionId: currentSessionId
        })
      });

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`);
      }

      status.textContent = 'Processing...';
      this.startPolling();

    } catch (error) {
      console.error('Failed to start action:', error);
      btn.disabled = false;
      btn.classList.remove('running');
      btn.classList.add('failed');
      status.textContent = 'Failed to start';
      status.className = 'action-status failed';
    }
  },

  // Start polling for status
  startPolling() {
    if (this.pollInterval) return;

    this.pollInterval = setInterval(() => this.checkStatus(), this.pollFrequency);
    this.checkStatus();  // Immediate check
  },

  // Check status of all actions
  async checkStatus() {
    const actions = ['ai-analysis', 'topics', 'summarize'];

    for (const actionName of actions) {
      try {
        const response = await fetch(
          `${API_ENDPOINT}/actions/status?sessionId=${currentSessionId}&action=${actionName}`,
          {
            headers: { 'Authorization': `Bearer ${await getIdToken()}` }
          }
        );

        const data = await response.json();
        this.updateActionUI(actionName, data.status, data.outputFile);

      } catch (error) {
        console.warn(`Failed to check status for ${actionName}:`, error);
      }
    }

    // Stop polling if no actions are running
    const anyRunning = actions.some(name => {
      const btn = document.getElementById(`btn-${name}`);
      return btn && btn.classList.contains('running');
    });

    if (!anyRunning && this.pollInterval) {
      clearInterval(this.pollInterval);
      this.pollInterval = null;
    }
  },

  // Update UI for a single action
  updateActionUI(actionName, status, outputFile) {
    const btn = document.getElementById(`btn-${actionName}`);
    const statusEl = document.getElementById(`status-${actionName}`);
    if (!btn || !statusEl) return;

    btn.classList.remove('running', 'completed', 'failed');

    switch (status) {
      case 'completed':
        btn.disabled = false;
        btn.classList.add('completed');
        statusEl.textContent = '✓ Done';
        statusEl.className = 'action-status completed';
        this.loadResult(actionName, outputFile);
        break;

      case 'processing':
      case 'pending':
        btn.disabled = true;
        btn.classList.add('running');
        statusEl.textContent = 'Processing...';
        statusEl.className = 'action-status running';
        break;

      case 'failed':
        btn.disabled = false;
        btn.classList.add('failed');
        statusEl.textContent = '✗ Failed';
        statusEl.className = 'action-status failed';
        break;

      default:
        btn.disabled = false;
        statusEl.textContent = '';
        statusEl.className = 'action-status';
    }
  },

  // Load and display result
  async loadResult(actionName, outputFile) {
    if (!outputFile) return;

    const resultSection = document.getElementById(`result-${actionName}`);
    const resultContent = resultSection?.querySelector('.result-content');
    const resultsContainer = document.getElementById('action-results');

    if (!resultSection || !resultContent) return;

    try {
      // Get presigned URL for the result file
      const sessionPath = `users/${currentUserId}/audio/sessions/${currentSessionId}`;
      const response = await fetch(
        `${API_ENDPOINT}/download?key=${sessionPath}/${outputFile}`,
        {
          headers: { 'Authorization': `Bearer ${await getIdToken()}` }
        }
      );

      const { url } = await response.json();
      const data = await fetch(url).then(r => r.json());

      // Display based on action type
      resultContent.innerHTML = this.formatResult(actionName, data);
      resultSection.classList.remove('hidden');
      resultsContainer.classList.remove('hidden');

    } catch (error) {
      console.error(`Failed to load result for ${actionName}:`, error);
      resultContent.innerHTML = '<p class="error">Failed to load result</p>';
      resultSection.classList.remove('hidden');
      resultsContainer.classList.remove('hidden');
    }
  },

  // Format result for display
  formatResult(actionName, data) {
    switch (actionName) {
      case 'ai-analysis':
        return this.formatAiAnalysis(data);
      case 'topics':
        return this.formatTopics(data);
      case 'summarize':
        return this.formatSummary(data);
      default:
        return `<pre>${JSON.stringify(data, null, 2)}</pre>`;
    }
  },

  formatAiAnalysis(data) {
    const items = data.actionItems || [];
    const themes = data.keyThemes || [];
    const highlights = data.highlights || [];

    return `
      <div class="analysis-section">
        <h5>Action Items (${items.length})</h5>
        <ul>
          ${items.map(i => `<li>${i.summary} <small>[${this.formatTime(i.timeCodeStart)}]</small></li>`).join('')}
        </ul>
      </div>
      <div class="analysis-section">
        <h5>Key Themes (${themes.length})</h5>
        <ul>
          ${themes.map(t => `<li><strong>${t.theme}</strong>: ${t.summary}</li>`).join('')}
        </ul>
      </div>
      <div class="analysis-section">
        <h5>Highlights (${highlights.length})</h5>
        <ul>
          ${highlights.map(h => `<li>${h.summary} <small>[${this.formatTime(h.timeCodeStart)}]</small></li>`).join('')}
        </ul>
      </div>
    `;
  },

  formatTopics(data) {
    const topics = data.topics || [];
    return `
      <div class="topics-list">
        ${topics.map((t, i) => `
          <div class="topic-item" onclick="seekTo(${t.startTime})">
            <span class="topic-number">${i + 1}</span>
            <span class="topic-name">${t.name || 'Topic ' + (i + 1)}</span>
            <span class="topic-time">${this.formatTime(t.startTime)} - ${this.formatTime(t.endTime)}</span>
          </div>
        `).join('')}
      </div>
    `;
  },

  formatSummary(data) {
    return `
      <div class="summary-content">
        ${data.summary || data.text || 'No summary available'}
      </div>
    `;
  },

  formatTime(seconds) {
    const mins = Math.floor(seconds / 60);
    const secs = Math.floor(seconds % 60);
    return `${mins}:${secs.toString().padStart(2, '0')}`;
  }
};

// Global function for onclick handlers
function runAction(actionName) {
  ActionsManager.runAction(actionName);
}

// Check status on page load
document.addEventListener('DOMContentLoaded', () => {
  // Wait for session to load, then check status
  setTimeout(() => ActionsManager.checkStatus(), 1000);
});
```

### Integration with Existing Code

```javascript
// In transcript-editor-v2.html.template, modify existing loadSession():

async function loadSession(sessionId) {
  // ... existing code ...

  // After loading transcript, check action status
  ActionsManager.checkStatus();
}
```

---

## The Simplest Implementation

If you want the absolute minimum viable version:

```python
# actions/base.py (30 lines)
class Action:
    def load(self, path, file): ...
    def save(self, path, file, data): ...

# actions/ai_analysis.py (10 lines - just imports existing)
from actions.base import Action
from scripts.lib.ai_analysis import process_session

class AiAnalysis(Action):
    def run(self, path, params):
        return process_session(path)

# run-action.sh (5 lines)
#!/bin/bash
python3 -c "from actions import $1; $1().run('$2', {})"
```

**That's 45 lines for the core system.** Everything else is convenience.

---

## Key Insight

The existing Python scripts are 90% of the work. We're just:
1. Creating a standard interface (ActionBase)
2. Adding a CLI runner (run-action.sh)
3. Adding an API trigger (actions.js)
4. Adding UI buttons

**The actual processing logic stays the same.**
