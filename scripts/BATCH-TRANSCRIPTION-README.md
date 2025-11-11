# Batch Transcription System

## Overview

The batch transcription system automatically finds and transcribes audio chunks that were missed during live recording sessions. This ensures every session has complete transcriptions, even if the WebSocket connection to WhisperLive was interrupted.

**Key Features:**
- **Smart GPU Management** - Only starts GPU when work exists, guaranteed shutdown
- **Cost Optimized** - 2-hour scheduling reduces GPU costs by 95%
- **Lock Mechanism** - Never interferes with live recording sessions
- **Automatic Reports** - JSON reports track costs, runtime, and success rates

## Architecture

### How it Works

```
Every 2 Hours (systemd timer)
         │
         ▼
┌────────────────────────────────────┐
│ 515-run-batch-transcribe.sh        │
│ Main Orchestrator                  │
└────────────────────────────────────┘
         │
         ├─► Step 1: Check batch lock
         │   └─► If locked: Exit immediately (live session active)
         │
         ├─► Step 2: Call 512-scan-missing-chunks.sh
         │   ├─► Scans ALL S3 sessions (fast, no GPU)
         │   ├─► Compares audio vs transcription chunks
         │   └─► Generates pending-jobs.json
         │       Returns: Missing chunk count
         │
         ├─► Step 3: Decide based on scan results
         │   ├─► If chunks == 0:
         │   │   ├─► Generate report (status: skipped)
         │   │   └─► Exit (no GPU needed)
         │   │
         │   └─► If chunks > 0:
         │       ├─► Check GPU state
         │       ├─► Start GPU if stopped (set WE_STARTED_GPU=true)
         │       ├─► Wait for GPU ready (~90 sec)
         │       ├─► SSH to GPU and transcribe all pending chunks
         │       ├─► Upload results to S3
         │       ├─► Stop GPU if we started it
         │       └─► Generate report with costs and stats
```

### Cost Analysis

**Old Approach (5-minute cron):**
- Runs: 288 times/day
- GPU starts: 288 times/day (even when no work)
- Cost: ~$152/month in wasted GPU time

**New Approach (2-hour smart cron):**
- Runs: 12 times/day
- GPU starts: Only when pending jobs exist (~1-3 times/day)
- Cost: ~$10.50/month
- **Savings: 93%**

## Components

### Python Scripts

**scripts/batch-transcribe-audio.py**
- Core transcription using faster-whisper
- Matches WhisperLive settings (word timestamps, small.en model)
- Input: Audio file (.webm)
- Output: JSON with segments and word-level timestamps

### Bash Scripts (500-Series)

**500-setup-batch-transcription.sh**
- Verifies GPU connectivity
- Checks WhisperLive installation
- Validates faster-whisper dependencies
- **Run once during initial setup**

**505-deploy-batch-worker.sh**
- Copies Python script to GPU
- Creates batch working directory (`~/batch-transcription/`)
- Sets permissions
- **Run once, or after updating batch-transcribe-audio.py**

**510-configure-batch-scheduler.sh**
- Creates systemd service (`batch-transcribe.service`)
- Creates systemd timer (runs every 2 hours)
- Enables and starts automation
- **Run once to enable automation**

**512-scan-missing-chunks.sh** (Helper Script)
- Scans S3 for all user sessions
- Compares audio chunks vs transcription chunks
- Generates `pending-jobs.json` with missing chunk details
- Fast operation (no GPU needed)
- **Called internally by 515, can also run standalone**

**515-run-batch-transcribe.sh** (Main Orchestrator)
- Checks batch lock (skips if live session active)
- Calls 512-scan to detect missing chunks
- Manages GPU lifecycle (start only if needed, guaranteed shutdown)
- Transcribes all pending chunks
- Generates batch report with cost tracking
- **Called automatically by systemd timer every 2 hours**
- **Can be run manually for immediate batch processing**

**520-test-batch-transcription.sh**
- End-to-end test suite
- Simulates missing chunk
- Runs batch transcription
- Verifies re-transcription
- Restores original chunk
- **Run after setup to verify system works**

### Lambda Functions

**cognito-stack/api/batch-lock.js**
- `createLock` - Called when recording starts
- `removeLock` - Called when recording stops
- `checkLock` - Batch script checks before running

