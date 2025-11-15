#!/bin/bash
#
# Riva Deployment Scripts - Common Functions Library
# 
# This library provides shared functionality for all riva-xxx scripts:
# - Environment validation
# - SSH connectivity 
# - Riva server management
# - Status tracking
# - Error handling
# - Test script generation
#
# Usage: source this file in any riva-xxx script
#

# =============================================================================
# LOGGING AND OUTPUT FUNCTIONS
# =============================================================================

# Logging functions for consistent output
log_info() {
    echo "ℹ️  $1"
}

log_success() {
    echo "✅ $1"
}

log_warn() {
    echo "⚠️  $1"
}

log_error() {
    echo "❌ $1"
}

log_execution_start() {
    local script_name="$1"
    local script_desc="$2"
    echo "🚀 Starting: $script_name"
    echo "📋 Description: $script_desc"
    echo "⏰ Started at: $(date)"
    echo ""
}

# Load environment with validation
load_environment() {
    if [[ ! -f .env ]]; then
        log_error ".env file not found. Please create one from .env.example first"
        exit 1
    fi
    source .env
    log_info "Environment loaded from .env"
}

# Update or add a variable to .env file (prevents duplicates)
# Usage: update_env_var "VAR_NAME" "value" [env_file_path]
update_env_var() {
    local var_name="$1"
    local var_value="$2"
    local env_file="${3:-.env}"

    if [[ ! -f "$env_file" ]]; then
        log_error "Environment file not found: $env_file"
        return 1
    fi

    # Check if variable exists
    if grep -q "^${var_name}=" "$env_file"; then
        # Update existing variable
        sed -i "s|^${var_name}=.*|${var_name}=${var_value}|" "$env_file"
    else
        # Append new variable
        echo "${var_name}=${var_value}" >> "$env_file"
    fi
}

# Step execution helpers
start_step() {
    local step_name="$1"
    echo ""
    log_info "🔧 Starting step: $step_name"
}

end_step() {
    log_success "Step completed"
}

# =============================================================================
# CONFIGURATION AND VALIDATION
# =============================================================================

# Load and validate .env configuration
load_and_validate_env() {
    if [[ ! -f .env ]]; then
        echo "❌ .env file not found. Please run configuration scripts first."
        exit 1
    fi
    
    source .env
    
    # Validate required base variables
    local base_vars=("GPU_INSTANCE_IP" "SSH_KEY_NAME")
    for var in "${base_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            echo "❌ Required environment variable $var not set in .env"
            exit 1
        fi
    done
}

# Validate SSH key exists and test connectivity
validate_ssh_connectivity() {
    local SSH_KEY_PATH="$HOME/.ssh/${SSH_KEY_NAME}.pem"
    
    if [[ ! -f "$SSH_KEY_PATH" ]]; then
        echo "❌ SSH key not found: $SSH_KEY_PATH"
        exit 1
    fi
    
    if ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i "$SSH_KEY_PATH" ubuntu@"$GPU_INSTANCE_IP" "echo 'SSH OK'" >/dev/null 2>&1; then
        echo "❌ Cannot connect to GPU instance via SSH: ubuntu@$GPU_INSTANCE_IP"
        echo "💡 Check that the instance is running and accessible"
        exit 1
    fi
}

# Validate Riva-specific environment variables
validate_riva_env() {
    local riva_vars=("RIVA_HOST" "RIVA_PORT" "RIVA_MODEL")
    for var in "${riva_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            echo "❌ Required Riva variable $var not set in .env"
            exit 1
        fi
    done
}

# =============================================================================
# GPU INSTANCE VERIFICATION
# =============================================================================

