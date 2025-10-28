#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# 305: Setup WhisperLive Edge Proxy
# ============================================================================
# Deploys Caddy reverse proxy on edge EC2 instance for WhisperLive.
# This script should be run ON THE EDGE EC2 INSTANCE.
#
# What this does:
# 1. Install Docker and Docker Compose
# 2. Create project directory structure
# 3. Create .env-http configuration file
# 4. Create Caddyfile for WebSocket reverse proxying
# 5. Deploy browser client files (index.html, test-whisper.html)
# 6. Start Caddy container
# 7. Verify deployment
# ============================================================================

# Find repository root (works from symlink or direct execution)
if [ -L "${BASH_SOURCE[0]}" ]; then
    SCRIPT_REAL=$(readlink -f "${BASH_SOURCE[0]}")
else
    SCRIPT_REAL="${BASH_SOURCE[0]}"
fi
REPO_ROOT="$(cd "$(dirname "$SCRIPT_REAL")/.." && pwd)"
PROJECT_ROOT="$REPO_ROOT"

# Source common functions if available
if [ -f "$REPO_ROOT/scripts/lib/common-functions.sh" ]; then
    source "$REPO_ROOT/scripts/lib/common-functions.sh"
else
    log_info() { echo "[INFO] $*"; }
    log_success() { echo "[SUCCESS] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_warn() { echo "[WARN] $*"; }
fi

echo "============================================"
echo "305: Setup WhisperLive Edge Proxy"
echo "============================================"
echo ""

# Check if running as root
if [ "$EUID" -eq 0 ]; then
  log_error "Do not run this script as root"
  echo "Run as: ./scripts/305-setup-whisperlive-edge.sh"
  exit 1
fi

# ============================================================================
# Step 1: Check Prerequisites
# ============================================================================
log_info "Step 1/8: Checking prerequisites..."

# Load main .env if exists
if [ -f "$PROJECT_ROOT/.env" ]; then
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
    log_info "Loaded environment from .env"
fi

# Check if SSL certificates exist
if [ ! -f "/opt/riva/certs/server.crt" ] || [ ! -f "/opt/riva/certs/server.key" ]; then
    log_error "SSL certificates not found at /opt/riva/certs/"
    log_info "These should have been created by script 010-setup-build-box.sh"
    log_info "Or copy existing certificates to /opt/riva/certs/"
    exit 1
fi

log_success "SSL certificates found at /opt/riva/certs/"
echo ""

# ============================================================================
# Step 2: Install Docker
# ============================================================================
log_info "Step 2/8: Installing Docker..."

if command -v docker &> /dev/null; then
    log_success "Docker already installed: $(docker --version)"
else
    log_info "Installing Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    sudo usermod -aG docker $USER
    rm get-docker.sh
    log_success "Docker installed. You may need to log out and back in for group changes to take effect."
fi

# Check if docker compose is available (v2 plugin)
if docker compose version &> /dev/null; then
    log_success "Docker Compose V2 available: $(docker compose version)"
elif command -v docker-compose &> /dev/null; then
    log_success "Docker Compose V1 available: $(docker-compose --version)"
else
    log_info "Installing Docker Compose V2 plugin..."
    sudo apt-get update
    sudo apt-get install -y docker-compose-plugin
    log_success "Docker Compose installed"
fi

echo ""

# ============================================================================
# Step 3: Create Project Directory
# ============================================================================
log_info "Step 3/8: Creating project directory..."

EDGE_DIR="$HOME/event-b/whisper-live-test"
mkdir -p "$EDGE_DIR"/{site,logs}
cd "$EDGE_DIR"

log_success "Project directory created at $EDGE_DIR"
echo ""

# ============================================================================
# Step 4: Gather Configuration
# ============================================================================
log_info "Step 4/8: Gathering configuration..."

# Get edge public IP
EDGE_PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null)
log_info "Edge public IP: $EDGE_PUBLIC_IP"

# Get GPU IP from .env or prompt
if [ -z "${GPU_INSTANCE_IP:-}" ]; then
    log_warn "GPU_INSTANCE_IP not found in .env"
    read -p "Enter GPU instance private IP: " GPU_INSTANCE_IP
fi

log_info "GPU instance IP: $GPU_INSTANCE_IP"

# Get user email
if [ -z "${EMAIL:-}" ]; then
    read -p "Enter your email for SSL certificates: " EMAIL
fi

log_success "Configuration gathered"
echo ""

# ============================================================================
# Step 5: Create .env-http Configuration
# ============================================================================
log_info "Step 5/8: Creating .env-http configuration..."

cat > "$EDGE_DIR/.env-http" << EOF
# WhisperLive Edge Proxy Configuration
# Created by 305-setup-whisperlive-edge.sh on $(date)

# Domain (using IP for now, can use domain name later)
DOMAIN=${GPU_INSTANCE_IP}

# Email for Let's Encrypt (not used with self-signed certs)
EMAIL=${EMAIL}

# GPU WhisperLive endpoint
GPU_HOST=${GPU_INSTANCE_IP}
GPU_PORT=9090

# WhisperLive model settings (these are just defaults shown in UI)
MODEL=Systran/faster-whisper-small.en
LANGUAGE=en
EOF

log_success ".env-http created"

# Create symlink in project root for startup-restore script
log_info "Creating .env-http symlink in project root..."
ln -sf "$EDGE_DIR/.env-http" "$REPO_ROOT/.env-http"
log_success "Symlink created: $REPO_ROOT/.env-http -> $EDGE_DIR/.env-http"
echo ""

# ============================================================================
# Step 6: Create Caddyfile
# ============================================================================
log_info "Step 6/8: Creating Caddyfile..."