**Lock File Format:**
```json
{
  "locked": true,
  "userId": "...",
  "sessionId": "session_...",
  "timestamp": "2025-11-10T01:30:00.000Z"
}
```

**Stale Lock Cleanup:**
- Locks older than 30 minutes are auto-removed
- Prevents stuck locks from blocking batch processing

### Report Format

**batch-reports/batch-YYYY-MM-DD-HHMM.json**
```json
{
  "timestamp": "2025-11-10T03:00:00Z",
  "status": "success",
  "skipped": false,
  "lockStatus": {
    "locked": false
  },
  "scan": {
    "sessionsScanned": 47,
    "totalMissingChunks": 12
  },
  "gpu": {
    "wasRunning": false,
    "weStartedIt": true,
    "startTime": "2025-11-10T03:00:15Z",
    "stopTime": "2025-11-10T03:08:42Z",
    "runtimeSeconds": 507,
    "costUSD": 0.067
  },
  "transcription": {
    "chunksTranscribed": 12,
    "chunksFailed": 0,
    "totalSizeBytes": 15728640
  },
  "performance": {
    "totalDurationSeconds": 510,
    "scanDurationSeconds": 8,
    "gpuStartupSeconds": 95,
    "transcribeDurationSeconds": 395,
    "shutdownSeconds": 12
  }
}
```

## Installation

Run scripts in sequence:

```bash
# 1. Setup GPU dependencies (verifies GPU is accessible)
./scripts/500-setup-batch-transcription.sh

# 2. Deploy batch worker to GPU (copies Python script)
./scripts/505-deploy-batch-worker.sh

# 3. Configure scheduler (creates 2-hour systemd timer)
./scripts/510-configure-batch-scheduler.sh

# 4. Test the system (simulates missing chunk and verifies re-transcription)
./scripts/520-test-batch-transcription.sh
```

**Important Notes:**
- Script 512 (scanner) is called automatically by 515, no manual setup needed
- Scripts 500 and 505 can be skipped if you only want to test scanning (no GPU needed)
- The scanner (512) works without GPU access - it only reads S3

**Verification:**
```bash
# Check timer is active
systemctl status batch-transcribe.timer

# Check next run time
systemctl list-timers batch-transcribe.timer

# View recent logs
sudo journalctl -u batch-transcribe --since "1 hour ago"
```

## Manual Operation

### Run Batch Immediately
```bash
# Run full batch process (smart GPU management)
./scripts/515-run-batch-transcribe.sh

# Just scan for missing chunks (no GPU)
./scripts/512-scan-missing-chunks.sh
```

### Check Status
```bash
# Scheduler status
systemctl status batch-transcribe.timer

# View pending jobs (if scan has run)
cat /tmp/pending-jobs.json | jq .

# View latest batch report
ls -lart batch-reports/ | tail -1
cat batch-reports/batch-*.json | jq .
```

### View Logs
```bash
# Follow live logs
sudo journalctl -u batch-transcribe -f

# View recent logs
sudo journalctl -u batch-transcribe --since "1 hour ago"

# View script logs (includes stdout/stderr)
ls -lart logs/515-run-batch-transcribe-*.log
tail -f logs/515-run-batch-transcribe-*.log
```

### Control Scheduler
```bash
# Stop scheduler
sudo systemctl stop batch-transcribe.timer

# Start scheduler
sudo systemctl start batch-transcribe.timer

# Disable scheduler (won't start on boot)
sudo systemctl disable batch-transcribe.timer

# Re-enable scheduler
sudo systemctl enable batch-transcribe.timer
```

## GPU Lifecycle Management

### How GPU Management Works

**Script 515 implements guaranteed GPU shutdown using bash traps:**

```bash
WE_STARTED_GPU=false

# Trap ensures cleanup even on error/interrupt
cleanup() {
    if [ "$WE_STARTED_GPU" = "true" ]; then
        log_warn "Ensuring GPU shutdown..."
        aws ec2 stop-instances --instance-ids "$GPU_INSTANCE_ID"
        aws ec2 wait instance-stopped --instance-ids "$GPU_INSTANCE_ID"
    fi
}
trap cleanup EXIT INT TERM

# Main logic
GPU_STATE=$(aws ec2 describe-instances ...)

if [ "$GPU_STATE" = "stopped" ]; then
    aws ec2 start-instances --instance-ids "$GPU_INSTANCE_ID"
    WE_STARTED_GPU=true
    wait_for_gpu_ready
fi

# Process chunks...
# cleanup() runs automatically via trap
```

