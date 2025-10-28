---
name: script-template
description: Generate new bash scripts that follow all project patterns (env loading, logging, success/failure reporting). Use when creating new numbered scripts like 220-*, 305-*, etc.
allowed-tools: AskUserQuestion, Write, Bash, Read, Grep, Glob
---

# Script Template Generator

You are a script template generator for this project. This skill creates new bash scripts that automatically follow all established patterns in the codebase.

## Overview

When invoked, you will:
1. Display a brief 2-3 sentence summary explaining what you're about to do
2. Interactively gather script requirements from the user
3. Generate a complete script following all project patterns
4. Auto-create the file in the scripts/ directory
5. Make it executable
6. Tell the user what to do next

## Established Patterns to Follow

Based on analysis of existing scripts (220-startup-restore.sh, 305-setup-whisperlive-edge.sh, 310-configure-whisperlive-gpu.sh, common-functions.sh):

### 1. File Header (Lines 1-3)
```bash
#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1
```

### 2. Documentation Header
```bash
# ============================================================================
# Script ###: [Script Title]
# ============================================================================
# [Brief description paragraph]
#
# What this does:
# 1. [Step 1]
# 2. [Step 2]
# 3. [Step 3]
# ... (all steps)
#
# Requirements:
# - .env variables: [LIST_VARIABLES]
#
# Total time: [ESTIMATE]
# ============================================================================
```

### 3. Path Resolution (handles symlinks)
```bash
# Resolve script path (handles symlinks)
if [ -L "${BASH_SOURCE[0]}" ]; then
    SCRIPT_REAL=$(readlink -f "${BASH_SOURCE[0]}")
else
    SCRIPT_REAL="${BASH_SOURCE[0]}"
fi
PROJECT_ROOT="$(cd "$(dirname "$SCRIPT_REAL")/.." && pwd)"
```

### 4. Environment & Library Loading
```bash
# Load environment and common functions
source "$PROJECT_ROOT/.env"
source "$PROJECT_ROOT/scripts/lib/common-functions.sh"
```

### 5. Runtime Banner
```bash
echo "============================================"
echo "###: [Script Title]"
echo "============================================"
echo ""
```

### 6. Pre-execution Summary
```bash
log_info "This script will:"
log_info "  1. [Step 1]"
log_info "  2. [Step 2]"
log_info "  3. [Step 3]"
echo ""
```

### 7. Main Implementation
```bash
# ============================================================================
# Main Implementation
# ============================================================================

log_info "Step 1: [Description]"
# TODO: Implement step 1

log_success "Step 1 completed"
echo ""

# ... repeat for all steps
```

### 8. Feature-Specific Helpers

**If SSH Operations selected:**
```bash
# SSH Configuration
SSH_KEY="$PROJECT_ROOT/$GPU_SSH_KEY_PATH"
SSH_USER="ubuntu"

# Verify SSH access
log_info "Verifying SSH access to GPU instance..."
if ! ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$GPU_INSTANCE_IP" "echo 'SSH OK'" &>/dev/null; then
    log_error "Cannot SSH to GPU instance at $GPU_INSTANCE_IP"
    exit 1
fi
log_success "SSH connection verified"
```

**If AWS Operations selected:**
```bash
# AWS Configuration
AWS_REGION="${AWS_REGION:-us-east-1}"

# Get instance status
log_info "Checking AWS EC2 instance status..."
INSTANCE_STATE=$(aws ec2 describe-instances \
    --instance-ids "$GPU_INSTANCE_ID" \
    --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text 2>/dev/null || echo "unknown")

log_info "Instance state: $INSTANCE_STATE"
```

**If Status Tracking selected:**
```bash
# Update status in .env
STATUS_KEY="SCRIPT_###_STATUS"
update_env_status "$STATUS_KEY" "running"

# ... at end of script:
update_env_status "$STATUS_KEY" "completed"
```

### 9. Success Reporting & Next Steps
```bash
echo ""
log_info "==================================================================="
log_success "✅ [SCRIPT TITLE] COMPLETED"
log_info "==================================================================="
echo ""
log_info "Summary:"
log_info "  - [Key achievement 1]"
log_info "  - [Key achievement 2]"
echo ""
log_info "Next Steps:"
log_info "  1. [Next script to run]: ./scripts/###-next-script.sh"
log_info "  2. [Alternative action]"
echo ""
```

## Script Numbering Convention

- **000-099**: Setup/Configuration scripts
- **100-199**: Deployment scripts
- **200-299**: Operational/daily use scripts
- **300-399**: WhisperLive-specific operations
- **700-799**: Advanced/alternate scripts

## Execution Instructions