cat > "$EDGE_DIR/Caddyfile" << 'EOF'
https:// {
    tls /certs/server.crt /certs/server.key

    # WebSocket proxy to WhisperLive on GPU
    handle /ws {
        reverse_proxy {$GPU_HOST}:{$GPU_PORT}
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
http:// {
    redir https://{host}{uri} permanent
}
EOF

log_success "Caddyfile created"
echo ""

# ============================================================================
# Step 7: Create Docker Compose Configuration
# ============================================================================
log_info "Step 7/8: Creating docker-compose.yml..."

cat > "$EDGE_DIR/docker-compose.yml" << 'EOF'
version: "3.9"

services:
  caddy:
    image: caddy:2.8
    container_name: whisperlive-edge
    restart: unless-stopped
    ports:
      - "80:80"     # HTTP (redirects to HTTPS)
      - "443:443"   # HTTPS
    env_file:
      - .env-http
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - ./site:/srv
      - /opt/riva/certs:/certs:ro
      - caddy_data:/data
      - caddy_config:/config

volumes:
  caddy_data:
  caddy_config:
EOF

log_success "docker-compose.yml created"
echo ""

# ============================================================================
# Step 8: Deploy Browser Client Files
# ============================================================================
log_info "Step 8/8: Deploying browser client files..."

# Copy client files from project if they exist
if [ -f "$PROJECT_ROOT/site/index.html" ]; then
    cp "$PROJECT_ROOT/site"/*.html "$EDGE_DIR/site/" 2>/dev/null || true
    log_success "Copied existing client files"
else
    log_info "Creating default browser clients..."
    # Files will be created by script 320-update-edge-clients.sh
    # For now, create a simple placeholder
    cat > "$EDGE_DIR/site/index.html" << 'HTMLEOF'
<!DOCTYPE html>
<html>
<head>
    <title>WhisperLive Edge Proxy</title>
</head>
<body>
    <h1>WhisperLive Edge Proxy</h1>
    <p>Edge proxy is running. Browser clients will be deployed by script 320-update-edge-clients.sh</p>
    <p><a href="/healthz">Health Check</a></p>
</body>
</html>
HTMLEOF
    log_success "Created placeholder index.html"
fi

echo ""

# ============================================================================
# Start Caddy
# ============================================================================
log_info "Starting Caddy container..."

# Stop nginx if running (conflicts on ports 80/443)
if systemctl is-active --quiet nginx 2>/dev/null; then
    log_warn "Nginx is running and will conflict with Caddy"
    read -p "Stop nginx? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        sudo systemctl stop nginx
        sudo systemctl disable nginx
        log_success "Nginx stopped"
    else
        log_error "Cannot start Caddy while nginx is running on ports 80/443"
        exit 1
    fi
fi

# Check if container already exists
if docker ps -a --format '{{.Names}}' | grep -q "^whisperlive-edge$"; then
    echo ""
    log_warn "⚠️  Container 'whisperlive-edge' already exists"
    echo ""
    echo "The container will be removed and recreated with current configuration."
    echo "This preserves all config files and Docker volumes (SSL certs, cache)."
    echo ""
    read -p "Remove existing container and recreate? (y/n): " -n 1 -r
    echo
    echo ""

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Stopping and removing existing container..."
        docker stop whisperlive-edge 2>/dev/null || true
        docker rm whisperlive-edge 2>/dev/null || true
        log_success "✅ Removed existing container"
        echo ""
    else
        log_info "Exiting without changes."
        echo ""
        echo "To manage the existing container:"
        echo "  • Restart: cd $EDGE_DIR && docker compose restart"
        echo "  • Logs: cd $EDGE_DIR && docker compose logs -f"
        echo "  • Stop: cd $EDGE_DIR && docker compose down"
        echo "  • Remove: docker stop whisperlive-edge && docker rm whisperlive-edge"
        echo ""
        exit 0
    fi
fi

# Start Caddy
cd "$EDGE_DIR"
docker compose up -d

log_success "Caddy container started"
echo ""

# Wait for Caddy to be ready
sleep 3

# Check Caddy status
if docker compose ps | grep -q "Up"; then
    log_success "Caddy is running"
else
    log_error "Caddy failed to start. Check logs with: docker compose logs"
    exit 1
fi

echo ""
log_info "==================================================================="
log_success "✅ WHISPERLIVE EDGE PROXY DEPLOYED"
log_info "==================================================================="
echo ""
log_info "Edge Proxy Details:"
log_info "  - Location: $EDGE_DIR"
log_info "  - HTTPS URL: https://$EDGE_PUBLIC_IP/"
log_info "  - Health Check: https://$EDGE_PUBLIC_IP/healthz"
log_info "  - WebSocket: wss://$EDGE_PUBLIC_IP/ws"
log_info "  - Container: whisperlive-edge"
echo ""
log_info "GPU Connection:"
log_info "  - Target: $GPU_INSTANCE_IP:9090"
log_info "  - Protocol: WebSocket (ws://)"
echo ""
log_info "Management Commands:"
log_info "  - View logs: docker compose logs -f"
log_info "  - Restart: docker compose restart"
log_info "  - Stop: docker compose down"
log_info "  - Status: docker compose ps"
echo ""
log_info "Next Steps:"
log_info "  1. Run 310-configure-whisperlive-gpu.sh to set up WhisperLive on GPU"
log_info "  2. Run 030-configure-gpu-security.sh to allow edge→GPU access (port 9090)"
log_info "  3. Run 031-configure-edge-box-security.sh to manage client access"
log_info "  4. Run 320-update-edge-clients.sh to deploy full browser clients"
log_info "  5. Run 325-test-whisperlive-connection.sh to validate end-to-end"
echo ""
log_warn "IMPORTANT: Browser clients need to be deployed with script 320"
echo ""
