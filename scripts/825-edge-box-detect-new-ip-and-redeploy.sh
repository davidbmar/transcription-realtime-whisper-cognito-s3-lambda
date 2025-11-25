#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# 825: Update Edge Box and GPU IP Addresses
# ============================================================================
# Detects and handles IP changes for both edge box and GPU (e.g., after EC2 stop/start).
# Uses dynamic IP lookup from instance IDs.
#
# What this does:
# 1. Detects current edge box public IP
# 2. Detects current GPU IP from GPU_INSTANCE_ID (dynamic lookup)
# 3. Compares both with stored IPs in configuration files
# 4. If edge box IP changed:
#    - Updates .env configuration
#    - Regenerates SSL certificate for new IP
#    - Redeploys UI with new WebSocket URL
# 5. If GPU IP changed:
#    - Updates .env-http (Caddy's proxy target)
#    - Restarts Caddy to connect to new GPU IP
# 6. Provides verification steps for browser
#
# Run this script:
# - After stopping/starting the edge box EC2 instance
# - After stopping/starting the GPU EC2 instance
# - When either IP changes for any reason
# - To verify/fix SSL certificate issues
# - Automatically runs on boot via systemd (if configured with script 827)
# ============================================================================

# Find repository root (works from symlink or direct execution)
if [ -L "${BASH_SOURCE[0]}" ]; then
    SCRIPT_REAL=$(readlink -f "${BASH_SOURCE[0]}")
else
    SCRIPT_REAL="${BASH_SOURCE[0]}"
fi
REPO_ROOT="$(cd "$(dirname "$SCRIPT_REAL")/.." && pwd)"

source "$REPO_ROOT/scripts/lib/common-functions.sh"
load_environment

# Source riva-common-library for dynamic GPU IP lookup
if [ -f "$REPO_ROOT/scripts/riva-common-library.sh" ]; then
    source "$REPO_ROOT/scripts/riva-common-library.sh"
fi

echo "============================================"
echo "825: Update Edge Box IP Address"
echo "============================================"
echo ""

# ============================================================================
# Step 1: Detect Current Edge Box IP
# ============================================================================
log_info "Step 1/7: Detecting edge box public IP..."

