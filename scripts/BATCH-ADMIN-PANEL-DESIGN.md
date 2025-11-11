# Batch Transcription Admin Panel - Design Document

## Executive Summary

This document describes the enhanced batch transcription system with a web-based admin panel, smart GPU lifecycle management, and automated 2-hour scheduling. This design optimizes costs by only starting the GPU when there are pending transcription jobs, and provides full visibility into batch operations.

## Problem Statement

### Current Issues
- **Original 5-minute cron**: Wasteful GPU starts even when no work exists
- **No visibility**: Can't see what needs transcription without checking S3 manually
- **No control**: Can't manually trigger batch or review pending jobs
- **No reporting**: No history of batch runs, costs, or success rates

### Business Impact
- **High costs**: GPU running unnecessarily
- **Operational overhead**: Manual S3 checks required
- **No accountability**: Can't track batch transcription effectiveness

## Solution Overview

### Core Components

1. **Web-based Admin Panel** - View pending jobs, trigger batches, see reports
2. **Smart S3 Scanner** - Detects missing transcriptions without starting GPU
3. **Intelligent GPU Manager** - Starts GPU only when work exists, guaranteed shutdown
4. **2-Hour Scheduler** - Reduces from 288 daily checks to 12
5. **Report System** - JSON + HTML reports with cost tracking

### Key Benefits

- **95% cost reduction** - From ~$144/day to ~$2-6/day
- **Full visibility** - See exactly what needs transcription
- **Manual control** - Trigger batch on-demand
- **Cost tracking** - Know your GPU spend per batch
- **Operational reports** - History of all batch runs

## Architecture

### High-Level Flow

```
┌─────────────────────────────────────────────────────────┐
│                  Every 2 Hours (Cron)                    │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│  525-scan-missing-chunks.sh                              │
│  - Scans S3 for all sessions                            │
│  - Compares audio vs transcription chunks               │
│  - Generates pending-jobs.json                          │
│  - Returns: chunk count                                 │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼
                ┌────┴────┐
                │ Jobs > 0?│
                └────┬────┘
                     │
           ┌─────────┴─────────┐
           │                   │
          Yes                 No
           │                   │
           ▼                   ▼
┌──────────────────┐  ┌────────────────────┐
│ 530-enhanced-    │  │ 535-generate-      │
│ batch-transcribe │  │ batch-report       │
│                  │  │ Status: "skipped"  │
│ 1. Start GPU     │  │ Chunks: 0          │
│ 2. Wait ready    │  └────────────────────┘
│ 3. Transcribe    │
│ 4. Stop GPU      │
│ 5. Report        │
└──────────────────┘
```

### User Interaction Flow

```
┌─────────────────────────────────────────────────────────┐
│  User Opens Admin Panel                                 │
│  https://edge-box-ip/batch-admin.html                  │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│  Panel loads via /api/batch/status                      │
│  - Fetches pending-jobs.json                            │
│  - Displays list of sessions with missing chunks        │
│  - Shows GPU status (running/stopped)                   │
│  - Lists recent batch reports                           │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│  User Reviews Pending Jobs                              │
│  ┌───────────────────────────────────────────────────┐ │
│  │ Session: session_2025-11-09_...                   │ │
│  │ Missing: chunk-001, chunk-007, chunk-008          │ │
│  │ Audio Size: 2.5 MB                                │ │
│  │ Created: 2 hours ago                              │ │
│  └───────────────────────────────────────────────────┘ │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│  User Clicks "Run Batch Now" (optional)                 │
│  - Triggers /api/batch/trigger                          │
│  - Backend runs 530-enhanced-batch-transcribe.sh        │
│  - Panel shows progress in real-time                    │
└─────────────────────────────────────────────────────────┘
```

## Component Details

### 1. S3 Scanner (525-scan-missing-chunks.sh)

**Purpose**: Fast S3 scan to detect missing transcriptions without starting GPU.

**Execution Time**: ~5-10 seconds for 100 sessions

**Output**: `pending-jobs.json`