# Validate GPU instance ID and optionally auto-correct it
# Usage: validate_gpu_instance_id [--auto-fix]
validate_gpu_instance_id() {
    local auto_fix=false
    if [[ "${1:-}" == "--auto-fix" ]]; then
        auto_fix=true
    fi

    local instance_id="${GPU_INSTANCE_ID:-}"
    local region="${AWS_REGION:-us-east-2}"

    # Check if GPU_INSTANCE_ID is set
    if [[ -z "$instance_id" ]]; then
        log_error "GPU_INSTANCE_ID not set in .env"

        if $auto_fix; then
            log_info "Attempting to auto-detect GPU instance..."
            local detected_id=$(detect_gpu_instance "$region")
            if [[ -n "$detected_id" ]]; then
                log_success "Found GPU instance: $detected_id"
                update_env_var "GPU_INSTANCE_ID" "$detected_id"
                export GPU_INSTANCE_ID="$detected_id"
                log_success "Updated .env with GPU_INSTANCE_ID=$detected_id"
                return 0
            else
                log_error "No GPU instances found in region $region"
                return 1
            fi
        fi
        return 1
    fi

    # Verify the instance exists and is a GPU instance
    log_info "Verifying GPU instance: $instance_id"

    local instance_info=$(aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --region "$region" \
        --query 'Reservations[0].Instances[0].[InstanceId,InstanceType,State.Name]' \
        --output text 2>/dev/null)

    if [[ -z "$instance_info" || "$instance_info" == "None"* ]]; then
        log_error "Instance $instance_id not found in region $region"

        if $auto_fix; then
            log_info "Attempting to find correct GPU instance..."
            local detected_id=$(detect_gpu_instance "$region")
            if [[ -n "$detected_id" ]]; then
                log_warn "Found different GPU instance: $detected_id"
                log_info "Updating .env with correct instance ID..."
                update_env_var "GPU_INSTANCE_ID" "$detected_id"
                export GPU_INSTANCE_ID="$detected_id"
                log_success "Updated .env with GPU_INSTANCE_ID=$detected_id"
                return 0
            else
                log_error "No GPU instances found"
                return 1
            fi
        fi
        return 1
    fi

    # Parse instance info
    local actual_id=$(echo "$instance_info" | awk '{print $1}')
    local instance_type=$(echo "$instance_info" | awk '{print $2}')
    local state=$(echo "$instance_info" | awk '{print $3}')

    # Verify it's a GPU instance type
    if [[ ! "$instance_type" =~ ^(g4dn|g5|p3|p4) ]]; then
        log_warn "Instance $actual_id is type $instance_type (not a GPU instance)"

        if $auto_fix; then
            log_info "Looking for GPU instances..."
            local detected_id=$(detect_gpu_instance "$region")
            if [[ -n "$detected_id" && "$detected_id" != "$instance_id" ]]; then
                log_info "Found GPU instance: $detected_id"
                log_info "Updating .env..."
                update_env_var "GPU_INSTANCE_ID" "$detected_id"
                export GPU_INSTANCE_ID="$detected_id"
                log_success "Updated .env with GPU_INSTANCE_ID=$detected_id"
                return 0
            fi
        fi
    fi

    log_success "GPU instance verified: $actual_id ($instance_type, state: $state)"
    return 0
}

# Auto-detect GPU instance in the region
# Returns instance ID or empty string
detect_gpu_instance() {
    local region="${1:-us-east-2}"

    # Look for GPU instances (g4dn, g5, p3, p4 families)
    local gpu_instances=$(aws ec2 describe-instances \
        --region "$region" \
        --filters "Name=instance-type,Values=g4dn.*,g5.*,p3.*,p4.*" \
        --query 'Reservations[*].Instances[?State.Name!=`terminated`].[InstanceId,InstanceType,State.Name]' \
        --output text 2>/dev/null)

    if [[ -z "$gpu_instances" ]]; then
        return 1
    fi

    # Count how many GPU instances found
    local count=$(echo "$gpu_instances" | wc -l)

    if [[ $count -eq 1 ]]; then
        # Exactly one GPU instance - use it
        echo "$gpu_instances" | awk '{print $1}'
        return 0
    elif [[ $count -gt 1 ]]; then
        # Multiple GPU instances - show them and pick first one
        log_warn "Multiple GPU instances found:"
        echo "$gpu_instances" | while read -r id type state; do
            log_info "  - $id ($type, $state)"
        done
        log_info "Using first instance: $(echo "$gpu_instances" | head -1 | awk '{print $1}')"
        echo "$gpu_instances" | head -1 | awk '{print $1}'
        return 0
    fi

    return 1
}

# Complete prerequisite validation for Riva scripts
validate_prerequisites() {
    load_and_validate_env
    validate_ssh_connectivity
    validate_riva_env
    echo "✅ Prerequisites validated"
}

# =============================================================================
# SSH AND REMOTE EXECUTION
# =============================================================================

# Execute command on remote GPU instance
run_remote() {
    local SSH_KEY_PATH="$HOME/.ssh/${SSH_KEY_NAME}.pem"
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 -i "$SSH_KEY_PATH" ubuntu@"$GPU_INSTANCE_IP" "$@"
}

# Copy file to remote instance
copy_to_remote() {
    local local_path=$1
    local remote_path=$2
    local SSH_KEY_PATH="$HOME/.ssh/${SSH_KEY_NAME}.pem"
    
    scp -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" "$local_path" ubuntu@"$GPU_INSTANCE_IP":"$remote_path"
}

