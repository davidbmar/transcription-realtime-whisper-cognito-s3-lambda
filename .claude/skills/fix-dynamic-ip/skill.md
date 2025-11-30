# fix-dynamic-ip

**Expert agent for finding and fixing static IP issues across all scripts**

## When to Use This Skill

Invoke this skill when:
- Batch transcription fails with "Timeout waiting for SSH"
- Scripts fail to connect to GPU or Edge box after reboot
- IP addresses change after EC2 instance stop/start
- User mentions IP-related connection failures
- Setting up new deployment and want to ensure IP handling is correct
- Proactively auditing codebase for IP-related issues

## What This Skill Does

This skill performs a comprehensive audit and fix of all IP address handling in the codebase:

1. **Problem Identification**: Scans all scripts for static IP usage patterns
2. **User Communication**: Explains findings and proposed fixes clearly
3. **Comprehensive Search**: Finds ALL scripts using IPs (GPU_INSTANCE_IP, EDGE_BOX_IP, etc.)
4. **Fix Implementation**: Updates scripts to use dynamic IP lookup from instance IDs
5. **Environment Sync**: Ensures .env reflects correct pattern (instance IDs, not IPs)
6. **Startup Script Updates**: Ensures 005-setup-configuration.sh and 820-startup-restore.sh handle IPs correctly
7. **Template Updates**: Updates .env.example with proper seed values and documentation
8. **Edge Box Testing**: Validates IP changes work correctly on edge box
9. **GPU Testing**: Validates IP changes work correctly on GPU
10. **Validation**: Quick test run of all updated scripts to ensure they work

## Key Technical Patterns

### The Problem
EC2 instance public IPs change on every stop/start, but instance IDs remain constant. Scripts using static IPs from .env break after reboots.

### The Solution
Always use instance ID → dynamic IP lookup pattern:
```bash
# WRONG (static IP from .env)
GPU_IP="${GPU_INSTANCE_IP}"

# CORRECT (dynamic lookup from instance ID)
GPU_IP=$(get_instance_ip "$GPU_INSTANCE_ID")
```

### Standard Functions Available
From `scripts/common-library.sh`:
- `get_instance_ip()` - Look up current IP from instance ID
- `get_instance_id()` - Get instance ID from name tag

From `scripts/lib/common-functions.sh`:
- `run_remote()` - SSH command execution (needs fix)
- `copy_to_remote()` - SCP file transfer (needs fix)

## Scripts Known to Have Issues

Based on previous analysis:
- `scripts/515-run-batch-transcribe.sh` - Uses static GPU_INSTANCE_IP
- `scripts/325-test-whisperlive-connection.sh` - Uses static IP
- `scripts/310-setup-whisperlive-gpu.sh` - Uses static IP
- `scripts/lib/common-functions.sh` - run_remote() and copy_to_remote() use static IP

Scripts that are CORRECT (reference implementations):
- `scripts/820-startup-restore.sh` - Dynamic IP lookup pattern
- `scripts/530-start-gpu-instance.sh` - Uses instance ID only
- `scripts/536-batch-watchdog.sh` - Uses instance ID only

## Expected Environment Variables

### .env (Current Deployment)
```bash
# AWS Configuration
AWS_REGION=us-east-2
AWS_ACCOUNT_ID=123456789012

# GPU Instance (INSTANCE ID ONLY - IP is dynamic)
GPU_INSTANCE_ID=i-03a292875d9b12688
# REMOVED: GPU_INSTANCE_IP (was causing issues)

# Edge Box Instance (INSTANCE ID ONLY - IP is dynamic)
EDGE_BOX_INSTANCE_ID=i-0123456789abcdef0
# REMOVED: EDGE_BOX_IP (was causing issues)

# Edge Box DNS (updated by 820-startup-restore.sh and 825-update-edge-box-ip.sh)
EDGE_BOX_DNS=3.16.164.228
WHISPERLIVE_WS_URL=wss://3.16.164.228/ws

# SSH Configuration
SSH_KEY=/home/ubuntu/.ssh/id_rsa
SSH_USER=ubuntu
```

### .env.example (Template)
Should have placeholders and clear documentation:
```bash
# GPU Instance - Use instance ID, NOT IP (IP changes on reboot)
GPU_INSTANCE_ID=i-xxxxxxxxxxxxxxxxx

# Edge Box Instance - Use instance ID, NOT IP
EDGE_BOX_INSTANCE_ID=i-xxxxxxxxxxxxxxxxx

# Edge Box DNS - Auto-updated by startup scripts
EDGE_BOX_DNS=YOUR_EDGE_BOX_IP
WHISPERLIVE_WS_URL=wss://YOUR_EDGE_BOX_IP/ws
```

## Testing Approach

### 1. Edge Box IP Change Test
```bash
# Simulate IP change on edge box
cd /home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4
./scripts/825-update-edge-box-ip.sh
# Should detect new IP, update .env, restart services
```

### 2. GPU IP Change Test
```bash
# Simulate GPU restart (IP changes)
./scripts/820-startup-restore.sh
# Should detect new IP, update .env, restore services
```

### 3. Script Validation
```bash
# Test each fixed script
./scripts/537-test-gpu-ssh.sh          # Should connect successfully
./scripts/515-run-batch-transcribe.sh  # Should not timeout on SSH
./scripts/325-test-whisperlive-connection.sh  # Should connect to GPU
```

## Expected Outcomes

After running this skill:
1. All scripts use dynamic IP lookup (no static IPs from .env)
2. .env contains only instance IDs (GPU_INSTANCE_ID, EDGE_BOX_INSTANCE_ID)
3. .env.example documents the correct pattern clearly
4. Startup scripts (005, 820, 825) handle IP detection automatically
5. Edge box IP changes work seamlessly
6. GPU IP changes work seamlessly
7. All scripts pass validation tests
8. User has confidence system survives reboots

## Files This Skill Will Modify

- `scripts/515-run-batch-transcribe.sh`
- `scripts/325-test-whisperlive-connection.sh`
- `scripts/310-setup-whisperlive-gpu.sh`
- `scripts/lib/common-functions.sh`
- `scripts/545-health-check-gpu.sh` (if needed)
- `.env.example`
- `scripts/005-setup-configuration.sh` (ensure instance ID prompts)
- New: `scripts/537-test-gpu-ssh.sh` (diagnostic script)

## User Interaction Pattern

The skill will:
1. **Report findings**: "Found 5 scripts using static IPs"
2. **Explain impact**: "These scripts will fail after GPU/Edge reboot"
3. **Show proposed changes**: "Will update to use get_instance_ip() pattern"
4. **Ask permission**: "Proceed with fixes? (y/n)"
5. **Implement fixes**: Update all identified scripts
6. **Update configuration**: Fix .env and .env.example
7. **Run tests**: Validate changes work correctly
8. **Report results**: "All scripts updated and tested successfully"

## Success Criteria

- Zero scripts using GPU_INSTANCE_IP or EDGE_BOX_IP variables
- All scripts using instance IDs with dynamic lookup
- Edge box IP change test passes
- GPU IP change test passes
- Batch transcription works after GPU restart
- .env and .env.example reflect best practices