**JSON Format**:
```json
{
  "timestamp": "2025-11-10T02:00:00Z",
  "totalSessions": 15,
  "sessionsWithMissingChunks": 3,
  "totalMissingChunks": 12,
  "estimatedGpuTime": "8 minutes",
  "estimatedCost": "$0.067",
  "sessions": [
    {
      "sessionId": "session_2025-11-09T20_50_33_875Z",
      "userId": "512b3590-30b1-707d-ed46-bf68df7b52d5",
      "sessionPath": "users/.../audio/sessions/...",
      "audioChunks": ["001", "002", "003", "007", "008"],
      "transcriptionChunks": ["002", "003"],
      "missingChunks": ["001", "007", "008"],
      "totalAudioSize": 2621440,
      "createdAt": "2025-11-09T20:50:33Z",
      "ageHours": 5.2
    },
    {
      "sessionId": "session_2025-11-10T01_30_43_049Z",
      "userId": "512b3590-30b1-707d-ed46-bf68df7b52d5",
      "sessionPath": "users/.../audio/sessions/...",
      "audioChunks": ["001", "002", "003", "004", "005", "006", "007", "008", "009", "010", "011"],
      "transcriptionChunks": ["002", "003", "004", "005", "006", "009", "010"],
      "missingChunks": ["001", "007", "008", "011"],
      "totalAudioSize": 3145728,
      "createdAt": "2025-11-10T01:30:43Z",
      "ageHours": 0.5
    }
  ]
}
```

**Key Features**:
- No GPU required
- Fast execution
- Detailed job information
- Cost estimation
- Age tracking (prioritize old sessions)

**Script Outline**:
```bash
#!/bin/bash
# 525-scan-missing-chunks.sh

# 1. Scan S3 for all audio sessions
find_all_sessions() {
    aws s3 ls s3://$BUCKET/users/ --recursive | \
        grep '/audio/sessions/.*chunk-.*\.webm$' | \
        awk '{print $4}' | sed 's|/chunk-.*||' | sort -u
}

# 2. For each session, compare audio vs transcription
analyze_session() {
    local session_path=$1

    audio_chunks=$(list_audio_chunks "$session_path")
    trans_chunks=$(list_transcription_chunks "$session_path")

    # Find missing
    missing=$(comm -23 <(echo "$audio_chunks" | sort) <(echo "$trans_chunks" | sort))

    # Build session JSON
    echo "{...}"
}

# 3. Generate pending-jobs.json
generate_jobs_file() {
    cat > pending-jobs.json <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "totalSessions": $total,
  "sessionsWithMissingChunks": $with_missing,
  "totalMissingChunks": $missing_count,
  "sessions": [...]
}
EOF
}

# Main
sessions=$(find_all_sessions)
for session in $sessions; do
    analyze_session "$session"
done
generate_jobs_file
```

### 2. Enhanced Batch Worker (530-enhanced-batch-transcribe.sh)

**Purpose**: Smart batch transcription with GPU lifecycle management.

**Key Features**:
- Reads `pending-jobs.json` from scanner
- Starts GPU only if jobs exist
- Waits for GPU to be fully ready (SSH + WhisperLive)
- Processes all chunks
- Guaranteed GPU shutdown
- Generates detailed report

**GPU Lifecycle States**:
```
┌─────────┐  No jobs   ┌─────────┐
│ Stopped │──────────▶ │ Stopped │ (Script exits)
└─────────┘            └─────────┘

┌─────────┐  Jobs exist ┌──────────┐  Ready   ┌────────────┐
│ Stopped │───────────▶ │ Starting │─────────▶│ Processing │
└─────────┘             └──────────┘           └─────┬──────┘
                                                      │
                                                      │ Done
                                                      ▼
                                               ┌──────────┐
                                               │ Stopping │
                                               └─────┬────┘
                                                     │
                                                     ▼
                                               ┌─────────┐
                                               │ Stopped │
                                               └─────────┘
```

