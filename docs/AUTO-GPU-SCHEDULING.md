# Automatic GPU Scheduling for Batch Transcription

## Overview

The system can automatically start the GPU instance, process batch transcriptions, and stop the GPU to save costs. This is handled by the Smart Batch Scheduler (script 535).

## How It Works

1. **Scheduler runs every hour** (configurable)
2. **Checks S3** for untranscribed audio chunks
3. **If threshold met** (default: 100 chunks):
   - Starts GPU instance automatically
   - Waits for GPU to be ready
   - Runs batch transcription
   - Stops GPU when complete
4. **Tracks costs** and reports savings

## Benefits

- **Cost Optimization**: Only runs GPU when cost-effective (batches ≥ 100 chunks)
- **Hands-Free**: Fully automated - no manual intervention needed
- **Safe**: Lock file prevents concurrent runs, max runtime limits prevent runaway costs
- **Cost Tracking**: Tracks GPU usage and estimated costs

## Setup Instructions

### Step 1: Configure Thresholds in .env

Add these settings to your `.env` file:

```bash
# Smart Scheduler Configuration
BATCH_THRESHOLD=100              # Minimum chunks to trigger GPU start (default: 100)
BATCH_MAX_RUNTIME_HOURS=2        # Safety cutoff - stop after 2 hours max
BATCH_SCHEDULER_CHECK_HOURS=1    # How often to check (1 = every hour)
```

**Threshold Guidelines:**
- **100 chunks** (default): Good balance of cost vs latency (~15-20 min of audio)
- **50 chunks**: More frequent processing, higher per-chunk cost
- **200 chunks**: Better cost efficiency, longer wait times

### Step 2: Set Up Systemd Timer (Recommended)

Create a systemd timer to run the scheduler every hour:

```bash
# Create timer configuration
sudo tee /etc/systemd/system/batch-transcribe-scheduler.timer << 'EOF'
[Unit]
Description=Smart Batch Transcription Scheduler Timer
Requires=batch-transcribe-scheduler.service

[Timer]
# Run every hour
OnCalendar=hourly
# Run immediately if missed (e.g., after system reboot)
Persistent=true
# Add random delay to avoid exact-hour spikes
RandomizedDelaySec=5min

[Install]
WantedBy=timers.target
EOF

# Create service configuration
sudo tee /etc/systemd/system/batch-transcribe-scheduler.service << 'EOF'
[Unit]
Description=Smart Batch Transcription Scheduler
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=ubuntu
WorkingDirectory=/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4
ExecStart=/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/scripts/535-smart-batch-scheduler.sh
StandardOutput=journal
StandardError=journal

# Resource limits
TimeoutStartSec=3h
CPUQuota=50%
MemoryMax=2G

[Install]
WantedBy=multi-user.target
EOF

# Enable and start the timer
sudo systemctl daemon-reload
sudo systemctl enable batch-transcribe-scheduler.timer
sudo systemctl start batch-transcribe-scheduler.timer

# Verify it's running
sudo systemctl status batch-transcribe-scheduler.timer
```

### Step 3: Verify Setup

```bash
# Check timer status
sudo systemctl list-timers batch-transcribe*

# Expected output:
# NEXT                        LEFT          LAST PASSED UNIT                                ACTIVATES
# 2025-11-15 17:00:00 EST     45min left    -    -      batch-transcribe-scheduler.timer    batch-transcribe-scheduler.service

# View logs
sudo journalctl -u batch-transcribe-scheduler.service -f
```

## Alternative: Cron Setup

If you prefer cron over systemd:

```bash
# Edit crontab
crontab -e

# Add this line (runs every hour at minute 0)
0 * * * * /home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/scripts/535-smart-batch-scheduler.sh >> /home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/logs/scheduler-cron.log 2>&1
```

## Manual Testing

Test the scheduler manually before enabling automation:

```bash
# Dry run - see what it would do
./scripts/535-smart-batch-scheduler.sh

# With custom threshold
BATCH_THRESHOLD=50 ./scripts/535-smart-batch-scheduler.sh

# Check logs
tail -f logs/535-smart-batch-scheduler-*.log
```

## Monitoring

### Check Scheduler Status
```bash
# Systemd timer
sudo systemctl status batch-transcribe-scheduler.timer

# View recent runs
sudo journalctl -u batch-transcribe-scheduler.service --since "24 hours ago"

# Check next scheduled run
systemctl list-timers batch-transcribe*
```

### Check Batch Processing Status
```bash
# View active batch jobs
ps aux | grep batch-transcribe

# Check lock file (indicates job running)
ls -lh /tmp/batch-transcribe.lock

# View recent batch reports
ls -lrt batch-reports/
cat batch-reports/batch-$(date +%Y-%m-%d)-*.json
```

## Cost Tracking

The scheduler automatically tracks costs:

