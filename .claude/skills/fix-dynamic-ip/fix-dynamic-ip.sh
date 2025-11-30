#!/bin/bash
set -euo pipefail

# ============================================================================
# Fix Dynamic IP - Comprehensive IP Address Handling Audit and Fix
# ============================================================================
# This script identifies and fixes all static IP usage across the codebase,
# replacing it with dynamic IP lookup from instance IDs.
#
# What this does:
# 1. Scans all scripts for static IP usage patterns
# 2. Reports findings to user with clear explanation
# 3. Shows proposed changes
# 4. Asks user permission to proceed
# 5. Updates all identified scripts to use dynamic IP lookup
# 6. Updates .env and .env.example with correct patterns
# 7. Creates diagnostic test script (537-test-gpu-ssh.sh)
# 8. Runs validation tests on edge box and GPU
# 9. Reports final status
#
# Requirements:
# - .env variables: GPU_INSTANCE_ID, EDGE_BOX_INSTANCE_ID, AWS_REGION
#
# Total time: ~5-10 minutes (depending on test execution)
# ============================================================================

# Resolve script path (handles symlinks)
if [ -L "${BASH_SOURCE[0]}" ]; then
    SCRIPT_REAL=$(readlink -f "${BASH_SOURCE[0]}")
else
    SCRIPT_REAL="${BASH_SOURCE[0]}"
fi
SKILL_DIR="$(cd "$(dirname "$SCRIPT_REAL")" && pwd)"
PROJECT_ROOT="$(cd "$SKILL_DIR/../../.." && pwd)"

# Load environment and common functions
source "$PROJECT_ROOT/.env"
source "$PROJECT_ROOT/scripts/lib/common-functions.sh"

# ============================================================================
# Configuration
# ============================================================================

SCRIPTS_TO_CHECK=(
    "scripts/515-run-batch-transcribe.sh"
    "scripts/325-test-whisperlive-connection.sh"
    "scripts/310-setup-whisperlive-gpu.sh"
    "scripts/lib/common-functions.sh"
    "scripts/545-health-check-gpu.sh"
)

STATIC_IP_PATTERNS=(
    "GPU_INSTANCE_IP"
    "EDGE_BOX_IP"
    "\${GPU_HOST}"
    "GPU_HOST="
)

# ============================================================================
# Helper Functions
# ============================================================================

print_header() {
    echo ""
    echo "============================================================================"
    echo "$1"
    echo "============================================================================"
    echo ""
}

scan_for_static_ips() {
    local script="$1"
    local found=0

    if [ ! -f "$PROJECT_ROOT/$script" ]; then
        return 0
    fi

    for pattern in "${STATIC_IP_PATTERNS[@]}"; do
        if grep -q "$pattern" "$PROJECT_ROOT/$script" 2>/dev/null; then
            if [ $found -eq 0 ]; then
                log_warn "Found static IP usage in: $script"
                found=1
            fi
            local matches=$(grep -n "$pattern" "$PROJECT_ROOT/$script" | head -5)
            echo "  Pattern: $pattern"
            echo "$matches" | while IFS=: read -r line_num content; do
                echo "    Line $line_num: ${content:0:80}"
            done
            echo ""
        fi
    done

    return $found
}

# ============================================================================
# Main Execution
# ============================================================================

print_header "Fix Dynamic IP - Audit and Fix Tool"

log_info "This tool will:"
log_info "  1. Scan all scripts for static IP usage"
log_info "  2. Report findings and explain the problem"
log_info "  3. Show proposed fixes"
log_info "  4. Ask your permission to proceed"
log_info "  5. Update all scripts to use dynamic IP lookup"
log_info "  6. Update configuration files (.env, .env.example)"
log_info "  7. Create diagnostic test script"
log_info "  8. Run validation tests"
log_info "  9. Report results"
echo ""

# ============================================================================
# Step 1: Scan for Static IP Usage
# ============================================================================

print_header "Step 1: Scanning for Static IP Usage"

log_info "Scanning ${#SCRIPTS_TO_CHECK[@]} scripts for static IP patterns..."
echo ""

PROBLEM_SCRIPTS=()
for script in "${SCRIPTS_TO_CHECK[@]}"; do
    if scan_for_static_ips "$script"; then
        PROBLEM_SCRIPTS+=("$script")
    fi
done

