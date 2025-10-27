#!/bin/bash
# Note: NOT using 'set -e' to allow proper error handling in AWS operations
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ==================================================================
# 031: Configure Edge Box Security Groups (Client Management)
# ==================================================================
# Manages client access to edge box web services.
# Interactive menu to add/remove/list authorized client IPs.
#
# DEFAULT: WhisperLive deployment (ports 80, 443)
# LEGACY: Use --riva flag for NVIDIA Riva deployment (ports 8443, 8444)
#
# Security Model:
#   Edge Box = Public-facing with explicit IP allowlist
#
# Client Storage:
#   authorized_clients.txt - Persistent list of authorized clients
#
# Usage:
#   ./scripts/031-configure-edge-box-security.sh           # WhisperLive (default)
#   ./scripts/031-configure-edge-box-security.sh --riva    # NVIDIA Riva (legacy)
# ==================================================================

# Find repository root (works from symlink or direct execution)
if [ -L "${BASH_SOURCE[0]}" ]; then
    SCRIPT_REAL=$(readlink -f "${BASH_SOURCE[0]}")
else
    SCRIPT_REAL="${BASH_SOURCE[0]}"
fi
REPO_ROOT="$(cd "$(dirname "$SCRIPT_REAL")/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"
CLIENTS_FILE="$REPO_ROOT/authorized_clients.txt"

# Parse command line arguments
DEPLOYMENT_MODE="whisperlive"  # Default
if [ "${1:-}" == "--riva" ]; then
    DEPLOYMENT_MODE="riva"
fi

# Source common functions
source "$REPO_ROOT/scripts/lib/common-functions.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

echo -e "${BLUE}🔒 Edge Box Security Group Configuration (Client Management)${NC}"
echo "================================================================"
echo ""
if [ "$DEPLOYMENT_MODE" == "riva" ]; then
    echo -e "${YELLOW}MODE: NVIDIA Riva (Legacy)${NC}"
    echo ""
    echo -e "${CYAN}Security Model:${NC}"
    echo "  Build Box: PUBLIC-FACING with explicit client allowlist"
    echo "  Ports: 22 (SSH), 8443 (WebSocket Bridge), 8444 (HTTPS Demo)"
else
    echo -e "${GREEN}MODE: WhisperLive (Default)${NC}"
    echo ""
    echo -e "${CYAN}Security Model:${NC}"
    echo "  Edge Box: PUBLIC-FACING with explicit client allowlist"
    echo "  Ports: 22 (SSH), 80 (HTTP), 443 (HTTPS Caddy Proxy)"
fi
echo "  GPU Access: Use script 030 to configure GPU security"
echo "================================================================"
echo ""

# Load configuration
if [ ! -f "$ENV_FILE" ]; then
    log_error "Configuration file not found: $ENV_FILE"
    exit 1
fi

source "$ENV_FILE"