### Step 1: Display Summary
Start by displaying this message to the user:

```
🚀 Script Template Generator

I'll create a new bash script that follows all project patterns:
- Auto-loads .env and common functions
- Includes proper logging and error handling
- Has pre-execution summaries and success/failure reporting
- Follows the project's numbering convention

Let me gather some details about your script...
```

### Step 2: Gather Requirements Interactively

Use the AskUserQuestion tool to collect:

**Question 1: Script Number**
- Question: "What number should this script have? (e.g., 220, 305, 710)"
- Options: Provide examples based on categories
  - "000-099: Setup/Configuration"
  - "200-299: Operations/Daily Use"
  - "300-399: WhisperLive Operations"
  - "700-799: Advanced/Alternate"

**Question 2: Features to Include**
- Question: "Which features should this script include?"
- Multi-select: true
- Options:
  - "SSH Operations: SSH to GPU instance, execute remote commands"
  - "AWS Operations: EC2 instance management, status checks"
  - "Status Tracking: Update .env with script execution status"
  - "Minimal: Just core patterns (logging, env, success/failure)"

**Question 3: Additional Details**
Prompt the user to provide (you can ask this conversationally, not via AskUserQuestion):
- Script title/name (e.g., "Deploy WhisperLive Edge Proxy")
- Brief description (1-2 sentences about what it does)
- Step-by-step breakdown (numbered list of what the script will do)
- Required .env variables (if any beyond the standard ones)
- Estimated execution time
- What script(s) should run next after this one completes

### Step 3: Generate the Script

Combine all the patterns above with the user's requirements to create a complete, functional script template.

**File naming**: `scripts/###-kebab-case-name.sh`
- Example: `scripts/220-startup-restore.sh`
- Derive from the script title

### Step 4: Create and Finalize

1. Write the script to `scripts/###-[name].sh`
2. Make it executable: `chmod +x scripts/###-[name].sh`
3. Display the full path to the user

### Step 5: Completion Message

Display this to the user:

```
✅ Script created successfully!

📄 Location: scripts/###-[name].sh
📝 Features: [list selected features]

Next steps:
1. Review the script and customize the TODO sections
2. Test it: ./scripts/###-[name].sh
3. Add it to run.sh menu if it's commonly used

The script includes all standard patterns:
- Environment loading from .env
- Consistent logging (log_info, log_success, log_error, log_warn)
- Pre-execution summary
- Success/failure reporting
- "Next Steps" guidance for users
```

## Important Notes

- **DO NOT** hardcode any values - always use .env variables
- **DO** include comprehensive logging at each step
- **DO** validate required .env variables exist before proceeding
- **DO** include helpful error messages
- **DO** tell users what to run next in the success message
- Scripts should be **idempotent** when possible (safe to run multiple times)
- Always use `set -euo pipefail` for proper error handling

## Example Generated Script Structure

```bash
#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Script 220: Example Script
# ============================================================================
# This is an example script that demonstrates the pattern.
#
# What this does:
# 1. Loads environment variables
# 2. Performs example operation
# 3. Reports success
#
# Requirements:
# - .env variables: EXAMPLE_VAR
#
# Total time: ~1 minute
# ============================================================================

# Resolve script path (handles symlinks)
if [ -L "${BASH_SOURCE[0]}" ]; then
    SCRIPT_REAL=$(readlink -f "${BASH_SOURCE[0]}")
else
    SCRIPT_REAL="${BASH_SOURCE[0]}"
fi
PROJECT_ROOT="$(cd "$(dirname "$SCRIPT_REAL")/.." && pwd)"

# Load environment and common functions
source "$PROJECT_ROOT/.env"
source "$PROJECT_ROOT/scripts/lib/common-functions.sh"

echo "============================================"
echo "220: Example Script"
echo "============================================"
echo ""

log_info "This script will:"
log_info "  1. Do something useful"
log_info "  2. Do something else"
echo ""

# ============================================================================
# Main Implementation
# ============================================================================

log_info "Step 1: Doing something useful"
# TODO: Implement step 1
log_success "Step 1 completed"
echo ""

log_info "Step 2: Doing something else"
# TODO: Implement step 2
log_success "Step 2 completed"
echo ""

# ============================================================================
# Success Reporting
# ============================================================================

echo ""
log_info "==================================================================="
log_success "✅ EXAMPLE SCRIPT COMPLETED"
log_info "==================================================================="
echo ""
log_info "Summary:"
log_info "  - Task completed successfully"
echo ""
log_info "Next Steps:"
log_info "  1. Run the next script: ./scripts/###-next-script.sh"
echo ""
```

---

Now proceed with the execution instructions above to create the user's script!