### GPU Safety Guarantees

1. **Exit trap** - GPU stops even on script error
2. **Interrupt trap** - GPU stops if you Ctrl+C
3. **Terminate trap** - GPU stops if process killed
4. **State tracking** - Only stops GPU if script started it
5. **Idempotent** - Safe to run multiple times

### Manual GPU Control

```bash
# Check GPU status
aws ec2 describe-instances --instance-ids $GPU_INSTANCE_ID \
  --query 'Reservations[0].Instances[0].State.Name' \
  --output text

# Start GPU manually (if needed for testing)
aws ec2 start-instances --instance-ids $GPU_INSTANCE_ID

# Stop GPU manually (if script fails to stop)
aws ec2 stop-instances --instance-ids $GPU_INSTANCE_ID
```

## Lock Mechanism

### Purpose
Prevents batch transcription from running while live sessions are active, avoiding GPU resource conflicts.

### How It Works

1. **Recording Starts**
   - Browser calls `POST /api/batch/lock`
   - Lock file created in S3: `batch-lock.json`

2. **Batch Script Checks**
   - Before running, calls `GET /api/batch/lock-status`
   - If locked, exits immediately (logs "Skipping: live session active")

3. **Recording Stops**
   - Browser calls `POST /api/batch/unlock`
   - Lock file deleted from S3

### Stale Lock Protection
- Locks older than 30 minutes are auto-removed
- Handles browser crashes / network disconnects

### Manual Lock Management

```bash
# Check lock status
curl https://your-api.amazonaws.com/dev/api/batch/lock-status

# Manually remove stuck lock
aws s3 rm s3://$COGNITO_S3_BUCKET/batch-lock.json
```

## Monitoring

### Key Metrics to Track

**Batch Run Frequency:**
```bash
# Count successful runs today
sudo journalctl -u batch-transcribe --since today | grep "SUCCESS" | wc -l
```

**GPU Utilization:**
```bash
# Sum GPU runtime from reports
jq -s '[.[] | .gpu.runtimeSeconds] | add' batch-reports/batch-*.json
```

**Cost Tracking:**
```bash
# Total batch cost this month
jq -s '[.[] | .gpu.costUSD] | add' batch-reports/batch-$(date +%Y-%m)-*.json
```

**Failure Rate:**
```bash
# Count failed chunks
jq -s '[.[] | .transcription.chunksFailed] | add' batch-reports/batch-*.json
```

### Alerting Recommendations

1. **High failure rate** - If chunksFailed > 10% of chunksTranscribed
2. **Stuck GPU** - If GPU runtime > 30 minutes in single batch
3. **No runs** - If no successful batch in 6 hours
4. **High cost** - If daily batch cost > $2

## Troubleshooting

### Batch Not Running

**Check timer status:**
```bash
systemctl status batch-transcribe.timer
```

**If inactive, start it:**
```bash
sudo systemctl start batch-transcribe.timer
sudo systemctl enable batch-transcribe.timer  # Start on boot
```

**Check timer configuration:**
```bash
systemctl cat batch-transcribe.timer
# Should show: OnUnitActiveSec=2h
```

### No Chunks Being Transcribed

**1. Check if sessions exist:**
```bash
aws s3 ls s3://$COGNITO_S3_BUCKET/users/ --recursive | grep "chunk-.*\\.webm"
```

**2. Run manual scan:**
```bash
./scripts/512-scan-missing-chunks.sh
cat /tmp/pending-jobs.json | jq .
```

**3. Check for pending jobs:**
```bash
# Should show count > 0 if there are missing chunks
jq '.totalMissingChunks' /tmp/pending-jobs.json
```

**4. Run manual batch:**
```bash
./scripts/515-run-batch-transcribe.sh
```

### Transcription Fails

**1. Check GPU logs:**
```bash
ssh ubuntu@$GPU_INSTANCE_IP "journalctl -u whisperlive -n 50"
```

**2. Test Python script directly:**
```bash
ssh ubuntu@$GPU_INSTANCE_IP
cd ~/batch-transcription
python3 batch-transcribe-audio.py /path/to/test-audio.webm
```