# Validate and auto-detect BUILDBOX_SECURITY_GROUP if not set
# (Variable name kept for backward compatibility)
if [ -z "$BUILDBOX_SECURITY_GROUP" ]; then
    log_warn "BUILDBOX_SECURITY_GROUP not set in .env"
    echo ""
    echo -e "${CYAN}Auto-detecting edge box security group...${NC}"

    # Try to get instance ID from metadata service (supports both IMDSv1 and IMDSv2)
    # Try IMDSv2 first (token-based)
    TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" --max-time 5 2>/dev/null || echo "")

    if [ -n "$TOKEN" ]; then
        # IMDSv2 available
        INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id --max-time 5 2>/dev/null || echo "")
    else
        # Fallback to IMDSv1
        INSTANCE_ID=$(curl -s --max-time 5 http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo "")
    fi

    if [ -z "$INSTANCE_ID" ]; then
        log_error "Failed to detect instance ID (not running on EC2?)"
        echo ""
        echo "Please manually add BUILDBOX_SECURITY_GROUP to .env:"
        echo "  INSTANCE_ID=\$(curl -s http://169.254.169.254/latest/meta-data/instance-id)"
        echo "  aws ec2 describe-instances --instance-ids \$INSTANCE_ID --region ${AWS_REGION:-us-east-2} \\"
        echo "    --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text"
        exit 1
    fi

    # Get security group ID from AWS
    DETECTED_SG=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --region "${AWS_REGION:-us-east-2}" \
        --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' \
        --output text 2>/dev/null || echo "")

    if [ -z "$DETECTED_SG" ] || [ "$DETECTED_SG" == "None" ]; then
        log_error "Failed to detect security group for instance $INSTANCE_ID"
        echo "Please check AWS credentials and region configuration."
        exit 1
    fi

    log_success "Detected security group: $DETECTED_SG"
    echo ""

    # Offer to save to .env
    read -p "Save this to .env file? (Y/n): " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        # Add to .env file
        if grep -q "^BUILDBOX_SECURITY_GROUP=" "$ENV_FILE"; then
            # Update existing line
            sed -i "s|^BUILDBOX_SECURITY_GROUP=.*|BUILDBOX_SECURITY_GROUP=$DETECTED_SG|" "$ENV_FILE"
        else
            # Add new line
            echo "" >> "$ENV_FILE"
            echo "# Build Box Security Group (auto-detected)" >> "$ENV_FILE"
            echo "BUILDBOX_SECURITY_GROUP=$DETECTED_SG" >> "$ENV_FILE"
        fi
        log_success "Saved BUILDBOX_SECURITY_GROUP to .env"

        # Reload .env
        source "$ENV_FILE"
    fi

    # Use detected value
    BUILDBOX_SECURITY_GROUP="$DETECTED_SG"
    echo ""
fi

if [ -z "$AWS_REGION" ]; then
    log_error "AWS_REGION not set in .env"
    exit 1
fi

# Auto-detect build box public IP if not set
if [ -z "$BUILDBOX_PUBLIC_IP" ]; then
    DETECTED_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || \
                  curl -s --max-time 5 icanhazip.com 2>/dev/null || \
                  echo "")

    if [ -n "$DETECTED_IP" ]; then
        log_info "Auto-detected build box IP: $DETECTED_IP"

        # Offer to save to .env
        read -p "Save this to .env file? (Y/n): " -n 1 -r
        echo

        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            if grep -q "^BUILDBOX_PUBLIC_IP=" "$ENV_FILE"; then
                sed -i "s|^BUILDBOX_PUBLIC_IP=.*|BUILDBOX_PUBLIC_IP=$DETECTED_IP|" "$ENV_FILE"
            else
                echo "" >> "$ENV_FILE"
                echo "# Build Box Public IP (auto-detected)" >> "$ENV_FILE"
                echo "BUILDBOX_PUBLIC_IP=$DETECTED_IP" >> "$ENV_FILE"
            fi
            log_success "Saved BUILDBOX_PUBLIC_IP to .env"
            source "$ENV_FILE"
        fi

        BUILDBOX_PUBLIC_IP="$DETECTED_IP"
        echo ""
    fi
fi

# Edge box configuration based on deployment mode
EDGE_BOX_SG="$BUILDBOX_SECURITY_GROUP"  # Variable name kept for backward compatibility

if [ "$DEPLOYMENT_MODE" == "riva" ]; then
    EDGE_BOX_PORTS=(22 8443 8444)
    EDGE_BOX_PORT_DESCRIPTIONS=("SSH" "WebSocket Bridge (WSS)" "HTTPS Demo Server")
    EDGE_BOX_NAME="Build Box"
else
    EDGE_BOX_PORTS=(22 80 443)
    EDGE_BOX_PORT_DESCRIPTIONS=("SSH" "HTTP (redirects to HTTPS)" "HTTPS Caddy Proxy")
    EDGE_BOX_NAME="Edge Box"
fi

echo -e "${CYAN}Configuration:${NC}"
echo "  Deployment Mode: $DEPLOYMENT_MODE"
echo "  $EDGE_BOX_NAME Security Group: $EDGE_BOX_SG"
echo "  $EDGE_BOX_NAME IP: ${BUILDBOX_PUBLIC_IP:-<not set>}"
echo "  AWS Region: $AWS_REGION"
echo "  Ports: ${EDGE_BOX_PORTS[*]}"
echo "  Client File: $CLIENTS_FILE"
echo ""