**Script Outline**:
```bash
#!/bin/bash
# 530-enhanced-batch-transcribe.sh

JOBS_FILE="pending-jobs.json"
WE_STARTED_GPU=false

# Trap to ensure GPU shutdown on exit
cleanup() {
    if [ "$WE_STARTED_GPU" = "true" ]; then
        log_warn "Script interrupted, shutting down GPU..."
        stop_gpu
    fi
}
trap cleanup EXIT INT TERM

# 1. Read pending jobs
read_pending_jobs() {
    if [ ! -f "$JOBS_FILE" ]; then
        log_error "No jobs file found. Run 525-scan-missing-chunks.sh first"
        exit 1
    fi

    MISSING_COUNT=$(jq '.totalMissingChunks' "$JOBS_FILE")

    if [ "$MISSING_COUNT" -eq 0 ]; then
        log_info "No pending transcriptions"
        generate_report "skipped" 0 0
        exit 0
    fi

    log_info "Found $MISSING_COUNT chunks to transcribe"
}

# 2. Start GPU if needed
start_gpu_if_needed() {
    GPU_STATE=$(aws ec2 describe-instances \
        --instance-ids "$GPU_INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text)

    if [ "$GPU_STATE" = "stopped" ]; then
        log_info "Starting GPU instance $GPU_INSTANCE_ID..."
        aws ec2 start-instances --instance-ids "$GPU_INSTANCE_ID"
        WE_STARTED_GPU=true

        wait_for_gpu_ready
    elif [ "$GPU_STATE" = "running" ]; then
        log_info "GPU already running"
    else
        log_error "GPU in unexpected state: $GPU_STATE"
        exit 1
    fi
}

# 3. Wait for GPU to be ready
wait_for_gpu_ready() {
    log_info "Waiting for GPU to be ready (2-3 minutes)..."

    # Wait for instance to be running
    aws ec2 wait instance-running --instance-ids "$GPU_INSTANCE_ID"
    log_success "GPU instance running"

    # Wait for SSH
    log_info "Waiting for SSH connectivity..."
    for i in {1..30}; do
        if ssh -i "$SSH_KEY" -o ConnectTimeout=5 "$SSH_USER@$GPU_IP" "echo OK" &>/dev/null; then
            log_success "SSH connected"
            break
        fi
        sleep 10
    done

    # Wait for WhisperLive service
    log_info "Waiting for WhisperLive service..."
    for i in {1..10}; do
        if ssh -i "$SSH_KEY" "$SSH_USER@$GPU_IP" "systemctl is-active whisperlive" &>/dev/null; then
            log_success "WhisperLive ready"
            break
        fi
        sleep 5
    done

    log_success "GPU fully ready"
}

# 4. Process all chunks
process_all_chunks() {
    local sessions=$(jq -r '.sessions[] | @base64' "$JOBS_FILE")

    for session_b64 in $sessions; do
        session=$(echo "$session_b64" | base64 -d)

        session_id=$(echo "$session" | jq -r '.sessionId')
        session_path=$(echo "$session" | jq -r '.sessionPath')
        missing_chunks=$(echo "$session" | jq -r '.missingChunks[]')

        log_info "Processing session: $session_id"

        for chunk_num in $missing_chunks; do
            transcribe_chunk "$session_path" "chunk-${chunk_num}.webm" "$chunk_num"
        done
    done
}

# 5. Stop GPU
stop_gpu() {
    log_info "Stopping GPU instance to save costs..."
    aws ec2 stop-instances --instance-ids "$GPU_INSTANCE_ID"

    # Wait for it to stop
    aws ec2 wait instance-stopped --instance-ids "$GPU_INSTANCE_ID"
    log_success "GPU stopped"
}

# Main execution
log_info "Starting enhanced batch transcription..."

read_pending_jobs
start_gpu_if_needed
process_all_chunks

# Generate report
generate_report "success" "$MISSING_COUNT" "$CHUNKS_TRANSCRIBED" "$CHUNKS_FAILED"

# Cleanup (stops GPU if we started it)
exit 0
```

**Safety Features**:
- `trap` ensures GPU shutdown even if script crashes
- Validates GPU state before starting
- Comprehensive error handling
- Detailed logging at each step

### 3. Report Generator (535-generate-batch-report.sh)

**Purpose**: Create comprehensive reports in JSON and HTML formats.

**Report Storage**: `batch-reports/YYYY-MM-DD-HHMM.json`

**JSON Report Format**:
```json
{
  "reportId": "batch-2025-11-10-0200",
  "timestamp": "2025-11-10T02:00:00Z",
  "status": "success",
  "execution": {
    "startTime": "2025-11-10T02:00:05Z",
    "endTime": "2025-11-10T02:08:37Z",
    "durationSeconds": 512,
    "durationHuman": "8m 32s"
  },
  "gpu": {
    "instanceId": "i-03a292875d9b12688",
    "started": true,
    "startTime": "2025-11-10T02:00:10Z",
    "stopTime": "2025-11-10T02:08:30Z",
    "runtimeSeconds": 500,
    "runtimeHuman": "8m 20s",
    "costUSD": 0.067
  },
  "scanning": {
    "totalSessions": 15,
    "sessionsScanned": 15,
    "sessionsWithMissingChunks": 3
  },
  "transcription": {
    "chunksFound": 12,
    "chunksTranscribed": 12,
    "chunksFailed": 0,
    "successRate": 100.0
  },
  "sessions": [
    {
      "sessionId": "session_2025-11-09T20_50_33_875Z",
      "userId": "512b3590-30b1-707d-ed46-bf68df7b52d5",
      "chunksProcessed": 3,
      "chunkNumbers": ["001", "007", "008"],
      "status": "success",
      "duration": "2m 15s"
    },
    {
      "sessionId": "session_2025-11-10T01_30_43_049Z",
      "userId": "512b3590-30b1-707d-ed46-bf68df7b52d5",
      "chunksProcessed": 9,
      "chunkNumbers": ["001", "007", "008", "011", "012", "013", "014", "015", "016"],
      "status": "success",
      "duration": "6m 05s"
    }
  ],
  "errors": [],
  "nextScheduledRun": "2025-11-10T04:00:00Z"
}
```