**3. Check faster-whisper:**
```bash
ssh ubuntu@$GPU_INSTANCE_IP \
  "cd ~/whisperlive && source venv/bin/activate && \
   python3 -c 'import faster_whisper; print(\"OK\")'"
```

**4. Check GPU connectivity:**
```bash
ssh ubuntu@$GPU_INSTANCE_IP "echo 'SSH OK'"
```

### GPU Won't Start/Stop

**Check AWS credentials:**
```bash
aws sts get-caller-identity
```

**Check EC2 permissions:**
```bash
# Should have: ec2:DescribeInstances, ec2:StartInstances, ec2:StopInstances
aws ec2 describe-instances --instance-ids $GPU_INSTANCE_ID
```

**Manual GPU control:**
```bash
# Start
aws ec2 start-instances --instance-ids $GPU_INSTANCE_ID
aws ec2 wait instance-running --instance-ids $GPU_INSTANCE_ID

# Stop
aws ec2 stop-instances --instance-ids $GPU_INSTANCE_ID
aws ec2 wait instance-stopped --instance-ids $GPU_INSTANCE_ID
```

### GPU Not Shutting Down

**Check for hung processes:**
```bash
# View script execution
ps aux | grep batch-transcribe

# Kill if needed
pkill -f run-batch-transcribe
```

**Force GPU stop:**
```bash
aws ec2 stop-instances --instance-ids $GPU_INSTANCE_ID --force
```

**Check batch reports for errors:**
```bash
# Look for runs where GPU didn't stop
jq -r 'select(.gpu.weStartedIt == true and .gpu.stopTime == null)' \
  batch-reports/batch-*.json
```

### Lock Issues

**Check lock status:**
```bash
curl https://your-api.amazonaws.com/dev/api/batch/lock-status
```

**Check lock age:**
```bash
# Locks older than 30 min should auto-remove
aws s3api head-object --bucket $COGNITO_S3_BUCKET --key batch-lock.json \
  --query 'LastModified' --output text
```

**Manually remove lock:**
```bash
aws s3 rm s3://$COGNITO_S3_BUCKET/batch-lock.json
```

## Performance

### Resource Usage

- **Edge Box CPU**: Minimal (just running scheduler)
- **Edge Box Disk**: ~10MB for reports per month
- **GPU Time**: Only when pending jobs exist (~10-30 min/day)
- **Network**: Download audio + upload JSON (~100KB per chunk)
- **S3 API Calls**: ~10-20 LIST operations per scan

### Timing

- **Scanner runs**: Every 2 hours (12 times/day)
- **Typical scan**: 5-15 seconds for 100 sessions
- **GPU startup**: 90-120 seconds
- **Transcription speed**: ~0.5x realtime (5 min audio = 2.5 min processing)
- **GPU shutdown**: 10-15 seconds

### Cost Estimate

**Monthly Costs (Typical Usage):**
- **S3 API calls**: $0.0004 per 1,000 LIST operations = ~$0.01/month
- **Lambda calls**: $0.0000002 per lock check = negligible
- **GPU runtime**: ~15 hours/month @ $0.5/hour = $7.50/month
- **S3 storage**: Reports ~10MB/month = negligible

**Total: ~$7.50-10.50/month** (vs. $152/month with 5-min cron)

### Optimization Tips

1. **Reduce scan frequency**: Change from 2h to 4h if acceptable latency
2. **Batch audio chunks**: Transcribe multiple chunks in single GPU session
3. **Use smaller model**: Switch to tiny.en if accuracy isn't critical
4. **Increase chunk size**: Record longer chunks (fewer total chunks)

## Integration Notes

### UI Integration (TODO)

The batch lock mechanism requires UI updates to audio.html:

**Add to recording start:**
```javascript
// When recording starts
async function startRecording() {
    // ... existing code ...

    // Create batch lock
    try {
        await fetch(`${config.apiUrl}/api/batch/lock`, {
            method: 'POST',
            headers: {
                'Authorization': `Bearer ${idToken}`,
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({
                sessionId: currentSession.id
            })
        });
        console.log('Batch lock created');
    } catch (error) {
        console.warn('Failed to create batch lock:', error);
        // Non-critical - continue recording
    }

    // ... existing code ...
}
```