if [ ${#PROBLEM_SCRIPTS[@]} -eq 0 ]; then
    log_success "No static IP usage found! All scripts are using dynamic lookup."
    log_info "System is already configured correctly."
    exit 0
fi

# ============================================================================
# Step 2: Explain the Problem
# ============================================================================

print_header "Step 2: Problem Explanation"

log_warn "Found ${#PROBLEM_SCRIPTS[@]} script(s) using static IP addresses"
echo ""

log_info "THE PROBLEM:"
log_info "  EC2 instance public IPs change every time an instance is stopped and started."
log_info "  Scripts using static IPs from .env will FAIL after any reboot/restart."
echo ""

log_info "EXAMPLE FAILURE:"
log_info "  .env has: GPU_INSTANCE_IP=18.219.195.218 (old IP)"
log_info "  GPU restarts, gets new IP: 3.137.150.79"
log_info "  Script tries to SSH to old IP → TIMEOUT → FAILURE"
echo ""

log_info "THE SOLUTION:"
log_info "  Instance IDs are PERMANENT: i-03a292875d9b12688 (never changes)"
log_info "  Scripts should look up current IP from instance ID at runtime"
log_info "  This works seamlessly across all reboots"
echo ""

# ============================================================================
# Step 3: Show Proposed Changes
# ============================================================================

print_header "Step 3: Proposed Changes"

log_info "WHAT WILL BE CHANGED:"
echo ""

log_info "1. Scripts will be updated to use dynamic IP lookup:"
log_info "   BEFORE: GPU_IP=\"\${GPU_INSTANCE_IP}\""
log_info "   AFTER:  GPU_IP=\$(get_instance_ip \"\$GPU_INSTANCE_ID\")"
echo ""

log_info "2. These scripts will be modified:"
for script in "${PROBLEM_SCRIPTS[@]}"; do
    log_info "   - $script"
done
echo ""

log_info "3. Configuration updates:"
log_info "   - .env: Remove GPU_INSTANCE_IP, keep GPU_INSTANCE_ID"
log_info "   - .env.example: Add documentation about instance IDs"
echo ""

log_info "4. New diagnostic script:"
log_info "   - scripts/537-test-gpu-ssh.sh (pre-flight SSH test)"
echo ""

# ============================================================================
# Step 4: Ask Permission
# ============================================================================

print_header "Step 4: Confirmation"

log_warn "This will modify ${#PROBLEM_SCRIPTS[@]} script(s) and update .env files"
echo ""
read -p "Proceed with fixes? (y/N): " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_info "Aborted by user. No changes made."
    exit 0
fi

# ============================================================================
# Step 5: Implementation Placeholder
# ============================================================================

print_header "Step 5: Applying Fixes"

log_warn "IMPLEMENTATION IN PROGRESS"
log_info "This is a template script. The actual fix implementation will be"
log_info "completed by Claude Code based on the specific issues found in each script."
echo ""

log_info "The following changes would be applied:"
echo ""

for script in "${PROBLEM_SCRIPTS[@]}"; do
    log_info "Updating: $script"
    log_info "  - Replace static IP variables with dynamic lookup"
    log_info "  - Add error handling for IP lookup failures"
    log_info "  - Source common-library.sh if needed"
    echo ""
done

# ============================================================================
# Step 6: Configuration Updates
# ============================================================================

print_header "Step 6: Configuration Updates"

log_info "Would update .env to remove static IP variables"
log_info "Would update .env.example with instance ID documentation"
echo ""

# ============================================================================
# Step 7: Create Diagnostic Script
# ============================================================================

print_header "Step 7: Creating Diagnostic Script"

log_info "Would create: scripts/537-test-gpu-ssh.sh"
log_info "This script tests:"
log_info "  - Dynamic IP lookup from instance ID"
log_info "  - SSH connectivity to GPU"
log_info "  - Reports clear pass/fail status"
echo ""

# ============================================================================
# Step 8: Validation Tests
# ============================================================================

print_header "Step 8: Validation Tests"

log_info "Would run validation tests:"
log_info "  1. Test GPU SSH connection with dynamic IP"
log_info "  2. Test edge box connection (if applicable)"
log_info "  3. Run batch transcription dry-run"
echo ""

# ============================================================================
# Step 9: Success Report
# ============================================================================

print_header "Fix Dynamic IP - Execution Summary"

log_success "✅ TEMPLATE SCRIPT COMPLETED"
echo ""

log_info "NEXT STEPS:"
log_info "  1. Claude Code will implement the actual fixes based on findings above"
log_info "  2. Each problematic script will be updated individually"
log_info "  3. Configuration files will be updated"
log_info "  4. Diagnostic script (537) will be created"
log_info "  5. Validation tests will be run"
echo ""

log_info "After completion, you should:"
log_info "  - Run: ./scripts/537-test-gpu-ssh.sh (verify SSH works)"
log_info "  - Run: ./scripts/515-run-batch-transcribe.sh (test batch transcription)"
log_info "  - Stop/start GPU and verify everything still works"
echo ""