**HTML Report** (for viewing in browser):
```html
<!DOCTYPE html>
<html>
<head>
    <title>Batch Report - 2025-11-10 02:00</title>
    <style>
        body { font-family: Arial; margin: 20px; }
        .success { color: green; }
        .error { color: red; }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background-color: #f2f2f2; }
    </style>
</head>
<body>
    <h1>Batch Transcription Report</h1>
    <h2>2025-11-10 02:00:00 UTC</h2>

    <h3>Summary</h3>
    <table>
        <tr><th>Status</th><td class="success">✓ Success</td></tr>
        <tr><th>Duration</th><td>8m 32s</td></tr>
        <tr><th>Chunks Processed</th><td>12 / 12</td></tr>
        <tr><th>GPU Runtime</th><td>8m 20s</td></tr>
        <tr><th>Cost</th><td>$0.067</td></tr>
    </table>

    <h3>Sessions Processed</h3>
    <table>
        <tr>
            <th>Session ID</th>
            <th>Chunks</th>
            <th>Status</th>
            <th>Duration</th>
        </tr>
        <tr>
            <td>session_2025-11-09T20_50_33_875Z</td>
            <td>3 (001, 007, 008)</td>
            <td class="success">✓ Success</td>
            <td>2m 15s</td>
        </tr>
        <tr>
            <td>session_2025-11-10T01_30_43_049Z</td>
            <td>9 (001, 007, 008, ...)</td>
            <td class="success">✓ Success</td>
            <td>6m 05s</td>
        </tr>
    </table>
</body>
</html>
```

**Cost Calculation**:
```bash
# GPU pricing: $0.526/hour for g4dn.xlarge
calculate_cost() {
    local runtime_seconds=$1
    local hourly_rate=0.526

    # Convert to hours
    local runtime_hours=$(echo "scale=4; $runtime_seconds / 3600" | bc)

    # Calculate cost
    local cost=$(echo "scale=3; $runtime_hours * $hourly_rate" | bc)

    echo "$cost"
}
```

### 4. Admin Panel UI (batch-admin.html)

**Access**: `https://edge-box-ip/batch-admin.html`

**Authentication**: Optional (can add Cognito auth later)

**Features**:
1. **Dashboard**
   - Current status (GPU running/stopped)
   - Pending jobs count
   - Last scan time
   - Next scheduled run

2. **Pending Jobs List**
   - Table of sessions with missing chunks
   - Audio size, age, chunk numbers
   - Refresh button

3. **Manual Trigger**
   - "Run Batch Now" button
   - Progress indicator
   - Real-time log streaming

4. **Reports Viewer**
   - List of recent reports
   - Click to view details
   - Cost summary
   - Success rate charts

**HTML Structure**:
```html
<!DOCTYPE html>
<html>
<head>
    <title>Batch Transcription Admin</title>
    <link rel="stylesheet" href="batch-admin-styles.css">
</head>
<body>
    <div class="container">
        <h1>🎬 Batch Transcription Admin</h1>

        <!-- Status Dashboard -->
        <div class="dashboard">
            <div class="stat-card">
                <h3>GPU Status</h3>
                <div id="gpu-status">Loading...</div>
            </div>
            <div class="stat-card">
                <h3>Pending Jobs</h3>
                <div id="pending-count">Loading...</div>
            </div>
            <div class="stat-card">
                <h3>Last Scan</h3>
                <div id="last-scan">Loading...</div>
            </div>
            <div class="stat-card">
                <h3>Next Run</h3>
                <div id="next-run">Loading...</div>
            </div>
        </div>

        <!-- Actions -->
        <div class="actions">
            <button onclick="refreshData()" class="btn btn-secondary">
                🔄 Refresh
            </button>
            <button onclick="scanNow()" class="btn btn-primary">
                🔍 Scan Now
            </button>
            <button onclick="runBatchNow()" class="btn btn-success">
                ▶️ Run Batch Now
            </button>
        </div>

        <!-- Pending Jobs Table -->
        <div class="section">
            <h2>📝 Pending Transcriptions</h2>
            <div id="pending-jobs-table">
                <table>
                    <thead>
                        <tr>
                            <th>Session ID</th>
                            <th>User ID</th>
                            <th>Missing Chunks</th>
                            <th>Audio Size</th>
                            <th>Age</th>
                        </tr>
                    </thead>
                    <tbody id="jobs-tbody">
                        <!-- Populated by JavaScript -->
                    </tbody>
                </table>
            </div>
        </div>

        <!-- Recent Reports -->
        <div class="section">
            <h2>📈 Recent Reports</h2>
            <div id="reports-list">
                <!-- Populated by JavaScript -->
            </div>
        </div>
    </div>

    <script src="batch-admin.js"></script>
</body>
</html>
```