```bash
# View cost report
cat logs/535-smart-batch-scheduler-*.log | grep -A10 "Cost Tracking"

# Expected output:
# Cost Tracking:
#   GPU Type:        g4dn.xlarge
#   Hourly Rate:     $0.526
#   Estimated Time:  0.5 hours
#   Estimated Cost:  $0.26
#   Chunks/Dollar:   ~380
```

## Safety Features

1. **Lock File**: Prevents concurrent runs
   - Location: `/tmp/batch-transcribe.lock`
   - Contains PID and timestamp
   - Auto-cleaned if stale (>2 hours)

2. **Max Runtime**: Kills job after configured hours (default: 2h)
   - Prevents runaway GPU costs
   - Logs warning if timeout triggered

3. **Instance State Check**: Verifies GPU stopped before starting new run

4. **Error Handling**: Logs failures, sends alerts if configured

## Troubleshooting

### Scheduler Not Running

```bash
# Check timer is enabled
sudo systemctl is-enabled batch-transcribe-scheduler.timer

# Check for errors
sudo journalctl -u batch-transcribe-scheduler.service -n 50

# Restart timer
sudo systemctl restart batch-transcribe-scheduler.timer
```

### GPU Not Starting

```bash
# Check AWS credentials
aws sts get-caller-identity

# Check GPU instance ID in .env
grep GPU_INSTANCE_ID .env

# Test GPU start manually
aws ec2 start-instances --instance-ids i-xxxxx --region us-east-2
```

### Chunks Detected But No Processing

```bash
# Check threshold setting
grep BATCH_THRESHOLD .env

# Check S3 for chunks
aws s3 ls s3://YOUR_BUCKET/audio-sessions/ --recursive | grep -c chunk

# Run manually with debug
BATCH_THRESHOLD=1 ./scripts/535-smart-batch-scheduler.sh
```

## Disabling Auto-Scheduling

### Temporarily Disable
```bash
# Stop timer (until reboot)
sudo systemctl stop batch-transcribe-scheduler.timer

# Re-enable
sudo systemctl start batch-transcribe-scheduler.timer
```

### Permanently Disable
```bash
# Disable timer (survives reboot)
sudo systemctl disable batch-transcribe-scheduler.timer
sudo systemctl stop batch-transcribe-scheduler.timer

# Or for cron:
crontab -e  # Remove the batch-transcribe line
```

## Advanced Configuration

### Custom Schedule (Every 30 Minutes)
```bash
# Edit timer file
sudo systemctl edit --full batch-transcribe-scheduler.timer

# Change OnCalendar line to:
OnCalendar=*:0/30  # Every 30 minutes

# Reload and restart
sudo systemctl daemon-reload
sudo systemctl restart batch-transcribe-scheduler.timer
```

### Email Notifications
```bash
# Install mailutils
sudo apt install mailutils

# Add to .env
BATCH_NOTIFY_EMAIL=your-email@example.com

# Script will email on completion/errors
```

### Slack Notifications
```bash
# Add to .env
SLACK_WEBHOOK_URL=https://hooks.slack.com/services/YOUR/WEBHOOK/URL

# Script posts to Slack on batch completion
```

## Performance Metrics

Expected performance with default settings:

| Chunks | GPU Time | Cost | Processing Time |
|--------|----------|------|-----------------|
| 100    | ~15 min  | $0.13| 20 min total    |
| 500    | ~1 hour  | $0.53| 70 min total    |
| 1000   | ~2 hours | $1.05| 140 min total   |

**Note**: Total time includes GPU startup (~2-3 min), transcription, and shutdown.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Systemd Timer (runs every hour)                   │
└──────────────────┬──────────────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────────────┐
│  535-smart-batch-scheduler.sh                      │
│  1. Check S3 for untranscribed chunks              │
│  2. If chunks >= threshold (100):                   │
│     - Start GPU (aws ec2 start-instances)          │
│     - Wait for ready (~2-3 min)                     │
│     - Run 515-run-batch-transcribe.sh               │
│     - Monitor progress                              │
│     - Stop GPU (aws ec2 stop-instances)            │
│  3. Log results + costs                             │
└─────────────────────────────────────────────────────┘
```

## Related Scripts

- **515-run-batch-transcribe.sh**: Core batch transcription logic
- **537-test-gpu-ssh.sh**: Verify GPU connectivity before batch
- **820-startup-restore.sh**: Manual GPU startup (bypasses scheduler)
- **530-start-gpu-instance.sh**: Start GPU without transcription

## See Also

- [Batch Transcription Optimization](./BATCH-OPTIMIZATION.md) - Performance tuning
- [Dynamic IP Lookup](./DYNAMIC-IP-LOOKUP.md) - How instance IDs replace static IPs
- [Cost Management](./COST-MANAGEMENT.md) - GPU cost tracking and optimization
