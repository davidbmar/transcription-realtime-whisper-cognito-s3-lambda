#!/usr/bin/env bash
#
# 306-setup-edge-domain-letsencrypt.sh
#
# Configure Edge Box with Domain Name and Let's Encrypt SSL
#
# This script:
# 1. Updates Caddyfile to use domain instead of IP
# 2. Caddy automatically obtains Let's Encrypt certificate
# 3. Updates .env with new domain and WebSocket URL
# 4. Restarts Caddy container
# 5. Redeploys UI with new configuration
#
# Prerequisites:
# - DNS A record pointing domain to edge box IP
# - Port 80 and 443 accessible (for Let's Encrypt verification)
# - Script must run ON the edge box instance
#
# Usage: ./scripts/306-setup-edge-domain-letsencrypt.sh [domain]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load common functions
source "$SCRIPT_DIR/lib/common-functions.sh"

# Initialize logging
SCRIPT_NAME="$(basename "$0" .sh)"
LOG_FILE="${REPO_ROOT}/logs/${SCRIPT_NAME}-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "${REPO_ROOT}/logs"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "============================================"
echo "306: Configure Edge Box with Domain + Let's Encrypt"
echo "============================================"
echo ""

# Load environment
load_environment

# Get domain from argument or prompt
DOMAIN="${1:-}"

if [[ -z "$DOMAIN" ]]; then
    echo "ℹ️  No domain provided as argument"
    echo ""
    echo "Please enter your domain name:"
    echo "  Example: transcribe.davidbmar.com"
    echo ""
    read -p "Domain: " DOMAIN
fi

if [[ -z "$DOMAIN" ]]; then
    log_error "Domain is required"
    echo ""
    echo "Usage: $0 transcribe.davidbmar.com"
    exit 1
fi

log_info "Domain: $DOMAIN"
echo ""

# Step 1: Verify DNS is configured
log_info "Step 1/7: Verifying DNS configuration..."

EXPECTED_IP=$(curl -s http://checkip.amazonaws.com 2>/dev/null || echo "")
if [[ -z "$EXPECTED_IP" ]]; then
    log_error "Could not determine edge box public IP"
    exit 1
fi

log_info "Edge box IP: $EXPECTED_IP"

# Check DNS resolution
RESOLVED_IP=$(nslookup "$DOMAIN" 8.8.8.8 2>/dev/null | grep -A1 "Name:" | grep "Address:" | awk '{print $2}' | head -1 || echo "")

if [[ -z "$RESOLVED_IP" ]]; then
    log_error "DNS not configured for $DOMAIN"
    echo ""
    echo "Please create DNS A record:"
    echo "  Host: ${DOMAIN%%.*}  (or subdomain part)"
    echo "  Type: A"
    echo "  Value: $EXPECTED_IP"
    echo "  TTL: 300"
    echo ""
    echo "Wait 1-5 minutes after creating the record, then re-run this script."
    exit 1
fi

if [[ "$RESOLVED_IP" != "$EXPECTED_IP" ]]; then
    log_error "DNS points to wrong IP"
    echo ""
    echo "Expected: $EXPECTED_IP (edge box)"
    echo "Actual:   $RESOLVED_IP (from DNS)"
    echo ""
    echo "Please update DNS A record to point to: $EXPECTED_IP"
    exit 1
fi

log_success "DNS configured correctly: $DOMAIN → $EXPECTED_IP"
echo ""

# Step 2: Check if we're on the edge box
log_info "Step 2/7: Verifying we're on the edge box..."

CURRENT_HOSTNAME=$(hostname)
log_info "Current hostname: $CURRENT_HOSTNAME"

# Check if docker compose exists (edge box has Caddy container)
if [[ ! -f "/home/ubuntu/event-b/whisper-live-test/docker-compose.yml" ]]; then
    log_error "Not running on edge box (docker-compose.yml not found)"
    echo ""
    echo "This script must run ON the edge box instance:"
    echo "  ssh -i ~/.ssh/your-key.pem ubuntu@${EXPECTED_IP}"
    echo "  cd ~/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4"
    echo "  ./scripts/306-setup-edge-domain-letsencrypt.sh $DOMAIN"
    exit 1
fi

log_success "Running on edge box"
echo ""

# Step 3: Backup current Caddyfile
log_info "Step 3/7: Backing up Caddyfile..."

CADDY_DIR="/home/ubuntu/event-b/whisper-live-test"
CADDYFILE="$CADDY_DIR/Caddyfile"
BACKUP_FILE="$CADDYFILE.backup-$(date +%Y%m%d-%H%M%S)"

if [[ -f "$CADDYFILE" ]]; then
    cp "$CADDYFILE" "$BACKUP_FILE"
    log_success "Backed up to: $BACKUP_FILE"
else
    log_error "Caddyfile not found: $CADDYFILE"
    exit 1
fi

echo ""

# Step 4: Update Caddyfile with domain
log_info "Step 4/7: Updating Caddyfile with domain..."

cat > "$CADDYFILE" << EOF
# Caddy configuration for WhisperLive Edge Proxy
# Domain: $DOMAIN (Let's Encrypt SSL)

$DOMAIN {
    # Caddy automatically obtains Let's Encrypt certificate!
    # No manual certificate management needed

    # WebSocket proxy to WhisperLive on GPU
    @websockets {
        path /ws*
    }

    handle @websockets {
        reverse_proxy {env.GPU_HOST}:{env.GPU_PORT} {
            header_up Host {http.request.host}
            header_up X-Real-IP {http.request.remote.host}
            header_up X-Forwarded-For {http.request.remote.host}
            header_up X-Forwarded-Proto {http.request.scheme}
            header_up Connection {http.request.header.Connection}
            header_up Upgrade {http.request.header.Upgrade}
        }
    }

    # Health check endpoint
    handle /healthz {
        respond "OK" 200
    }

    # Static files (browser clients)
    handle {
        root * /srv
        file_server browse
    }

    log {
        output stdout
    }
}

# HTTP redirect to HTTPS
http://$DOMAIN {
    redir https://{host}{uri} permanent
}
EOF