**JavaScript Logic**:
```javascript
// batch-admin.js

const API_BASE = '/api/batch';

// Load dashboard data
async function loadDashboard() {
    const status = await fetch(`${API_BASE}/status`).then(r => r.json());

    document.getElementById('gpu-status').textContent =
        status.gpuRunning ? '🟢 Running' : '🔴 Stopped';

    document.getElementById('pending-count').textContent =
        `${status.pendingChunks} chunks (${status.pendingSessions} sessions)`;

    document.getElementById('last-scan').textContent =
        formatDate(status.lastScan);

    document.getElementById('next-run').textContent =
        formatDate(status.nextRun);
}

// Load pending jobs
async function loadPendingJobs() {
    const jobs = await fetch(`${API_BASE}/pending`).then(r => r.json());

    const tbody = document.getElementById('jobs-tbody');
    tbody.innerHTML = '';

    jobs.sessions.forEach(session => {
        const row = document.createElement('tr');
        row.innerHTML = `
            <td>${session.sessionId}</td>
            <td>${session.userId.substring(0, 8)}...</td>
            <td>${session.missingChunks.join(', ')}</td>
            <td>${formatSize(session.totalAudioSize)}</td>
            <td>${session.ageHours.toFixed(1)}h ago</td>
        `;
        tbody.appendChild(row);
    });
}

// Manual trigger
async function runBatchNow() {
    if (!confirm('Start batch transcription now? This will start the GPU.')) {
        return;
    }

    const btn = event.target;
    btn.disabled = true;
    btn.textContent = '⏳ Running...';

    try {
        const result = await fetch(`${API_BASE}/trigger`, {
            method: 'POST'
        }).then(r => r.json());

        alert(`Batch completed!\n${result.chunksTranscribed} chunks transcribed\nCost: $${result.cost}`);

        loadDashboard();
        loadPendingJobs();
    } catch (error) {
        alert('Error running batch: ' + error.message);
    } finally {
        btn.disabled = false;
        btn.textContent = '▶️ Run Batch Now';
    }
}

// Load reports
async function loadReports() {
    const reports = await fetch(`${API_BASE}/reports`).then(r => r.json());

    const container = document.getElementById('reports-list');
    container.innerHTML = '';

    reports.slice(0, 10).forEach(report => {
        const card = document.createElement('div');
        card.className = 'report-card';
        card.innerHTML = `
            <div class="report-header">
                <span>${formatDate(report.timestamp)}</span>
                <span class="${report.status}">${report.status.toUpperCase()}</span>
            </div>
            <div class="report-body">
                <div>Chunks: ${report.transcription.chunksTranscribed}</div>
                <div>Duration: ${report.execution.durationHuman}</div>
                <div>Cost: $${report.gpu.costUSD.toFixed(3)}</div>
            </div>
            <a href="/batch-reports/${report.reportId}.html" target="_blank">View Details</a>
        `;
        container.appendChild(card);
    });
}

// Initialize
document.addEventListener('DOMContentLoaded', () => {
    loadDashboard();
    loadPendingJobs();
    loadReports();

    // Auto-refresh every 30 seconds
    setInterval(() => {
        loadDashboard();
    }, 30000);
});
```

### 5. Admin API (batch-admin.js Lambda)

**Endpoints**:

1. **GET `/api/batch/status`** - Dashboard status
```json
{
  "gpuRunning": false,
  "gpuInstanceId": "i-03a292875d9b12688",
  "pendingChunks": 12,
  "pendingSessions": 3,
  "lastScan": "2025-11-10T02:00:00Z",
  "nextRun": "2025-11-10T04:00:00Z",
  "schedulerActive": true
}
```

2. **GET `/api/batch/pending`** - Get pending-jobs.json
```json
{
  "timestamp": "2025-11-10T02:00:00Z",
  "totalMissingChunks": 12,
  "sessions": [...]
}
```

