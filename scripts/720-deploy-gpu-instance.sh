#!/bin/bash
# RIVA-015: Deploy GPU Instance (Deploy-Only)
# Creates a new EC2 GPU instance for Riva ASR deployment
# Version: 2.0.0

set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# Script metadata
SCRIPT_NAME="riva-015-deploy"
SCRIPT_VERSION="2.0.0"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-library.sh"

# ============================================================================
# Configuration
# ============================================================================

# Parse command line arguments
DRY_RUN=false
FORCE=false
SKIP_CONFIRM=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run|--plan)
            DRY_RUN=true
            shift
            ;;
        --force)
            FORCE=true
            SKIP_CONFIRM=true
            shift
            ;;
        --yes|-y)
            SKIP_CONFIRM=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Deploy a new GPU instance for Riva ASR"
            echo ""
            echo "Options:"
            echo "  --dry-run, --plan    Show what would be done without doing it"
            echo "  --force              Force deployment even if instance exists"
            echo "  --yes, -y            Skip confirmation prompts"
            echo "  --help, -h           Show this help message"
            echo ""
            echo "Exit Codes:"
            echo "  0 - Success"
            echo "  1 - Instance already exists"
            echo "  2 - AWS API error"
            echo "  3 - Validation failed"
            echo "  4 - Configuration error"
            echo "  5 - Lock conflict"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# ============================================================================
# Helper Functions from Original Script
# ============================================================================

# Function to get latest Deep Learning AMI
get_latest_dl_ami() {
    local region="$1"
    aws ec2 describe-images \
        --owners amazon \
        --filters \
            'Name=name,Values=Deep Learning AMI GPU PyTorch*Ubuntu*' \
            'Name=state,Values=available' \
        --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
        --output text \
        --region "$region"
}

# Function to create user data script
create_user_data() {
    cat << 'EOF'
#!/bin/bash
set -e

# Log all output
exec > >(tee -a /var/log/user-data.log)
exec 2>&1

echo "Starting user data script at $(date)"

# Update system
echo "Updating system packages..."
apt-get update || true
apt-get install -y htop nvtop git python3-pip docker.io || true

# Add ubuntu user to docker group
usermod -aG docker ubuntu || true

# Install Docker Compose
echo "Installing Docker Compose..."
curl -L "https://github.com/docker/compose/releases/download/v2.20.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Clean up any existing NVIDIA repository configurations
echo "Cleaning up existing NVIDIA repositories..."
rm -f /etc/apt/sources.list.d/nvidia-container*
rm -f /usr/share/keyrings/nvidia-container*

# Install NVIDIA Container Toolkit (fixed version)
echo "Installing NVIDIA Container Toolkit..."
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

# Create the repository file correctly
cat > /etc/apt/sources.list.d/nvidia-container-toolkit.list <<NVIDIA_REPO
deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://nvidia.github.io/libnvidia-container/stable/ubuntu20.04/\$(ARCH) /
NVIDIA_REPO

# Update and install
apt-get update || true
apt-get install -y nvidia-container-toolkit || true

# Configure Docker for NVIDIA runtime
echo "Configuring Docker for NVIDIA runtime..."
nvidia-ctk runtime configure --runtime=docker || true
systemctl restart docker || true

# Verify Docker and NVIDIA runtime
docker info | grep nvidia || echo "NVIDIA runtime not detected yet"

# Create directories
echo "Creating Riva directories..."
mkdir -p /opt/whisperlive/{logs,models,certs,config}
chown -R ubuntu:ubuntu /opt/whisperlive

# Mark initialization complete
echo "$(date): GPU instance initialization complete" > /opt/whisperlive/init-complete
echo "User data script completed at $(date)"
EOF
}

# ============================================================================
# Main Function
# ============================================================================