CURRENT_EDGE_IP=$(curl -s http://checkip.amazonaws.com 2>/dev/null || curl -s http://ifconfig.me 2>/dev/null || curl -s http://icanhazip.com 2>/dev/null)

if [ -z "$CURRENT_EDGE_IP" ]; then
    log_error "Failed to detect edge box public IP"
    log_info "Are you running this script ON the edge box instance?"
    exit 1
fi

log_info "Current edge box IP: $CURRENT_EDGE_IP"
echo ""

# ============================================================================
# Step 2: Check if IP Changed
# ============================================================================
log_info "Step 2/7: Checking if IP changed..."

OLD_EDGE_IP=$(grep "^EDGE_BOX_DNS=" .env 2>/dev/null | cut -d'=' -f2 || echo "")
OLD_WS_URL=$(grep "^WHISPERLIVE_WS_URL=" .env 2>/dev/null | cut -d'=' -f2 || echo "")

if [ -z "$OLD_EDGE_IP" ]; then
    log_warn "EDGE_BOX_DNS not found in .env, will add it"
    IP_CHANGED=true
elif [ "$CURRENT_EDGE_IP" = "$OLD_EDGE_IP" ]; then
    log_success "✅ IP unchanged: $CURRENT_EDGE_IP"

    # Even if IP unchanged, verify certificate is correct
    log_info ""
    log_info "Verifying SSL certificate..."
    CERT_CN=$(openssl x509 -in /opt/riva/certs/server.crt -noout -subject 2>/dev/null | grep -oP 'CN\s*=\s*\K[^,]+' || echo "")

    if [ "$CERT_CN" = "$CURRENT_EDGE_IP" ]; then
        log_success "✅ SSL certificate is correct for IP: $CERT_CN"
        echo ""
        echo "╔════════════════════════════════════════════════════════════╗"
        echo "║                                                            ║"
        echo "║    ✅ EDGE BOX CONFIGURATION IS UP TO DATE                ║"
        echo "║                                                            ║"
        echo "╚════════════════════════════════════════════════════════════╝"
        echo ""
        log_info "Edge Box Details:"
        echo "  Public IP: $CURRENT_EDGE_IP"
        echo "  WebSocket URL: $OLD_WS_URL"
        echo "  SSL Certificate: Valid for $CERT_CN"
        echo "  Caddy Container: $(docker ps --filter name=whisperlive-edge --format '{{.Status}}' 2>/dev/null || echo 'Not running')"
        echo ""
        log_info "Next Steps:"
        echo "  1. Visit: https://$CURRENT_EDGE_IP/healthz"
        echo "  2. Accept SSL certificate in browser (if using self-signed cert)"
        echo "  3. Test recording: https://${COGNITO_CLOUDFRONT_URL:-your-cloudfront-url}/audio.html"
        echo ""
        exit 0
    else
        log_warn "⚠️  SSL certificate is for different IP: $CERT_CN (should be $CURRENT_EDGE_IP)"
        log_info "Will regenerate certificate..."
        IP_CHANGED=false
        CERT_NEEDS_REGEN=true
    fi
else
    log_warn "⚠️  IP has changed!"
    echo "  Old IP: $OLD_EDGE_IP"
    echo "  New IP: $CURRENT_EDGE_IP"
    IP_CHANGED=true
fi

echo ""

# ============================================================================
# Step 2b: Check GPU IP Changes (Critical for Caddy Proxy)
# ============================================================================
log_info "Step 2b/8: Checking GPU IP (for Caddy reverse proxy)..."

GPU_IP_CHANGED=false
CADDY_NEEDS_UPDATE=false

if [ -n "${GPU_INSTANCE_ID:-}" ] && command -v get_instance_ip >/dev/null 2>&1; then
    # Use dynamic IP lookup
    CURRENT_GPU_IP=$(get_instance_ip "$GPU_INSTANCE_ID")

    if [ -z "$CURRENT_GPU_IP" ] || [ "$CURRENT_GPU_IP" = "None" ]; then
        log_warn "⚠️  Could not look up GPU IP from instance ID: $GPU_INSTANCE_ID"
        log_info "GPU may be stopped. Caddy config will be updated when GPU restarts."
        CURRENT_GPU_IP=""
    else
        log_success "✅ GPU IP from dynamic lookup: $CURRENT_GPU_IP"

        # Check if GPU IP changed in .env-http (Caddy's config)
        ENV_HTTP_PATH=""
        for caddy_dir in "$HOME/event-b/whisper-live-test" "$HOME/event-b/whisper-live-edge"; do
            if [ -f "$caddy_dir/.env-http" ]; then
                ENV_HTTP_PATH="$caddy_dir/.env-http"
                break
            fi
        done

        if [ -n "$ENV_HTTP_PATH" ]; then
            OLD_GPU_IP=$(grep "^GPU_HOST=" "$ENV_HTTP_PATH" 2>/dev/null | cut -d'=' -f2 || echo "")

            if [ -z "$OLD_GPU_IP" ]; then
                log_warn "GPU_HOST not found in .env-http, will add it"
                GPU_IP_CHANGED=true
                CADDY_NEEDS_UPDATE=true
            elif [ "$CURRENT_GPU_IP" != "$OLD_GPU_IP" ]; then
                log_warn "⚠️  GPU IP has changed!"
                echo "  Old GPU IP: $OLD_GPU_IP"
                echo "  New GPU IP: $CURRENT_GPU_IP"
                GPU_IP_CHANGED=true
                CADDY_NEEDS_UPDATE=true
            else
                log_success "✅ GPU IP unchanged: $CURRENT_GPU_IP"
            fi
        else
            log_warn ".env-http not found, Caddy may not be configured"
        fi
    fi
else
    log_info "GPU_INSTANCE_ID not set, skipping GPU IP check"
    log_info "To enable automatic GPU IP detection, set GPU_INSTANCE_ID in .env"
fi

echo ""

# ============================================================================
# Step 3: Update Configuration Files
# ============================================================================
if [ "$IP_CHANGED" = "true" ]; then
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║                                                            ║"
    echo "║       ⚠️  CRITICAL: EDGE BOX IP ADDRESS HAS CHANGED       ║"
    echo "║                                                            ║"
    echo "╟────────────────────────────────────────────────────────────╢"
    echo "║  Old IP: $OLD_EDGE_IP"
    echo "║  New IP: $CURRENT_EDGE_IP"
    echo "╟────────────────────────────────────────────────────────────╢"
    echo "║  Actions being taken:                                      ║"
    echo "║   1. Updating .env configuration                           ║"
    echo "║   2. Regenerating SSL certificate                          ║"
    echo "║   3. Restarting Caddy container                            ║"
    echo "║   4. Redeploying UI with new WebSocket URL                 ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    log_info "Step 3/7: Updating configuration files..."

    # Update EDGE_BOX_DNS in .env
    if grep -q "^EDGE_BOX_DNS=" .env 2>/dev/null; then
        sed -i "s/^EDGE_BOX_DNS=.*/EDGE_BOX_DNS=$CURRENT_EDGE_IP/" .env
        log_success "  ✅ Updated EDGE_BOX_DNS in .env"
    else
        echo "EDGE_BOX_DNS=$CURRENT_EDGE_IP" >> .env
        log_success "  ✅ Added EDGE_BOX_DNS to .env"
    fi

    # Update WHISPERLIVE_WS_URL in .env
    NEW_WS_URL="wss://$CURRENT_EDGE_IP/ws"
    if grep -q "^WHISPERLIVE_WS_URL=" .env 2>/dev/null; then
        sed -i "s|^WHISPERLIVE_WS_URL=.*|WHISPERLIVE_WS_URL=$NEW_WS_URL|" .env
        log_success "  ✅ Updated WHISPERLIVE_WS_URL in .env"
    else
        echo "WHISPERLIVE_WS_URL=$NEW_WS_URL" >> .env
        log_success "  ✅ Added WHISPERLIVE_WS_URL to .env"
    fi

    # Update BUILDBOX_PUBLIC_IP in .env (if present)
    if grep -q "^BUILDBOX_PUBLIC_IP=" .env 2>/dev/null; then
        sed -i "s/^BUILDBOX_PUBLIC_IP=.*/BUILDBOX_PUBLIC_IP=$CURRENT_EDGE_IP/" .env
        log_success "  ✅ Updated BUILDBOX_PUBLIC_IP in .env"
    fi

    log_success "✅ Configuration files updated"

    # Update GPU security group to allow SSH from new Edge Box IP
    if [ -n "${GPU_INSTANCE_ID:-}" ]; then
        log_info "Updating GPU security group for SSH access..."
        GPU_SG=$(aws ec2 describe-instances --instance-ids "$GPU_INSTANCE_ID" --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")

        if [ -n "$GPU_SG" ] && [ "$GPU_SG" != "None" ]; then
            # Add new IP
            if aws ec2 authorize-security-group-ingress --group-id "$GPU_SG" --protocol tcp --port 22 --cidr "$CURRENT_EDGE_IP/32" 2>/dev/null; then
                log_success "  ✅ Added SSH access from $CURRENT_EDGE_IP to GPU security group"
            else
                log_info "  ℹ️  SSH rule may already exist (ignoring error)"
            fi

            # Remove old IP if it exists and is different
            if [ -n "$OLD_EDGE_IP" ] && [ "$OLD_EDGE_IP" != "$CURRENT_EDGE_IP" ]; then
                if aws ec2 revoke-security-group-ingress --group-id "$GPU_SG" --protocol tcp --port 22 --cidr "$OLD_EDGE_IP/32" 2>/dev/null; then
                    log_success "  ✅ Removed old SSH rule for $OLD_EDGE_IP"
                else
                    log_info "  ℹ️  Old SSH rule not found (may have been removed already)"
                fi
            fi
        else
            log_warn "  ⚠️  Could not find GPU security group"
        fi
    fi

    # Reload environment
    load_environment
    echo ""
fi

# Generate .env-http from .env with dynamic GPU IP lookup
# This ensures .env is single source of truth and GPU_HOST is always correct
if [ "$GPU_IP_CHANGED" = "true" ] || [ "$IP_CHANGED" = "true" ] || [ "${CADDY_NEEDS_UPDATE:-false}" = "true" ]; then
    log_info "Regenerating .env-http from .env with dynamic GPU IP lookup..."

    # Find all possible Caddy directories
    CADDY_DIRS=(
        "$HOME/event-b/whisper-live-test"
        "$HOME/event-b/whisper-live-edge"
    )

    for caddy_dir in "${CADDY_DIRS[@]}"; do
        if [ -d "$caddy_dir" ]; then
            # Generate .env-http with dynamic GPU IP from GPU_INSTANCE_ID
            if generate_env_http "$caddy_dir"; then
                log_success "  ✅ Generated .env-http in: $caddy_dir"
                CADDY_NEEDS_UPDATE=true
            fi
        fi
    done

    echo ""
fi

# ============================================================================
# Step 4: Regenerate SSL Certificate
# ============================================================================
if [ "$IP_CHANGED" = "true" ] || [ "${CERT_NEEDS_REGEN:-false}" = "true" ]; then
    log_info "Step 4/7: Regenerating SSL certificate for new IP..."

    # Check if certificates directory exists
    if [ ! -d "/opt/riva/certs" ]; then
        log_info "Creating /opt/riva/certs directory..."
        sudo mkdir -p /opt/riva/certs
        sudo chown -R $USER:$USER /opt/riva
    fi

    # Backup old certificate if it exists
    if [ -f "/opt/riva/certs/server.crt" ]; then
        BACKUP_SUFFIX=$(date +%Y%m%d-%H%M%S)
        sudo cp /opt/riva/certs/server.crt "/opt/riva/certs/server.crt.backup-$BACKUP_SUFFIX"
        sudo cp /opt/riva/certs/server.key "/opt/riva/certs/server.key.backup-$BACKUP_SUFFIX"
        log_info "  Backed up old certificate to server.crt.backup-$BACKUP_SUFFIX"
    fi

    # Generate new certificate with IP as CN and SAN
    cd /opt/riva/certs
    sudo openssl req -x509 -newkey rsa:4096 -nodes \
        -keyout server.key \
        -out server.crt \
        -days 365 \
        -subj "/C=US/ST=State/L=City/O=Organization/CN=$CURRENT_EDGE_IP" \
        -addext "subjectAltName=IP:$CURRENT_EDGE_IP" \
        2>/dev/null

    sudo chmod 600 server.key
    sudo chmod 644 server.crt

    log_success "✅ SSL certificate regenerated for IP: $CURRENT_EDGE_IP"

    # Verify certificate
    CERT_CN=$(openssl x509 -in server.crt -noout -subject | grep -oP 'CN\s*=\s*\K[^,]+')
    log_info "  Certificate CN: $CERT_CN"

    cd "$REPO_ROOT"
    echo ""
fi

# ============================================================================
# Step 5: Restart Caddy Container
# ============================================================================
if [ "${CADDY_NEEDS_UPDATE:-false}" = "true" ]; then
    log_info "Step 5/8: Restarting Caddy container (config changed)..."
else
    log_info "Step 5/8: Restarting Caddy container with new certificate..."
fi

# Find Caddy docker-compose directory
CADDY_DIRS=(
    "$HOME/event-b/whisper-live-test"
    "$HOME/event-b/whisper-live-edge"
)

CADDY_RESTARTED=false
for caddy_dir in "${CADDY_DIRS[@]}"; do
    if [ -f "$caddy_dir/docker-compose.yml" ]; then
        log_info "  Found Caddy at: $caddy_dir"
        cd "$caddy_dir"

        # Regenerate .env-http from .env with dynamic GPU IP lookup
        # This ensures GPU_HOST is always correct before starting Caddy
        log_info "  Regenerating .env-http with current GPU IP..."
        cd "$REPO_ROOT"  # go back to repo root for generate_env_http
        generate_env_http "$caddy_dir"
        cd "$caddy_dir"  # return to caddy dir

        # Stop and remove container
        docker stop whisperlive-edge 2>/dev/null || true
        docker rm whisperlive-edge 2>/dev/null || true

        # Restart with docker compose (now with fresh .env-http)
        if docker compose up -d 2>/dev/null || docker-compose up -d 2>/dev/null; then
            log_success "  ✅ Caddy container restarted"
            CADDY_RESTARTED=true

            # Wait for Caddy to start
            sleep 3

            # Verify Caddy is running
            if docker ps --filter name=whisperlive-edge --format '{{.Names}}' | grep -q "whisperlive-edge"; then
                log_success "  ✅ Caddy is running"
            else
                log_error "  ❌ Caddy failed to start"
                docker logs whisperlive-edge --tail 20
            fi
        else
            log_error "  ❌ Failed to restart Caddy"
        fi

        cd "$REPO_ROOT"
        break
    fi
done

if [ "$CADDY_RESTARTED" = "false" ]; then
    log_warn "⚠️  Caddy docker-compose.yml not found in standard locations"
    log_info "You may need to manually restart Caddy"
fi

echo ""

# ============================================================================
# Step 6: Redeploy UI with New WebSocket URL
# ============================================================================
if [ "$IP_CHANGED" = "true" ]; then
    log_info "Step 6/7: Redeploying UI with new WebSocket URL..."

    if [ -f "$REPO_ROOT/scripts/425-deploy-recorder-ui.sh" ]; then
        log_info "Running 425-deploy-recorder-ui.sh..."
        "$REPO_ROOT/scripts/425-deploy-recorder-ui.sh"
        log_success "✅ UI redeployed with new WebSocket URL"
    else
        log_warn "⚠️  Script 425-deploy-recorder-ui.sh not found"
        log_info "You may need to manually redeploy the UI"
    fi
    echo ""
else
    log_info "Step 6/7: Skipping UI deployment (IP unchanged)"
    echo ""
fi

# ============================================================================
# Step 7: Verification and Next Steps
# ============================================================================
log_info "Step 7/7: Verification..."

# Test healthz endpoint
if curl -k -s https://localhost/healthz 2>/dev/null | grep -q "OK"; then
    log_success "✅ Edge proxy health check passed"
else
    log_warn "⚠️  Edge proxy health check failed"
fi

# Test certificate
CERT_TEST=$(openssl s_client -connect localhost:443 -servername $CURRENT_EDGE_IP </dev/null 2>&1 | grep "Verify return code")
log_info "  $CERT_TEST"

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                                                            ║"
echo "║       ✅ EDGE BOX IP UPDATE COMPLETE                      ║"
echo "║                                                            ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
log_info "Edge Box Configuration:"
echo "  Public IP: $CURRENT_EDGE_IP"
echo "  WebSocket URL: wss://$CURRENT_EDGE_IP/ws"
echo "  Health Check: https://$CURRENT_EDGE_IP/healthz"
echo "  SSL Certificate: Self-signed (CN=$CURRENT_EDGE_IP)"
echo ""
log_info "Caddy Status:"
docker ps --filter name=whisperlive-edge --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "  Container not running"
echo ""
log_warn "⚠️  IMPORTANT: Browser Certificate Acceptance Required"
echo ""
echo "Because we're using a self-signed certificate, you MUST accept it in your browser:"
echo ""
echo "  1. Open in browser: https://$CURRENT_EDGE_IP/healthz"
echo "  2. Click 'Advanced' → 'Proceed to $CURRENT_EDGE_IP (unsafe)'"
echo "  3. You should see: OK"
echo "  4. Now WebSocket connections will work"
echo ""
log_info "Then test the audio recorder:"
echo "  1. Visit: https://${COGNITO_CLOUDFRONT_URL:-your-cloudfront-url}/audio.html"
echo "  2. Hard refresh: Ctrl+Shift+R (or Cmd+Shift+R on Mac)"
echo "  3. Click 'Start Recording'"
echo "  4. You should see: 'WhisperLive WebSocket connected'"
echo ""
log_info "To use a trusted certificate (recommended for production):"
echo "  1. Point a domain to this IP: $CURRENT_EDGE_IP"
echo "  2. Update Caddyfile to use domain instead of IP"
echo "  3. Caddy will automatically get Let's Encrypt certificate"
echo ""
log_success "🎉 Edge box is ready!"