3. **POST `/api/batch/trigger`** - Manual batch trigger
```json
{
  "triggered": true,
  "jobId": "batch-manual-2025-11-10-021530",
  "estimatedDuration": "8 minutes"
}
```

4. **GET `/api/batch/reports`** - List reports
```json
[
  {
    "reportId": "batch-2025-11-10-0200",
    "timestamp": "2025-11-10T02:00:00Z",
    "status": "success",
    "chunksTranscribed": 12,
    "cost": 0.067
  },
  ...
]
```

**Implementation**:
```javascript
// cognito-stack/api/batch-admin.js

const AWS = require('aws-sdk');
const { exec } = require('child_process');
const util = require('util');
const execPromise = util.promisify(exec);

/**
 * GET /api/batch/status
 */
module.exports.getStatus = async (event) => {
    try {
        // Get GPU status
        const ec2 = new AWS.EC2();
        const gpuStatus = await ec2.describeInstances({
            InstanceIds: [process.env.GPU_INSTANCE_ID]
        }).promise();

        const gpuState = gpuStatus.Reservations[0].Instances[0].State.Name;

        // Get pending jobs
        const s3 = new AWS.S3();
        let pendingJobs = { totalMissingChunks: 0, sessionsWithMissingChunks: 0 };

        try {
            const jobsFile = await s3.getObject({
                Bucket: process.env.S3_BUCKET,
                Key: 'batch-data/pending-jobs.json'
            }).promise();

            pendingJobs = JSON.parse(jobsFile.Body.toString());
        } catch (err) {
            // File doesn't exist yet
        }

        return {
            statusCode: 200,
            body: JSON.stringify({
                gpuRunning: gpuState === 'running',
                gpuInstanceId: process.env.GPU_INSTANCE_ID,
                pendingChunks: pendingJobs.totalMissingChunks || 0,
                pendingSessions: pendingJobs.sessionsWithMissingChunks || 0,
                lastScan: pendingJobs.timestamp || null,
                nextRun: calculateNextRun(),
                schedulerActive: true
            })
        };
    } catch (error) {
        console.error('Error getting status:', error);
        return {
            statusCode: 500,
            body: JSON.stringify({ error: error.message })
        };
    }
};

/**
 * POST /api/batch/trigger
 */
module.exports.trigger = async (event) => {
    try {
        // Trigger batch transcription script
        // Note: This would typically use Step Functions or ECS for long-running tasks
        // For now, we'll just kick off the script asynchronously

        const scriptPath = '/home/ubuntu/event-b/.../scripts/530-enhanced-batch-transcribe.sh';

        // Execute in background (don't wait)
        exec(`${scriptPath} > /tmp/batch-manual-$(date +%s).log 2>&1 &`);

        return {
            statusCode: 200,
            body: JSON.stringify({
                triggered: true,
                message: 'Batch transcription started',
                jobId: `batch-manual-${Date.now()}`
            })
        };
    } catch (error) {
        console.error('Error triggering batch:', error);
        return {
            statusCode: 500,
            body: JSON.stringify({ error: error.message })
        };
    }
};
```

## Scheduler Configuration

### Systemd Timer (2-Hour Intervals)

**File**: `/etc/systemd/system/batch-transcribe.timer`

```ini
[Unit]
Description=Batch Transcription Every 2 Hours
Requires=batch-transcribe.service

[Timer]
# First run 10 minutes after boot
OnBootSec=10min

# Then every 2 hours
OnUnitActiveSec=2h

# Allow some flexibility (±5 min) to spread load
AccuracySec=5min

# Run even if system was powered off during scheduled time
Persistent=true

[Install]
WantedBy=timers.target
```

**File**: `/etc/systemd/system/batch-transcribe.service`

```ini
[Unit]
Description=Batch Transcription Scan and Process
After=network.target

[Service]
Type=oneshot
User=ubuntu
WorkingDirectory=/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4

# Step 1: Scan for missing chunks
ExecStartPre=/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/scripts/525-scan-missing-chunks.sh

# Step 2: Process if jobs exist
ExecStart=/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/scripts/530-enhanced-batch-transcribe.sh

# Logs
StandardOutput=journal
StandardError=journal
SyslogIdentifier=batch-transcribe

# Timeout: 2 hours max (in case of large batch)
TimeoutStartSec=7200

[Install]
WantedBy=multi-user.target
```