# =============================================================================
# DOCKER AND RIVA SERVER MANAGEMENT
# =============================================================================

# Get current Riva server container status
get_riva_status() {
    run_remote "sudo docker ps --filter name=riva-server --format '{{.Status}}' 2>/dev/null" || echo "container_not_found"
}

# Check if port is listening using multiple methods
check_port_listening() {
    local port=$1
    
    # Try multiple methods to check port status
    local result=$(run_remote "
        # Try ss first (modern replacement for netstat)
        ss -tulpn 2>/dev/null | grep :${port} && echo 'LISTENING' ||
        # Try lsof if ss fails  
        lsof -i :${port} 2>/dev/null | grep LISTEN && echo 'LISTENING' ||
        # Try netstat if available
        netstat -tulpn 2>/dev/null | grep :${port} | grep LISTEN && echo 'LISTENING' ||
        # Check docker port mapping
        sudo docker port \$(sudo docker ps -q --filter name=riva-server) 2>/dev/null | grep ${port} && echo 'LISTENING' ||
        echo 'NOT_LISTENING'
    ")
    
    [[ "$result" == *"LISTENING"* ]]
}

# Wait for Riva server to be fully ready
wait_for_riva_ready() {
    local max_wait=${1:-180}  # Default 3 minutes
    local wait_interval=10
    local waited=0
    
    echo "   ⏳ Waiting for Riva server to be ready (max ${max_wait}s)..."
    
    while [[ $waited -lt $max_wait ]]; do
        local status=$(get_riva_status)
        
        if [[ "$status" == *"Up"* ]]; then
            if check_port_listening "${RIVA_PORT:-50051}"; then
                echo "   ✅ Riva server is ready! (${waited}s elapsed)"
                return 0
            else
                echo "   ⏳ Container up, waiting for gRPC port... (${waited}s)"
            fi
        elif [[ "$status" == *"Restarting"* ]]; then
            echo "   🔄 Riva server restarting... (${waited}s elapsed)"
        elif [[ "$status" == "container_not_found" ]]; then
            echo "   ❌ Riva container not found"
            return 1
        else
            echo "   ⚠️  Riva status: $status (${waited}s elapsed)"
        fi
        
        sleep $wait_interval
        waited=$((waited + wait_interval))
    done
    
    echo "   ❌ Timeout waiting for Riva server after ${max_wait}s"
    return 1
}

# Analyze Riva logs for diagnostic information
analyze_riva_logs() {
    local log_lines=${1:-20}
    
    echo "   🔍 Analyzing Riva server logs (last $log_lines lines)..."
    local logs=$(run_remote "sudo docker logs --tail $log_lines riva-server 2>&1")
    
    # Check for common issues
    if [[ "$logs" == *"NVIDIA Deep Learning Container License"* ]] && [[ ! "$logs" == *"Riva server listening"* ]]; then
        echo "   ⚠️  Issue: Container stuck at license display"
        echo "   💡 Likely cause: Models not properly downloaded or GPU access issue"
        return 1
    elif [[ "$logs" == *"No such file or directory"* ]]; then
        echo "   ❌ Issue: Missing model files"
        echo "   💡 Run: ./scripts/riva-042-download-models.sh"
        return 1
    elif [[ "$logs" == *"CUDA"* ]] && [[ "$logs" == *"error"* ]]; then
        echo "   ❌ Issue: GPU/CUDA error"
        echo "   💡 Check GPU drivers and availability"
        return 1
    elif [[ "$logs" == *"permission denied"* ]]; then
        echo "   ❌ Issue: Permission problems"
        echo "   💡 Check docker permissions and file ownership"
        return 1
    elif [[ "$logs" == *"Address already in use"* ]]; then
        echo "   ❌ Issue: Port conflict"
        echo "   💡 Another service using port ${RIVA_PORT:-50051}"
        return 1
    elif [[ "$logs" == *"listening"* ]] || [[ "$logs" == *"server started"* ]] || [[ "$logs" == *"ready"* ]]; then
        echo "   ✅ Log analysis: Server appears to be starting normally"
        return 0
    else
        echo "   ⚠️  Log analysis: Unclear startup status"
        echo "   📋 Recent log sample:"
        echo "$logs" | tail -5 | sed 's/^/       /'
        return 1
    fi
}

# Comprehensive Riva health check with recovery
check_riva_health() {
    echo "🏥 Checking Riva Server Health"
    echo "=============================="
    
    local status=$(get_riva_status)
    echo "   📊 Current status: $status"
    
    if [[ "$status" == *"Up"* ]]; then
        echo "   ✅ Riva server container is running"
        
        if check_port_listening "${RIVA_PORT:-50051}"; then
            echo "   ✅ Riva gRPC port ${RIVA_PORT:-50051} is accessible"
            return 0
        else
            echo "   ⏳ Port not yet accessible, waiting..."
            wait_for_riva_ready 60
            return $?
        fi
        
    elif [[ "$status" == *"Restarting"* ]]; then
        echo "   🔄 Riva server is restarting..."
        
        # Analyze logs to understand why it's restarting
        if analyze_riva_logs 50; then
            echo "   ⏳ Logs look okay, waiting for startup to complete..."
            wait_for_riva_ready 180
            return $?
        else
            echo "   🔧 Log analysis detected issues - attempting recovery..."
            
            # Try to break restart loop with fresh start
            echo "   🔄 Stopping container..."
            run_remote "sudo docker stop riva-server" >/dev/null 2>&1 || true
            sleep 5
            
            echo "   🚀 Starting container with fresh logs..."
            run_remote "sudo docker start riva-server" >/dev/null 2>&1 || true
            
            # Wait longer after restart
            wait_for_riva_ready 300  # 5 minutes for model loading
            return $?
        fi
        
    elif [[ "$status" == "container_not_found" ]]; then
        echo "   ❌ Riva container not found"
        echo "   💡 Run: ./scripts/riva-042-download-models.sh"
        return 1
        
    else
        echo "   ❌ Riva server not running: $status"
        echo "   💡 Try: sudo docker restart riva-server"
        return 1
    fi
}

# =============================================================================
# STATUS TRACKING AND PERSISTENCE
# =============================================================================

# Update status in .env file
update_env_status() {
    local key=$1
    local value=$2

    if [[ ! -f .env ]]; then
        echo "❌ .env file not found"
        return 1
    fi

    # Status values typically don't need quotes, but handle empty values safely
    local safe_value
    if [[ -z "$value" ]]; then
        safe_value='""'
    else
        safe_value="$value"
    fi

    if grep -q "^${key}=" .env; then
        sed -i "s|^${key}=.*|${key}=${safe_value}|" .env
    else
        echo "${key}=${safe_value}" >> .env
    fi

    echo "📝 Updated .env: ${key}=${safe_value}"
}

# Update or append environment variable
update_or_append_env() {
    local key=$1
    local value=$2

    if [[ ! -f .env ]]; then
        echo "❌ .env file not found"
        return 1
    fi

    # Handle quoting properly - always quote the value to handle empty strings
    local quoted_value
    if [[ -z "$value" ]]; then
        quoted_value='""'
    else
        quoted_value="\"$value\""
    fi

    if grep -q "^${key}=" .env; then
        sed -i "s|^${key}=.*|${key}=${quoted_value}|" .env
    else
        echo "${key}=${quoted_value}" >> .env
    fi

    echo "📝 Updated .env: ${key}=${quoted_value}"
}

# Check if prerequisite step passed
check_prerequisite_status() {
    local status_key=$1
    local required_value=${2:-"passed"}
    
    if [[ ! -f .env ]]; then
        echo "❌ .env file not found"
        return 1
    fi
    
    local current_value=$(grep "^${status_key}=" .env 2>/dev/null | cut -d'=' -f2)
    
    if [[ "$current_value" == "$required_value" ]]; then
        return 0
    else
        echo "❌ Prerequisite not met: ${status_key} must be '${required_value}' (currently: '${current_value:-unset}')"
        return 1
    fi
}

# =============================================================================
# TEST SCRIPT GENERATION
# =============================================================================

# Create Python test script on remote instance
create_remote_python_test() {
    local script_name=$1
    local script_content=$2
    
    run_remote "
        cd /opt/riva-app
        source venv/bin/activate
        cat > ${script_name} << 'EOF'
${script_content}
EOF
        echo '✅ Created: ${script_name}'
    "
}

# Run Python test script on remote instance
run_remote_python_test() {
    local script_name=$1
    
    run_remote "
        cd /opt/riva-app
        source venv/bin/activate
        python3 ${script_name}
    "
}

# =============================================================================
# EDUCATIONAL AND DIAGNOSTIC FUNCTIONS  
# =============================================================================

# Explain what should happen during Riva startup
explain_riva_startup_process() {
    echo "💡 What Should Happen During Riva Startup:"
    echo "=========================================="
    echo "   1. 📄 Container shows license information"
    echo "   2. 🔧 Riva initializes GPU and loads models"
    echo "   3. 🎯 ASR models (like Parakeet RNNT) get loaded into GPU memory"
    echo "   4. 🌐 gRPC server starts listening on port ${RIVA_PORT:-50051}"
    echo "   5. ✅ Server reports 'ready' and accepts transcription requests"
    echo ""
    echo "   ⏱️  Expected time: 2-5 minutes (depending on model size)"
    echo "   🔍 Common issues:"
    echo "      - Models not downloaded (stuck at license screen)"  
    echo "      - GPU not accessible (CUDA errors)"
    echo "      - Insufficient GPU memory"
    echo "      - Port conflicts"
    echo ""
}

# =============================================================================
# STANDARDIZED SCRIPT STRUCTURE FUNCTIONS
# =============================================================================

# Standard script header
print_script_header() {
    local script_number=$1
    local script_title=$2
    local target_info=$3
    
    echo "🔧 RIVA-${script_number}: ${script_title}"
    echo "$(printf '=%.0s' {1..60})"
    echo "Target: ${target_info}"
    echo "Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo ""
}

# Standard step header
print_step_header() {
    local step_number=$1
    local step_title=$2
    
    echo ""
    echo "📋 Step ${step_number}: ${step_title}"
    echo "$(printf '=%.0s' {1..40})"
}

# Standard success completion
complete_script_success() {
    local script_number=$1
    local status_key=$2
    local next_script=${3:-""}
    
    update_env_status "$status_key" "passed"
    
    echo ""
    echo "🎉 RIVA-${script_number} Complete: Success!"
    echo "$(printf '=%.0s' {1..50})"
    
    if [[ -n "$next_script" ]]; then
        echo "🚀 Next: Run ${next_script}"
    fi
    
    echo "✅ All checks passed successfully!"
}

# Standard failure handling
handle_script_failure() {
    local script_number=$1
    local status_key=$2
    local error_message=$3
    
    update_env_status "$status_key" "failed"
    
    echo ""
    echo "❌ RIVA-${script_number} FAILED: ${error_message}"
    echo "$(printf '=%.0s' {1..50})"
    echo "🔧 Please resolve issues before proceeding"
    
    exit 1
}

# =============================================================================
# CLEANUP AND UTILITIES
# =============================================================================

# Cleanup temporary files on remote instance
cleanup_remote_temp() {
    run_remote "
        cd /opt/riva-app 2>/dev/null || cd /tmp
        rm -f test_*.py generate_*.py *test*.wav *.log.tmp
        echo 'Temporary files cleaned up'
    " 2>/dev/null || true
}

# Show system resource usage on remote instance
show_system_resources() {
    echo "📊 System Resources:"
    run_remote "
        echo '   GPU Status:'
        nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits | awk '{printf \"   GPU: %s%%, Memory: %s/%s MB\\n\", \$1, \$2, \$3}'
        
        echo '   Memory Usage:'
        free -m | awk 'NR==2{printf \"   RAM: %.1f%% (%s/%s MB)\\n\", \$3*100/\$2, \$3, \$2}'
        
        echo '   Disk Usage:'
        df -h /opt | awk 'NR==2{printf \"   Disk: %s (%s used, %s available)\\n\", \$5, \$3, \$4}'
    "
}

# ============================================================================
# Auto-resolve GPU IP from instance ID
# ============================================================================
# Resolves current public IP address from GPU_INSTANCE_ID via AWS API
# Falls back to GPU_INSTANCE_IP from .env if AWS query fails
#
# Returns: Current public IP address
# Exit Code: 0 on success, 1 if no IP could be resolved
resolve_gpu_ip() {
    local ip=""

    # Priority 1: Resolve from instance ID via AWS API
    if [ -n "${GPU_INSTANCE_ID:-}" ]; then
        ip=$(aws ec2 describe-instances \
            --instance-ids "$GPU_INSTANCE_ID" \
            --query 'Reservations[0].Instances[0].PublicIpAddress' \
            --output text \
            --region "${AWS_REGION:-us-east-2}" 2>/dev/null || true)

        # Check if IP is valid (not "None" or empty)
        if [ -n "$ip" ] && [ "$ip" != "None" ]; then
            echo "$ip"
            return 0
        fi
    fi

    # Priority 2: Fallback to .env IP
    if [ -n "${GPU_INSTANCE_IP:-}" ]; then
        echo "${GPU_INSTANCE_IP}"
        return 0
    fi

    # No IP could be resolved
    log_error "Failed to resolve GPU IP: GPU_INSTANCE_ID and GPU_INSTANCE_IP both unavailable"
    return 1
}

export -f resolve_gpu_ip