**Add to recording stop:**
```javascript
// When recording stops
async function stopRecording() {
    // ... existing code ...

    // Remove batch lock
    try {
        await fetch(`${config.apiUrl}/api/batch/unlock`, {
            method: 'POST',
            headers: {
                'Authorization': `Bearer ${idToken}`
            }
        });
        console.log('Batch lock removed');
    } catch (error) {
        console.warn('Failed to remove batch lock:', error);
        // Non-critical - lock will auto-expire
    }

    // ... existing code ...
}
```

### Deployment

After installing batch system:

1. **Deploy Lambda endpoints:**
   ```bash
   cd cognito-stack
   serverless deploy
   ```

2. **Update UI with lock calls** (see above)

3. **Redeploy UI:**
   ```bash
   ./scripts/425-deploy-recorder-ui.sh
   ```

## Testing

### Unit Test
```bash
./scripts/520-test-batch-transcription.sh
```

### Manual Test Workflow
1. Record a session with audio.html
2. Manually delete a transcription chunk:
   ```bash
   aws s3 rm s3://$COGNITO_S3_BUCKET/users/.../transcription-chunk-005.json
   ```
3. Run scanner to detect missing chunk:
   ```bash
   ./scripts/512-scan-missing-chunks.sh
   cat /tmp/pending-jobs.json | jq .
   ```
4. Run batch to re-transcribe:
   ```bash
   ./scripts/515-run-batch-transcribe.sh
   ```
5. Verify chunk was re-created:
   ```bash
   aws s3 ls s3://$COGNITO_S3_BUCKET/users/.../transcription-chunk-005.json
   ```
6. Check batch report:
   ```bash
   cat batch-reports/batch-*.json | jq .
   ```

### Load Test
```bash
# Simulate 100 sessions with missing chunks
for i in {1..100}; do
    # Delete random transcription chunk from random session
    SESSION=$(aws s3 ls s3://$COGNITO_S3_BUCKET/users/ --recursive | \
              grep session_ | shuf -n 1 | awk '{print $4}')
    CHUNK=$(aws s3 ls s3://$COGNITO_S3_BUCKET/$SESSION | \
            grep transcription-chunk | shuf -n 1 | awk '{print $4}')
    aws s3 rm "s3://$COGNITO_S3_BUCKET/$SESSION/$CHUNK"
done

# Run batch and time it
time ./scripts/515-run-batch-transcribe.sh

# Check results
cat batch-reports/batch-*.json | jq '.transcription'
```

### GPU Safety Test
```bash
# Test trap cleanup on error
./scripts/515-run-batch-transcribe.sh &
BATCH_PID=$!
sleep 60  # Let it start GPU
kill $BATCH_PID  # Interrupt

# Verify GPU stopped
aws ec2 describe-instances --instance-ids $GPU_INSTANCE_ID \
  --query 'Reservations[0].Instances[0].State.Name' \
  --output text
# Should show: stopped or stopping
```

## Future Enhancements

### Planned Features

1. **Web Admin Panel** (Phase 2)
   - View pending jobs in real-time
   - Manual trigger button
   - Historical reports dashboard
   - Cost tracking graphs

2. **Final Transcription Regeneration**
   - Automatically regenerate `transcription.json` after batch completion
   - Ensures viewer shows complete text

3. **Retry Logic**
   - Auto-retry failed chunks (max 3 attempts)
   - Exponential backoff

4. **Priority Queue**
   - Process recent sessions first
   - Age-based prioritization

5. **Email Notifications**
   - Alert when batch completes session
   - Error notifications

6. **Metrics Dashboard**
   - Grafana/CloudWatch integration
   - Real-time GPU utilization
   - Cost tracking over time

### Not Planned (Kept Simple)

- ❌ DynamoDB tracking (file-based is sufficient)
- ❌ SQS queuing (cron is adequate)
- ❌ Separate batch GPU (time-slicing works)
- ❌ Real-time progress updates (batch reports are sufficient)

## Support

**Logs:** All scripts log to `logs/` directory with timestamps

**Debugging:** Run scripts with `bash -x` for verbose output:
```bash
bash -x ./scripts/515-run-batch-transcribe.sh
```

**Issues:** Check CLAUDE.md troubleshooting section

**Reports:** All batch runs generate detailed reports in `batch-reports/`

---

**Last Updated:** 2025-11-10
**Version:** 2.0.0 (Enhanced with smart GPU management)