**Installation**:
```bash
# Copy files
sudo cp batch-transcribe.service /etc/systemd/system/
sudo cp batch-transcribe.timer /etc/systemd/system/

# Reload systemd
sudo systemctl daemon-reload

# Enable and start timer
sudo systemctl enable batch-transcribe.timer
sudo systemctl start batch-transcribe.timer

# Check status
systemctl status batch-transcribe.timer
```

## Cost Analysis

### Current 5-Minute Approach
- **Frequency**: 288 scans/day (every 5 minutes)
- **GPU starts**: If ANY work exists, GPU starts 288 times/day
- **Avg runtime**: 2 minutes per start (startup + transcribe 1-2 chunks + shutdown)
- **Total GPU time**: 576 minutes/day = 9.6 hours/day
- **Cost**: 9.6 hours × $0.526/hour = **$5.05/day** = **$152/month**

### New 2-Hour Approach
- **Frequency**: 12 scans/day (every 2 hours)
- **GPU starts**: Only when work accumulates (e.g., 3-4 times/day)
- **Avg runtime**: 8-10 minutes per start (batch process all chunks)
- **Total GPU time**: 4 starts × 10 min = 40 minutes/day = 0.67 hours/day
- **Cost**: 0.67 hours × $0.526/hour = **$0.35/day** = **$10.50/month**

### Savings
- **Daily**: $5.05 - $0.35 = $4.70/day saved
- **Monthly**: $152 - $10.50 = **$141.50/month saved** (93% reduction)
- **Annual**: **$1,698/year saved**

## Implementation Timeline

### Phase 1: Core Scripts (2-3 hours)
- ✓ 525-scan-missing-chunks.sh
- ✓ 530-enhanced-batch-transcribe.sh
- ✓ 535-generate-batch-report.sh
- ✓ Update 510 to use 2-hour timer

### Phase 2: Admin Panel (3-4 hours)
- ✓ batch-admin.html
- ✓ batch-admin.css
- ✓ batch-admin.js (frontend)
- ✓ batch-admin.js (Lambda backend)
- ✓ Update serverless.yml

### Phase 3: Testing (1-2 hours)
- ✓ Test scanner with real data
- ✓ Test GPU start/stop
- ✓ Test manual trigger
- ✓ Verify cost tracking

### Phase 4: Deployment (1 hour)
- ✓ Deploy scripts
- ✓ Deploy Lambda functions
- ✓ Configure systemd timer
- ✓ Deploy admin panel UI

**Total Time**: 7-10 hours

## Testing Plan

### Unit Tests

**Test 1: Scanner Accuracy**
```bash
# Create test scenario
aws s3 cp test-audio.webm s3://bucket/users/test/audio/sessions/test-session/chunk-001.webm
# (Don't create transcription)

# Run scanner
./scripts/525-scan-missing-chunks.sh

# Verify
cat pending-jobs.json | jq '.totalMissingChunks'
# Should return: 1
```

**Test 2: GPU Lifecycle**
```bash
# Ensure GPU is stopped
aws ec2 stop-instances --instance-ids $GPU_INSTANCE_ID
aws ec2 wait instance-stopped --instance-ids $GPU_INSTANCE_ID

# Create pending jobs
./scripts/525-scan-missing-chunks.sh

# Run batch (should start GPU)
./scripts/530-enhanced-batch-transcribe.sh

# Verify GPU stopped after completion
aws ec2 describe-instances --instance-ids $GPU_INSTANCE_ID \
    --query 'Reservations[0].Instances[0].State.Name' --output text
# Should return: stopped
```

**Test 3: Report Generation**
```bash
# Run batch with known data
./scripts/530-enhanced-batch-transcribe.sh

# Check report exists
ls -lh batch-reports/batch-$(date +%Y-%m-%d)*.json

# Validate JSON
jq '.status' batch-reports/batch-*.json
# Should return: "success"

# Check HTML report
firefox batch-reports/batch-*.html
```

### Integration Tests

**Test 4: Full Workflow**
```bash
# 1. Create missing chunks scenario
# 2. Run scheduler (simulated)
# 3. Verify all chunks transcribed
# 4. Verify report generated
# 5. Verify GPU stopped
# 6. Check admin panel displays correctly
```

**Test 5: Error Handling**
```bash
# Test GPU start failure
# Test SSH timeout
# Test WhisperLive crash
# Verify GPU still shuts down
```

## Monitoring & Alerts

### Key Metrics to Track

1. **Batch Success Rate**
   - Target: >95%
   - Alert if <90% for 3 consecutive runs

2. **GPU Runtime**
   - Target: <15 minutes per batch
   - Alert if >30 minutes