# ==================================================================
# Client File Management Functions
# ==================================================================

# Initialize clients file if it doesn't exist
init_clients_file() {
    if [ ! -f "$CLIENTS_FILE" ]; then
        cat > "$CLIENTS_FILE" <<'EOF'
# Authorized Clients for Build Box Access
# Format: IP_ADDRESS LABEL
# Example:
#   136.62.92.204 macbook
#   192.168.1.100 office-laptop
#   10.0.1.50 phone

EOF
        log_info "Created new clients file: $CLIENTS_FILE"
    fi
}

# Load clients from file
load_clients() {
    local -n clients_array=$1
    local -n labels_array=$2

    clients_array=()
    labels_array=()

    if [ ! -f "$CLIENTS_FILE" ]; then
        return
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        # Skip comments and empty lines
        [[ "$line" =~ ^#.*$ ]] && continue
        [[ -z "$line" ]] && continue

        # Parse IP and label
        local ip=$(echo "$line" | awk '{print $1}')
        local label=$(echo "$line" | awk '{print $2}')

        if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            clients_array+=("$ip")
            labels_array+=("${label:-unknown}")
        fi
    done < "$CLIENTS_FILE"
}

# Save clients to file
save_clients() {
    local -n clients_array=$1
    local -n labels_array=$2

    cat > "$CLIENTS_FILE" <<'EOF'
# Authorized Clients for Build Box Access
# Format: IP_ADDRESS LABEL
# DO NOT edit manually while script is running

EOF

    for i in "${!clients_array[@]}"; do
        echo "${clients_array[$i]} ${labels_array[$i]}" >> "$CLIENTS_FILE"
    done

    log_success "Saved ${#clients_array[@]} clients to $CLIENTS_FILE"
}

# ==================================================================
# AWS Security Group Functions
# ==================================================================

# Add IP to all edge box ports
add_ip_to_aws() {
    local ip=$1
    local label=$2

    echo -n "  Adding $ip ($label) to AWS..."

    local added=0
    local existed=0

    for port in "${EDGE_BOX_PORTS[@]}"; do
        RESULT=$(aws ec2 authorize-security-group-ingress \
            --region "$AWS_REGION" \
            --group-id "$EDGE_BOX_SG" \
            --protocol tcp \
            --port "$port" \
            --cidr "${ip}/32" 2>&1)

        if echo "$RESULT" | grep -q "already exists"; then
            ((existed++))
        elif echo "$RESULT" | grep -q "Success\|^$"; then
            ((added++))
        fi
    done

    # Show clearer message based on what happened
    if [ $added -gt 0 ] && [ $existed -eq 0 ]; then
        # All ports were new
        echo -e " ${GREEN}added (all $added ports)${NC}"
    elif [ $added -gt 0 ] && [ $existed -gt 0 ]; then
        # Some ports were new, some existed
        echo -e " ${GREEN}added ($added port(s))${NC}${YELLOW}, $existed already existed${NC}"
    elif [ $existed -gt 0 ]; then
        # All ports already existed
        echo -e " ${YELLOW}already exists (all $existed ports)${NC}"
    else
        # Something went wrong
        echo -e " ${RED}failed${NC}"
    fi
}

# Remove IP from all edge box ports
remove_ip_from_aws() {
    local ip=$1

    echo -n "  Removing $ip from AWS..."

    local removed=0
    local failed=0
    local not_found=0

    for port in "${EDGE_BOX_PORTS[@]}"; do
        RESULT=$(aws ec2 revoke-security-group-ingress \
            --region "$AWS_REGION" \
            --group-id "$EDGE_BOX_SG" \
            --protocol tcp \
            --port "$port" \
            --cidr "${ip}/32" 2>&1)
        EXIT_CODE=$?

        if [ $EXIT_CODE -eq 0 ]; then
            removed=$((removed + 1))
        elif echo "$RESULT" | grep -qi "not found\|does not exist\|InvalidPermission\.NotFound"; then
            not_found=$((not_found + 1))
        else
            failed=$((failed + 1))
            echo "" >&2
            echo "    Error on port $port: $RESULT" >&2
        fi
    done

    local total_ports=${#EDGE_BOX_PORTS[@]}

    # Show clearer message based on what happened
    if [ $removed -eq $total_ports ]; then
        # All ports removed successfully
        echo -e " ${GREEN}removed (all $removed ports)${NC}"
    elif [ $removed -gt 0 ]; then
        # Some removed, some failed or not found
        echo -e " ${GREEN}removed ($removed port(s))${NC}"
        [ $not_found -gt 0 ] && echo -e "    ${YELLOW}Note: $not_found port(s) not found${NC}"
        [ $failed -gt 0 ] && echo -e "    ${RED}Warning: $failed port(s) failed${NC}"
    elif [ $not_found -gt 0 ]; then
        # All ports not found
        echo -e " ${YELLOW}not found (rules don't exist)${NC}"
    else
        # All failed
        echo -e " ${RED}failed${NC}"
    fi
}

# List current AWS security group rules
list_aws_rules() {
    echo -e "${CYAN}Current AWS Security Group Rules:${NC}"
    echo "================================================================"

    RULES=$(aws ec2 describe-security-groups \
        --region "$AWS_REGION" \
        --group-ids "$BUILDBOX_SG" \
        --query 'SecurityGroups[0].IpPermissions[]' \
        --output json 2>/dev/null)

    if [ -z "$RULES" ] || [ "$RULES" == "[]" ]; then
        echo "  (no rules configured)"
    else
        echo "$RULES" | jq -r '.[] | {port: .FromPort, cidrs: .IpRanges[].CidrIp} | "\(.port) \(.cidrs)"' | \
            sort -n | awk 'BEGIN {
                print "  PORT     SOURCE"
                print "  ───────────────────────────────"
            } { printf "  %-8s %s\n", $1, $2 }'
    fi
    echo ""
}

# ==================================================================
# Interactive Menu Functions
# ==================================================================

# List all authorized clients
list_clients_menu() {
    local -a clients
    local -a labels
    load_clients clients labels

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}Authorized Clients${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"

    if [ ${#clients[@]} -eq 0 ]; then
        echo "  No clients configured"
    else
        echo ""
        printf "  %-3s %-18s %s\n" "#" "IP ADDRESS" "LABEL"
        echo "  ───────────────────────────────────────────────────────"

        for i in "${!clients[@]}"; do
            printf "  %-3s %-18s %s\n" "$((i+1))" "${clients[$i]}" "${labels[$i]}"
        done
    fi

    echo ""
    echo "Total: ${#clients[@]} client(s)"
    echo ""
}

# Add new client
add_client_menu() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}Add New Client${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo ""

    # Get IP address
    while true; do
        read -p "Enter client IP address (or 'cancel' to abort): " new_ip

        if [ "$new_ip" == "cancel" ]; then
            log_info "Add client cancelled"
            return
        fi

        if [[ ! "$new_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo -e "${RED}Invalid IP format. Please use XXX.XXX.XXX.XXX${NC}"
            continue
        fi

        break
    done

    # Get label
    read -p "Enter label for this client (e.g., 'macbook', 'office'): " new_label
    new_label=${new_label:-"client"}

    # Check if IP already exists
    local -a clients
    local -a labels
    load_clients clients labels

    for existing_ip in "${clients[@]}"; do
        if [ "$existing_ip" == "$new_ip" ]; then
            log_warn "IP $new_ip already exists in authorized clients"
            read -p "Update label? (y/N): " -n 1 -r
            echo

            if [[ $REPLY =~ ^[Yy]$ ]]; then
                # Update label
                for i in "${!clients[@]}"; do
                    if [ "${clients[$i]}" == "$new_ip" ]; then
                        labels[$i]="$new_label"
                    fi
                done
                save_clients clients labels
                log_success "Updated label for $new_ip to '$new_label'"
            fi
            return
        fi
    done

    # Add to AWS
    echo ""
    add_ip_to_aws "$new_ip" "$new_label"

    # Add to file
    clients+=("$new_ip")
    labels+=("$new_label")
    save_clients clients labels

    echo ""
    log_success "Client added: $new_ip ($new_label)"
}

# Remove client
remove_client_menu() {
    local -a clients
    local -a labels
    load_clients clients labels

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}Remove Client${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo ""

    if [ ${#clients[@]} -eq 0 ]; then
        log_warn "No clients to remove"
        return
    fi

    # List clients
    printf "  %-3s %-18s %s\n" "#" "IP ADDRESS" "LABEL"
    echo "  ───────────────────────────────────────────────────────"

    for i in "${!clients[@]}"; do
        printf "  %-3s %-18s %s\n" "$((i+1))" "${clients[$i]}" "${labels[$i]}"
    done

    echo ""
    read -p "Enter client number to remove (or 'cancel' to abort): " selection

    if [ "$selection" == "cancel" ]; then
        log_info "Remove client cancelled"
        return
    fi

    # Validate selection
    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt ${#clients[@]} ]; then
        log_error "Invalid selection: $selection"
        return
    fi

    local idx=$((selection - 1))
    local ip_to_remove="${clients[$idx]}"
    local label_to_remove="${labels[$idx]}"

    # Confirm
    echo ""
    log_warn "Will remove: $ip_to_remove ($label_to_remove)"
    read -p "Confirm removal? (y/N): " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Removal cancelled"
        return
    fi

    # Remove from AWS
    echo ""
    remove_ip_from_aws "$ip_to_remove"

    # Remove from arrays
    unset clients[$idx]
    unset labels[$idx]
    clients=("${clients[@]}")  # Reindex
    labels=("${labels[@]}")    # Reindex

    save_clients clients labels

    echo ""
    log_success "Client removed: $ip_to_remove ($label_to_remove)"
}

# Sync clients file to AWS
sync_clients_to_aws() {
    local -a clients
    local -a labels
    load_clients clients labels

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}Sync Clients to AWS${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo ""

    if [ ${#clients[@]} -eq 0 ]; then
        log_warn "No clients in file to sync"
        return
    fi

    log_info "Syncing ${#clients[@]} clients to AWS security group..."
    echo ""

    for i in "${!clients[@]}"; do
        add_ip_to_aws "${clients[$i]}" "${labels[$i]}"
    done

    echo ""
    log_success "Sync complete"
}

# ==================================================================
# Main Menu
# ==================================================================

show_main_menu() {
    echo ""
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${MAGENTA}Build Box Client Management Menu${NC}"
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  1) List authorized clients"
    echo "  2) Add new client"
    echo "  3) Remove client"
    echo "  4) Show current AWS security group rules"
    echo "  5) Sync clients file to AWS"
    echo "  6) Exit"
    echo ""
}

# ==================================================================
# Main Execution
# ==================================================================

# Initialize clients file
init_clients_file

# Main loop
while true; do
    show_main_menu
    read -p "Enter choice [1-6]: " choice

    case $choice in
        1)
            list_clients_menu
            ;;
        2)
            add_client_menu
            ;;
        3)
            remove_client_menu
            ;;
        4)
            echo ""
            list_aws_rules
            ;;
        5)
            sync_clients_to_aws
            ;;
        6)
            echo ""
            log_success "═══════════════════════════════════════════════════════════"
            log_success "Build Box Client Management Complete"
            log_success "═══════════════════════════════════════════════════════════"
            echo ""
            echo "Configuration Summary:"
            echo "  Security Group: $EDGE_BOX_SG"
            echo "  Clients File: $CLIENTS_FILE"
            echo ""

            # Count clients (without using local in main script)
            clients_count=$(grep -v '^#' "$CLIENTS_FILE" | grep -v '^$' | wc -l)
            echo "  Authorized Clients: $clients_count"
            echo ""
            echo "Next Steps:"
            echo "  • Test web access: https://${BUILDBOX_PUBLIC_IP:-<buildbox-ip>}:8444/demo.html"
            echo "  • Configure GPU security: ./scripts/030-configure-gpu-security.sh"
            echo ""
            exit 0
            ;;
        *)
            log_error "Invalid choice: $choice"
            ;;
    esac

    # Pause before showing menu again
    echo ""
    read -p "Press Enter to continue..." -r
done