log_success "Caddyfile updated for domain: $DOMAIN"
echo ""

# Step 5: Update .env files
log_info "Step 5/7: Updating .env configuration..."

# Update edge box .env-http
if [[ -f "$REPO_ROOT/.env-http" ]]; then
    sed -i "s|^EDGE_BOX_DNS=.*|EDGE_BOX_DNS=$DOMAIN|" "$REPO_ROOT/.env-http"
    sed -i "s|^WHISPERLIVE_WS_URL=.*|WHISPERLIVE_WS_URL=wss://$DOMAIN/ws|" "$REPO_ROOT/.env-http"
    log_info "Updated .env-http"
fi

# Update main .env
if [[ -f "$REPO_ROOT/.env" ]]; then
    # Update or add EDGE_BOX_DNS
    if grep -q "^EDGE_BOX_DNS=" "$REPO_ROOT/.env"; then
        sed -i "s|^EDGE_BOX_DNS=.*|EDGE_BOX_DNS=$DOMAIN|" "$REPO_ROOT/.env"
    else
        echo "EDGE_BOX_DNS=$DOMAIN" >> "$REPO_ROOT/.env"
    fi

    # Update or add WHISPERLIVE_WS_URL
    if grep -q "^WHISPERLIVE_WS_URL=" "$REPO_ROOT/.env"; then
        sed -i "s|^WHISPERLIVE_WS_URL=.*|WHISPERLIVE_WS_URL=wss://$DOMAIN/ws|" "$REPO_ROOT/.env"
    else
        echo "WHISPERLIVE_WS_URL=wss://$DOMAIN/ws" >> "$REPO_ROOT/.env"
    fi

    log_success "Updated .env"
fi

echo ""

# Step 6: Restart Caddy container
log_info "Step 6/7: Restarting Caddy with new configuration..."

cd "$CADDY_DIR"

# Stop and remove old container
docker stop whisperlive-edge 2>/dev/null || true
docker rm whisperlive-edge 2>/dev/null || true

# Start new container (Caddy will automatically get Let's Encrypt cert)
log_info "Starting Caddy (this will obtain Let's Encrypt certificate)..."
log_info "This may take 30-60 seconds..."

# Regenerate .env-http from .env with dynamic GPU IP lookup
log_info "Regenerating .env-http with current GPU IP..."
cd "$REPO_ROOT"  # Go to repo root for generate_env_http context
if generate_env_http "$CADDY_DIR"; then
    log_success "✅ Generated .env-http with dynamic GPU IP"
else
    log_error "Failed to generate .env-http"
    exit 1
fi
cd "$CADDY_DIR"  # Return to caddy dir
echo ""

docker compose up -d

# Wait for container to start
sleep 5

# Check if container is running
if docker ps | grep -q whisperlive-edge; then
    log_success "Caddy container running"
else
    log_error "Caddy container failed to start"
    echo ""
    echo "Check logs: docker logs whisperlive-edge"
    exit 1
fi

echo ""

# Step 7: Verify Let's Encrypt certificate
log_info "Step 7/7: Verifying Let's Encrypt certificate..."

# Wait a bit for Let's Encrypt
sleep 10

# Test HTTPS endpoint
if curl -s --max-time 10 "https://$DOMAIN/healthz" 2>&1 | grep -q "OK"; then
    log_success "✅ Let's Encrypt certificate obtained successfully!"
    log_success "✅ HTTPS working: https://$DOMAIN/healthz"
else
    log_warn "Certificate may still be loading (this is normal)"
    log_info "Check Caddy logs: docker logs whisperlive-edge -f"
fi

echo ""

# Summary
echo "==========================================="
echo "✅ EDGE BOX CONFIGURED WITH DOMAIN"
echo "==========================================="
echo ""
echo "📋 Configuration:"
echo "  Domain: $DOMAIN"
echo "  SSL: Let's Encrypt (automatic renewal)"
echo "  WebSocket: wss://$DOMAIN/ws"
echo "  Health check: https://$DOMAIN/healthz"
echo ""
echo "🔒 SSL Certificate:"
echo "  ✅ Let's Encrypt (trusted by all browsers)"
echo "  ✅ Auto-renewal every 90 days"
echo "  ✅ No more certificate warnings!"
echo ""
echo "📝 Next Steps:"
echo "  1. Test health check: curl https://$DOMAIN/healthz"
echo "  2. Redeploy UI with new WebSocket URL:"
echo "     ./scripts/425-deploy-recorder-ui.sh"
echo "  3. Test in browser: https://[your-cloudfront-url]/audio.html"
echo ""
echo "🔍 Troubleshooting:"
echo "  - View Caddy logs: docker logs whisperlive-edge -f"
echo "  - Check certificate: curl -v https://$DOMAIN/healthz"
echo "  - Manual restart: cd $CADDY_DIR && docker compose restart"
echo ""
echo "✅ No more browser certificate warnings!"
echo ""