3. **Cost per Day**
   - Target: <$0.50/day
   - Alert if >$1.00/day

4. **Pending Chunks Age**
   - Target: All chunks <6 hours old
   - Alert if chunks >24 hours old

### CloudWatch Dashboards

**Widget 1: Batch Runs**
- Line graph of batches per day
- Success vs failure rate

**Widget 2: GPU Cost**
- Daily GPU cost
- Running 7-day average

**Widget 3: Pending Queue**
- Current pending chunks
- Age of oldest pending chunk

## Security Considerations

### Admin Panel Access

**Option 1: IP Whitelist** (Simple)
```nginx
# In Caddy config
https://edge-box-ip {
    @admin path /batch-admin.html
    @admin remote_ip 203.0.113.0/24  # Your IP range

    handle @admin {
        file_server
    }

    respond @admin 403
}
```

**Option 2: Cognito Auth** (Recommended)
- Require login to access panel
- Only admin users can trigger batches
- Audit log of who triggered manual batches

### AWS Permissions

**Lambda IAM Role**:
```yaml
- Effect: Allow
  Action:
    - ec2:DescribeInstances
    - ec2:StartInstances
    - ec2:StopInstances
  Resource: !Sub "arn:aws:ec2:${AWS::Region}:${AWS::AccountId}:instance/${GPUInstanceId}"

- Effect: Allow
  Action:
    - s3:GetObject
    - s3:PutObject
  Resource:
    - !Sub "${BucketArn}/batch-data/*"
    - !Sub "${BucketArn}/batch-reports/*"
```

### Cost Protection

**EC2 Instance Protection**:
```bash
# Set instance metadata to prevent accidental termination
aws ec2 modify-instance-attribute \
    --instance-id $GPU_INSTANCE_ID \
    --disable-api-termination

# Set tag for cost tracking
aws ec2 create-tags \
    --resources $GPU_INSTANCE_ID \
    --tags Key=ManagedBy,Value=BatchTranscription
```

**Cost Alarm**:
```yaml
Resources:
  GPUCostAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: batch-transcription-high-cost
      MetricName: EstimatedCharges
      Namespace: AWS/Billing
      Statistic: Maximum
      Period: 86400  # 1 day
      EvaluationPeriods: 1
      Threshold: 5.0  # Alert if >$5/day
      ComparisonOperator: GreaterThanThreshold
      AlarmActions:
        - !Ref SNSTopicArn
```

## Future Enhancements

### Priority Queue
- Prioritize sessions by age (old sessions first)
- Prioritize by user tier (paid users first)
- Manual priority override from admin panel

### Notifications
- Email when batch completes
- Slack integration for failures
- SMS for high costs

### Analytics
- Cost trends over time
- Success rate by session
- Average transcription time per chunk

### Automatic Cleanup
- Delete old reports (>30 days)
- Archive completed pending-jobs.json
- Compress old logs

## Appendix

### File Structure
```
scripts/
├── 525-scan-missing-chunks.sh          # S3 scanner
├── 530-enhanced-batch-transcribe.sh    # Smart batch worker
├── 535-generate-batch-report.sh        # Report generator
└── batch-data/
    ├── pending-jobs.json               # Current scan results
    └── batch-reports/
        ├── batch-2025-11-10-0200.json  # JSON reports
        └── batch-2025-11-10-0200.html  # HTML reports

ui-source/
├── batch-admin.html                    # Admin panel
├── batch-admin.css                     # Styles
└── batch-admin.js                      # Frontend logic

cognito-stack/api/
└── batch-admin.js                      # Lambda backend
```

### Environment Variables
```bash
# .env additions
GPU_INSTANCE_ID=i-03a292875d9b12688
GPU_HOURLY_COST=0.526
BATCH_REPORT_RETENTION_DAYS=30
ADMIN_NOTIFICATION_EMAIL=admin@example.com
```

### CLI Commands
```bash
# Manual scan
./scripts/525-scan-missing-chunks.sh

# View pending jobs
cat batch-data/pending-jobs.json | jq

# Manual batch run
./scripts/530-enhanced-batch-transcribe.sh

# View latest report
ls -t batch-reports/*.json | head -1 | xargs cat | jq

# Check scheduler
systemctl status batch-transcribe.timer
sudo journalctl -u batch-transcribe -f

# View GPU status
aws ec2 describe-instances --instance-ids $GPU_INSTANCE_ID \
    --query 'Reservations[0].Instances[0].State.Name' --output text
```

---

**Version**: 1.0.0
**Last Updated**: 2025-11-10
**Author**: Batch Transcription System Design Team