deploy_instance() {
    # Initialize logging
    init_log "$SCRIPT_NAME"

    echo -e "${BLUE}🚀 GPU Instance Deploy Script v${SCRIPT_VERSION}${NC}"
    echo "================================================"

    # Load environment
    if ! load_env_or_fail; then
        exit 4
    fi

    # Check if this is AWS deployment strategy
    if [ "${DEPLOYMENT_STRATEGY:-1}" != "1" ]; then
        json_log "$SCRIPT_NAME" "validate" "warn" "Not AWS deployment strategy" \
            "strategy=${DEPLOYMENT_STRATEGY}"
        print_status "warn" "Skipping GPU instance deployment (Strategy: ${DEPLOYMENT_STRATEGY})"
        echo "This script is only for AWS EC2 deployment (Strategy 1)"
        exit 0
    fi

    # Validate AWS configuration
    if [ -z "${AWS_REGION:-}" ] || [ -z "${AWS_ACCOUNT_ID:-}" ] || [ -z "${GPU_INSTANCE_TYPE:-}" ] || [ -z "${SSH_KEY_NAME:-}" ]; then
        json_log "$SCRIPT_NAME" "validate" "error" "Missing AWS configuration"
        print_status "error" "Missing AWS configuration in .env file"
        exit 4
    fi

    # Check for existing instance
    local existing_instance_id=$(get_instance_id)
    if [ -n "$existing_instance_id" ] && [ "$FORCE" = "false" ]; then
        local existing_state=$(get_instance_state "$existing_instance_id")

        if [ "$existing_state" != "none" ]; then
            json_log "$SCRIPT_NAME" "validate" "error" "Instance already exists" \
                "instance_id=$existing_instance_id" \
                "state=$existing_state"

            print_status "error" "Instance already exists: $existing_instance_id"
            echo "Current state: $existing_state"
            echo ""
            echo "Options:"
            echo "  • Use --force to deploy anyway (not recommended)"
            echo "  • Use riva-016-start-gpu-instance.sh if instance is stopped"
            echo "  • Use riva-018-status-gpu-instance.sh to check status"
            echo "  • Use riva-999-destroy-all.sh to remove existing instance"
            exit 1
        fi
    fi

    # Set defaults for EBS configuration
    EBS_VOLUME_SIZE=${EBS_VOLUME_SIZE:-200}
    EBS_VOLUME_TYPE=${EBS_VOLUME_TYPE:-gp3}

    # Show configuration
    echo ""
    echo -e "${CYAN}Deployment Configuration:${NC}"
    echo "  • AWS Region: ${AWS_REGION}"
    echo "  • Account ID: ${AWS_ACCOUNT_ID}"
    echo "  • Instance Type: ${GPU_INSTANCE_TYPE}"
    echo "  • SSH Key: ${SSH_KEY_NAME}"
    echo "  • EBS Volume: ${EBS_VOLUME_SIZE}GB (${EBS_VOLUME_TYPE})"
    echo "  • Deployment ID: ${DEPLOYMENT_ID}"

    # Cost estimate
    local hourly_rate=$(get_instance_hourly_rate "${GPU_INSTANCE_TYPE}")
    local daily_cost=$(echo "scale=2; $hourly_rate * 24" | bc)
    local monthly_cost=$(echo "scale=2; $hourly_rate * 24 * 30" | bc)

    echo ""
    echo -e "${YELLOW}💰 Cost Estimate:${NC}"
    echo "  • Hourly: \$$hourly_rate"
    echo "  • Daily (24/7): \$$daily_cost"
    echo "  • Monthly (24/7): \$$monthly_cost"

    # Confirmation prompt
    if [ "$SKIP_CONFIRM" = "false" ] && [ "$DRY_RUN" = "false" ]; then
        echo ""
        echo -e "${YELLOW}⚠️  This will create a new GPU instance${NC}"
        echo -n "Continue with deployment? [y/N]: "
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            json_log "$SCRIPT_NAME" "confirm" "warn" "User cancelled deployment"
            echo "Deployment cancelled."
            exit 0
        fi
    fi

    # Dry run check
    if [ "$DRY_RUN" = "true" ]; then
        echo ""
        echo -e "${YELLOW}🔸 DRY RUN MODE - No changes will be made${NC}"
        echo ""
        echo "Would perform:"
        echo "  1. Create/reuse security group"
        echo "  2. Create/reuse SSH key pair"
        echo "  3. Find latest Deep Learning AMI"
        echo "  4. Launch EC2 instance with user data"
        echo "  5. Wait for instance to be running"
        echo "  6. Update .env configuration"
        echo "  7. Run initial health checks"

        json_log "$SCRIPT_NAME" "dry_run" "ok" "Dry run completed"
        exit 0
    fi

    # Start deployment
    echo ""
    echo -e "${BLUE}🚀 Starting deployment...${NC}"

    # Step 1: Ensure SSH key exists
    echo -e "${BLUE}🔑 Setting up SSH key...${NC}"
    local ssh_key_path="$HOME/.ssh/${SSH_KEY_NAME}.pem"

    if [ -f "$ssh_key_path" ]; then
        # Local key exists - use it
        print_status "ok" "Using existing SSH key: $ssh_key_path"
    else
        # Check if key exists in AWS but not locally
        local key_exists=$(aws ec2 describe-key-pairs \
            --key-names "${SSH_KEY_NAME}" \
            --region "${AWS_REGION}" \
            --query 'KeyPairs[0].KeyName' \
            --output text 2>/dev/null || echo "None")

        if [ "$key_exists" != "None" ] && [ "$key_exists" != "null" ]; then
            # Key exists in AWS but not locally - ERROR
            echo ""
            print_status "error" "AWS key pair '${SSH_KEY_NAME}' exists but local file not found at: $ssh_key_path"
            echo ""
            echo -e "${YELLOW}Choose one of the following options:${NC}"
            echo ""
            echo -e "  ${CYAN}1. Copy existing key to expected location:${NC}"
            echo "     cp /path/to/your/${SSH_KEY_NAME}.pem $ssh_key_path"
            echo "     chmod 400 $ssh_key_path"
            echo ""
            echo -e "  ${CYAN}2. Delete AWS key pair to allow recreation:${NC}"
            echo "     aws ec2 delete-key-pair --key-name ${SSH_KEY_NAME} --region ${AWS_REGION}"
            echo "     Then re-run this script"
            echo ""
            echo -e "  ${CYAN}3. Update SSH_KEY_NAME in .env to a new value:${NC}"
            echo "     Example: SSH_KEY_NAME=riva-key-$(date +%Y%m%d)"
            echo "     Then re-run this script"
            echo ""
            json_log "$SCRIPT_NAME" "ssh_key" "error" "Key exists in AWS but not locally" \
                "key_name=${SSH_KEY_NAME},local_path=$ssh_key_path"
            exit 1
        else
            # Key doesn't exist anywhere - create it
            json_log "$SCRIPT_NAME" "ssh_key" "ok" "Creating new SSH key pair" \
                "key_name=${SSH_KEY_NAME}"

            aws ec2 create-key-pair \
                --key-name "${SSH_KEY_NAME}" \
                --query 'KeyMaterial' \
                --output text \
                --region "${AWS_REGION}" > "$ssh_key_path"

            chmod 400 "$ssh_key_path"
            print_status "ok" "Created SSH key: $ssh_key_path"
        fi
    fi

    # Step 2: Ensure security group exists
    echo -e "${BLUE}🔒 Setting up security group...${NC}"
    local sg_id=$(ensure_security_group "riva-asr-sg-${DEPLOYMENT_ID}" "Security group for NVIDIA Parakeet Riva ASR server")

    # Add additional rules for our deployment
    echo "Configuring security group rules..."

    # RIVA gRPC port
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port "${RIVA_PORT:-50051}" \
        --cidr 0.0.0.0/0 \
        --region "${AWS_REGION}" &>/dev/null || true

    # RIVA HTTP port
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port "${RIVA_HTTP_PORT:-8000}" \
        --cidr 0.0.0.0/0 \
        --region "${AWS_REGION}" &>/dev/null || true

    # WebSocket app port
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port "${APP_PORT:-8443}" \
        --cidr 0.0.0.0/0 \
        --region "${AWS_REGION}" &>/dev/null || true

    # Step 3: Get AMI
    echo -e "${BLUE}🔍 Finding Deep Learning AMI...${NC}"
    local ami_id=$(get_latest_dl_ami "${AWS_REGION}")

    if [ -z "$ami_id" ] || [ "$ami_id" = "None" ]; then
        json_log "$SCRIPT_NAME" "ami" "error" "Failed to find suitable AMI"
        print_status "error" "Failed to find suitable Deep Learning AMI"
        exit 2
    fi

    json_log "$SCRIPT_NAME" "ami" "ok" "Using AMI" "ami_id=$ami_id"
    echo "Using AMI: $ami_id"

    # Step 4: Create user data
    echo -e "${BLUE}📝 Preparing user data...${NC}"
    local user_data_file="/tmp/riva-user-data-$(date +%s).sh"
    create_user_data > "$user_data_file"

    # Step 5: Launch instance
    echo -e "${BLUE}🎯 Launching EC2 instance...${NC}"
    local launch_time=$(date +%s)

    local instance_id=$(aws ec2 run-instances \
        --image-id "$ami_id" \
        --count 1 \
        --instance-type "${GPU_INSTANCE_TYPE}" \
        --key-name "${SSH_KEY_NAME}" \
        --security-group-ids "$sg_id" \
        --user-data "file://$user_data_file" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=riva-asr-${DEPLOYMENT_ID}},{Key=Purpose,Value=ParakeetRivaASR},{Key=DeploymentId,Value=${DEPLOYMENT_ID}},{Key=CreatedBy,Value=riva-deployment-script-v2}]" \
        --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":'${EBS_VOLUME_SIZE}',"VolumeType":"'${EBS_VOLUME_TYPE}'","DeleteOnTermination":true}}]' \
        --query 'Instances[0].InstanceId' \
        --output text \
        --region "${AWS_REGION}")

    if [ -z "$instance_id" ]; then
        json_log "$SCRIPT_NAME" "launch" "error" "Failed to launch instance"
        print_status "error" "Failed to launch instance"
        exit 2
    fi

    json_log "$SCRIPT_NAME" "launch" "ok" "Instance launched" \
        "instance_id=$instance_id"

    print_status "ok" "Instance launched: $instance_id"

    # Step 6: Wait for running state
    echo -e "${YELLOW}⏳ Waiting for instance to be running...${NC}"
    aws ec2 wait instance-running \
        --instance-ids "$instance_id" \
        --region "${AWS_REGION}"

    # Step 7: Get IP address
    echo -e "${BLUE}🔄 Retrieving network information...${NC}"
    local public_ip=$(get_instance_ip "$instance_id")
    local private_ip=$(aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].PrivateIpAddress' \
        --output text \
        --region "${AWS_REGION}")

    if [ -z "$public_ip" ]; then
        json_log "$SCRIPT_NAME" "network" "error" "Failed to get public IP"
        print_status "error" "Failed to retrieve public IP address"
        exit 2
    fi

    # Step 8: Update configuration files
    echo -e "${BLUE}📝 Updating configuration...${NC}"

    # Update .env file
    # NOTE: Instance ID is permanent, IPs are temporary (change on every stop/start)
    update_env_file "GPU_INSTANCE_ID" "$instance_id"
    update_env_file "SECURITY_GROUP_ID" "$sg_id"

    # IP addresses written for immediate use only (will become stale on next reboot)
    # All scripts should use dynamic IP lookup via get_instance_ip()
    update_env_file "GPU_INSTANCE_IP" "$public_ip"  # Deprecated - use GPU_INSTANCE_ID
    update_env_file "GPU_HOST" "$public_ip"          # Deprecated - use GPU_INSTANCE_ID
    update_env_file "RIVA_HOST" "$public_ip"         # Deprecated - use GPU_INSTANCE_ID

    echo "  ⚠️  Note: IP addresses stored for immediate use only"
    echo "     All scripts use dynamic IP lookup from GPU_INSTANCE_ID"

    # Write instance facts
    write_instance_facts "$instance_id" "${GPU_INSTANCE_TYPE}" "$ami_id" "$sg_id" "${SSH_KEY_NAME}"

    # Write state cache
    write_state_cache "$instance_id" "running" "$public_ip" "$private_ip"

    # Start cost tracking
    update_cost_metrics "start" "${GPU_INSTANCE_TYPE}"

    # Step 9: Wait for SSH and initial health checks
    echo -e "${BLUE}🏥 Running initial health checks...${NC}"

    echo -n "  • SSH connectivity: "
    local ssh_attempts=0
    local max_ssh_attempts=30

    while [ $ssh_attempts -lt $max_ssh_attempts ]; do
        if validate_ssh_connectivity "$public_ip" "$ssh_key_path"; then
            print_status "ok" "Connected"
            break
        fi
        sleep 10
        ssh_attempts=$((ssh_attempts + 1))
    done

    if [ $ssh_attempts -eq $max_ssh_attempts ]; then
        print_status "warn" "SSH timeout (instance may still be initializing)"
    fi

    # Wait for cloud-init if SSH is working
    if [ $ssh_attempts -lt $max_ssh_attempts ]; then
        echo -n "  • Cloud-init: "
        if wait_for_cloud_init "$public_ip" "$ssh_key_path" 300; then
            print_status "ok" "Completed"
        else
            print_status "warn" "Timeout (may still be running)"
        fi

        echo -n "  • GPU availability: "
        if check_gpu_availability "$public_ip" "$ssh_key_path"; then
            print_status "ok" "GPU detected"
        else
            print_status "warn" "GPU check failed (may need time to initialize)"
        fi
    fi

    # Calculate deployment time
    local total_time=$(($(date +%s) - launch_time))

    json_log "$SCRIPT_NAME" "complete" "ok" "Deployment completed successfully" \
        "instance_id=$instance_id" \
        "public_ip=$public_ip" \
        "total_duration_ms=$((total_time * 1000))"

    # Clean up
    rm -f "$user_data_file"

    # Success summary
    echo ""
    echo -e "${GREEN}✅ GPU Instance Deployed Successfully!${NC}"
    echo "================================================"
    echo "Instance ID: $instance_id"
    echo "Public IP: $public_ip"
    echo "Instance Type: ${GPU_INSTANCE_TYPE}"
    echo "SSH Access: ssh -i $ssh_key_path ubuntu@$public_ip"
    echo "Deployment Time: $(format_duration $total_time)"
    echo ""

    # Show next steps
    echo -e "${CYAN}Next Steps:${NC}"
    if [ "${USE_RIVA_DEPLOYMENT:-false}" = "true" ]; then
        echo "1. Setup RIVA server: ./scripts/riva-070-setup-traditional-riva-server.sh"
        echo "2. Start RIVA server: ./scripts/riva-085-start-traditional-riva-server.sh"
    elif [ "${USE_NIM_DEPLOYMENT:-false}" = "true" ]; then
        echo "1. Setup NIM container: ./scripts/riva-062-deploy-nim-from-s3.sh"
    else
        echo "1. Configure services: ./scripts/riva-007-discover-s3-models.sh"
    fi
    echo "2. Check status: ./scripts/riva-018-status-gpu-instance.sh"
    echo "3. Stop to save costs: ./scripts/riva-017-stop-gpu-instance.sh"
}

# ============================================================================
# Execute with lock
# ============================================================================

if [ "$FORCE" = "true" ]; then
    deploy_instance
else
    with_lock deploy_instance
fi