# Fix Dynamic IP Skill

Expert agent for finding and fixing static IP issues across all scripts in the project.

## Overview

This skill performs a comprehensive audit of the entire codebase to find and fix scripts that use static IP addresses instead of dynamic IP lookup. This is critical because EC2 instance public IPs change on every stop/start, breaking scripts that rely on hardcoded IPs from `.env`.

## When Claude Should Invoke This Skill

Claude Code should automatically invoke this skill when:

1. **Batch transcription fails** with "Timeout waiting for SSH"
2. **Scripts fail to connect** to GPU or Edge box after instance reboot
3. **User mentions IP-related failures** (connection timeouts, SSH failures)
4. **Setting up new deployment** and want to ensure IP handling is correct
5. **Proactive audit requested** by user
6. **After any EC2 instance stop/start** that causes connection issues

## What This Skill Does

### 10-Step Process (As Requested)

1. **Tell user about the problem**
   - Scans all scripts for static IP usage patterns
   - Explains why static IPs cause failures (IPs change on reboot, instance IDs don't)
   - Shows specific scripts and line numbers with problems

2. **Explain what it will do**
   - Details the dynamic IP lookup pattern (instance ID → current IP)
   - Shows before/after examples for each script
   - Lists all files that will be modified

3. **Search all code and ask user to proceed**
   - Comprehensive grep search for: `GPU_INSTANCE_IP`, `EDGE_BOX_IP`, `GPU_HOST`
   - Shows exactly which scripts will be updated
   - Asks explicit permission before making any changes

4. **Fix all scripts for reboot/new IPs**
   - GPU: Changes `GPU_IP="${GPU_INSTANCE_IP}"` to `GPU_IP=$(get_instance_ip "$GPU_INSTANCE_ID")`
   - Edge: Changes `EDGE_IP="${EDGE_BOX_IP}"` to `EDGE_IP=$(get_instance_ip "$EDGE_BOX_INSTANCE_ID")`
   - Adds error handling for failed IP lookups
   - Sources `riva-common-library.sh` if needed (for `get_instance_ip()` function)

5. **Make sure implementations reflect to .env**
   - Removes `GPU_INSTANCE_IP` from `.env` (stale IP removed)
   - Removes `EDGE_BOX_IP` from `.env` (stale IP removed)
   - Keeps `GPU_INSTANCE_ID` and `EDGE_BOX_INSTANCE_ID` (permanent values)
   - Ensures `EDGE_BOX_DNS` and `WHISPERLIVE_WS_URL` are updated by startup scripts

6. **Ensure instance IDs set properly from startup scripts**
   - Verifies `scripts/005-setup-configuration.sh` prompts for instance IDs
   - Checks `scripts/820-startup-restore.sh` detects GPU IP changes automatically
   - Validates `scripts/825-update-edge-box-ip.sh` handles edge box IP changes
   - Ensures `scripts/827-setup-edge-ip-autodetect.sh` enables automatic detection

7. **Ensure .env.example copied with right seed values**
   - Updates `.env.example` with clear documentation
   - Adds comments explaining instance ID vs IP
   - Includes example values: `GPU_INSTANCE_ID=i-xxxxxxxxxxxxxxxxx`
   - Documents that IPs are auto-detected, not manually set

8. **Test run on edge box showing change is fine**
   - Simulates edge box IP change scenario
   - Runs `./scripts/825-update-edge-box-ip.sh`
   - Verifies:
     - New IP detected correctly
     - `.env` updated with new IP
     - SSL certificate regenerated
     - Caddy restarted
     - WebSocket URL updated
   - Reports pass/fail status

9. **Test run on GPU showing changed IP is fine**
   - Simulates GPU restart scenario
   - Runs `./scripts/820-startup-restore.sh`
   - Verifies:
     - New GPU IP detected from instance ID
     - `.env` updated automatically
     - SSH connection works with new IP
     - WhisperLive services restored
   - Reports pass/fail status

10. **Quick validation on all scripts using the utility**
    - Creates diagnostic script: `scripts/537-test-gpu-ssh.sh`
    - Tests each updated script:
      - `515-run-batch-transcribe.sh` - No SSH timeout
      - `325-test-whisperlive-connection.sh` - Connects successfully
      - `310-setup-whisperlive-gpu.sh` - Works with current IP
    - Reports summary: X/X scripts passing
    - Lists any failures with diagnostic info

## Technical Details

### The Problem Pattern

```bash
# WRONG - Uses static IP from .env (breaks on reboot)
GPU_IP="${GPU_INSTANCE_IP}"
ssh ubuntu@$GPU_IP "command"
```

After GPU restarts:
- `.env` has old IP: `18.219.195.218`
- GPU gets new IP: `3.137.150.79`
- Script tries old IP → CONNECTION TIMEOUT → FAILURE

### The Solution Pattern

```bash
# CORRECT - Dynamic IP lookup from instance ID
GPU_IP=$(get_instance_ip "$GPU_INSTANCE_ID")
if [ -z "$GPU_IP" ]; then
    log_error "Failed to get GPU IP from instance ID: $GPU_INSTANCE_ID"
    exit 1
fi
ssh ubuntu@$GPU_IP "command"
```

After GPU restarts:
- `.env` has instance ID: `i-03a292875d9b12688` (never changes)
- Script looks up current IP via AWS API: `3.137.150.79`
- Script uses current IP → CONNECTION SUCCESS

### Scripts Known to Need Fixing

From previous analysis:
- `scripts/515-run-batch-transcribe.sh` - Main batch transcription (CRITICAL)
- `scripts/325-test-whisperlive-connection.sh` - Connection testing
- `scripts/310-setup-whisperlive-gpu.sh` - GPU setup
- `scripts/lib/common-functions.sh` - `run_remote()` and `copy_to_remote()` functions
- `scripts/545-health-check-gpu.sh` - Health monitoring

### Scripts That Are Already Correct

Reference implementations (do NOT modify):
- `scripts/820-startup-restore.sh` - Already uses dynamic IP lookup
- `scripts/825-update-edge-box-ip.sh` - Handles edge box IP changes
- `scripts/530-start-gpu-instance.sh` - Uses instance ID only
- `scripts/536-batch-watchdog.sh` - Uses instance ID only

### Standard Functions Available

From `scripts/riva-common-library.sh`:
```bash
get_instance_ip() {
    local instance_id="${1:-$(get_instance_id)}"
    aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text \
        --region "${AWS_REGION:-us-east-2}"
}
```

## Expected `.env` Changes

### Before (BROKEN)
```bash
GPU_INSTANCE_ID=i-03a292875d9b12688
GPU_INSTANCE_IP=18.219.195.218  # STALE - causes failures

EDGE_BOX_INSTANCE_ID=i-0123456789abcdef0
EDGE_BOX_IP=3.16.164.228  # STALE - causes failures
```

### After (FIXED)
```bash
# GPU Instance - Use instance ID only (IP is looked up dynamically)
GPU_INSTANCE_ID=i-03a292875d9b12688
# REMOVED: GPU_INSTANCE_IP (was causing failures)

# Edge Box Instance - Use instance ID only
EDGE_BOX_INSTANCE_ID=i-0123456789abcdef0
# REMOVED: EDGE_BOX_IP (was causing failures)

# Edge Box DNS - Auto-updated by startup scripts (820, 825)
EDGE_BOX_DNS=3.16.164.228
WHISPERLIVE_WS_URL=wss://3.16.164.228/ws
```

## Success Criteria

After running this skill:
- ✅ Zero scripts using `GPU_INSTANCE_IP` or `EDGE_BOX_IP` variables
- ✅ All scripts use instance IDs with dynamic IP lookup
- ✅ Edge box IP change test passes
- ✅ GPU IP change test passes
- ✅ Batch transcription works after GPU restart
- ✅ `.env` and `.env.example` reflect best practices
- ✅ Diagnostic script (537) created and passing
- ✅ All validation tests pass

## Usage

This skill is invoked by Claude Code automatically when IP-related issues are detected.

Manual invocation (for testing):
```bash
cd /home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4
./.claude/skills/fix-dynamic-ip/fix-dynamic-ip.sh
```

## Files Modified by This Skill

Scripts:
- `scripts/515-run-batch-transcribe.sh`
- `scripts/325-test-whisperlive-connection.sh`
- `scripts/310-setup-whisperlive-gpu.sh`
- `scripts/lib/common-functions.sh`
- `scripts/545-health-check-gpu.sh` (if needed)

Configuration:
- `.env` (remove static IPs)
- `.env.example` (add documentation)

New files:
- `scripts/537-test-gpu-ssh.sh` (diagnostic script)

## Integration with Other Scripts

This skill ensures these scripts work correctly:
- `005-setup-configuration.sh` - Prompts for instance IDs properly
- `820-startup-restore.sh` - Detects GPU IP changes automatically
- `825-update-edge-box-ip.sh` - Handles edge box IP changes
- `827-setup-edge-ip-autodetect.sh` - Enables automatic IP detection on boot

## Error Handling

If IP lookup fails:
```bash
GPU_IP=$(get_instance_ip "$GPU_INSTANCE_ID")
if [ -z "$GPU_IP" ] || [ "$GPU_IP" = "None" ]; then
    log_error "Failed to get GPU IP from instance ID: $GPU_INSTANCE_ID"
    log_error "Is the instance running? Check: aws ec2 describe-instances --instance-ids $GPU_INSTANCE_ID"
    exit 1
fi
```

## Testing Strategy

### Edge Box Test
```bash
# Simulate IP change
./scripts/825-update-edge-box-ip.sh

# Expected outcome:
# ✅ New IP detected
# ✅ .env updated
# ✅ SSL cert regenerated
# ✅ Caddy restarted
# ✅ UI redeployed
```

### GPU Test
```bash
# Simulate restart
./scripts/820-startup-restore.sh

# Expected outcome:
# ✅ New GPU IP detected
# ✅ .env updated
# ✅ SSH works
# ✅ WhisperLive restored
```

### Validation Test
```bash
# Run diagnostic
./scripts/537-test-gpu-ssh.sh

# Expected outcome:
# ✅ Instance ID → IP lookup: PASS
# ✅ SSH connection: PASS
# ✅ Ready for batch transcription
```

## Maintenance

This skill should be re-run whenever:
- New scripts are added that connect to GPU or Edge box
- Connection failures occur after instance restarts
- Deployment to new environment (ensures clean IP handling)
- Quarterly audit (proactive health check)
