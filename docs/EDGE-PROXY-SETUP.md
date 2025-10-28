# Edge Proxy Setup and GPU IP Management

## Overview

The WhisperLive edge proxy (Caddy) runs on the build box and forwards requests to the GPU instance. When the GPU instance is stopped and restarted, its public IP address changes, requiring updates to configuration files and container restarts.

## Architecture

```
Browser Client (HTTPS)
    ↓
Caddy Edge Proxy (Build Box)
    ↓ (forwards to GPU_HOST:9090)
WhisperLive Server (GPU Instance)
```

## File Structure

### Actual Files (in whisper-live-test/)
- `/home/ubuntu/event-b/whisper-live-test/.env-http` - GPU connection config
- `/home/ubuntu/event-b/whisper-live-test/docker-compose.yml` - Caddy container definition
- `/home/ubuntu/event-b/whisper-live-test/Caddyfile` - Caddy reverse proxy config
- `/home/ubuntu/event-b/whisper-live-test/site/` - Browser client files

### Symlinks (in project root)
Created to enable startup-restore script automation:
- `docker-compose.yml` → whisper-live-test/docker-compose.yml
- `Caddyfile` → whisper-live-test/Caddyfile
- `site/` → whisper-live-test/site/
- `.env-http` → whisper-live-test/.env-http (created by setup script)

**Note**: `.env-http` symlink is NOT committed to git (.gitignore) but is created automatically by `305-setup-whisperlive-edge.sh`

## Setup Workflow

### Initial Setup
```bash
# 1. Deploy GPU instance
./scripts/020-deploy-gpu-instance.sh

# 2. Configure WhisperLive on GPU
./scripts/310-configure-whisperlive-gpu.sh

# 3. Setup edge proxy on build box
./scripts/305-setup-whisperlive-edge.sh
   ↓
   Creates .env-http with current GPU IP
   Creates .env-http symlink in project root
   Creates docker-compose.yml, Caddyfile, site/
   Starts Caddy container
```

### Shutdown/Startup Cycle

#### Shutdown GPU to Save Costs
```bash
./scripts/210-shutdown-gpu.sh
```
This stops the GPU EC2 instance.

#### Startup GPU
```bash
./scripts/220-startup-restore.sh
```

**What this script does**:
1. Starts GPU instance (takes 2-3 minutes)
2. Queries AWS for new public IP
3. **If IP changed**:
   - Updates `.env` and `.env-http` with new GPU IP
   - Exports environment variables for child scripts
   - Updates AWS security groups
   - **Recreates Docker containers** (docker compose down && up -d)
4. Verifies SSH connectivity to GPU
5. Checks if WhisperLive is running
6. Deploys WhisperLive if needed
7. Restarts WhisperLive service

**Critical**: Docker containers MUST be recreated (not just restarted) to pick up new `.env-http` values.

## How Symlinks Enable Script Automation

The `220-startup-restore.sh` script includes this logic:

```bash
# Update .env-http files in multiple locations
EDGE_ENV_HTTP_LOCATIONS=(
  "$HOME/event-b/whisper-live-test/.env-http"
  "$HOME/event-b/whisper-live-edge/.env-http"
  ".env-http"
)

# ... updates all .env-http files with new IP ...

# Recreate Docker containers
if [ -f docker-compose.yml ]; then
  docker compose down
  docker compose up -d
fi
```

**Without symlinks**: Script would fail at `if [ -f docker-compose.yml ]` because file is in whisper-live-test/, not project root.

**With symlinks**:
- Script finds docker-compose.yml ✓
- Docker Compose follows symlinks to find Caddyfile, site/, and .env-http ✓
- Container recreated with new GPU IP ✓

## Verification

### Check Symlinks
```bash
ls -la | grep "^l.*->"
# Should show:
# .env-http -> whisper-live-test/.env-http
# Caddyfile -> whisper-live-test/Caddyfile
# docker-compose.yml -> whisper-live-test/docker-compose.yml
# site -> whisper-live-test/site
```

### Check Caddy Container
```bash
docker ps --filter "name=whisperlive-edge"
# Should show container running on ports 80, 443
```

### Check GPU IP in Config
```bash
grep "GPU_HOST" .env-http
# Should match current GPU IP from:
grep "GPU_INSTANCE_IP" .env
```

### Test Edge Proxy
```bash
curl -k https://$(grep BUILDBOX_PUBLIC_IP .env | cut -d= -f2)
# Should return HTML from site/index.html
```

## Troubleshooting

### Container Can't Connect to GPU
**Symptom**: Browser spins indefinitely, Caddy logs show "dial tcp: i/o timeout"

**Cause**: .env-http has old GPU IP

**Fix**:
```bash
# Check GPU IP
grep "GPU_INSTANCE_IP" .env

# Check .env-http
grep "GPU_HOST" .env-http

# If different, update and recreate container
cd /home/ubuntu/event-b/whisper-live-test
docker compose down
docker compose up -d
```

### Symlink Missing After Fresh Checkout
**Symptom**: `docker-compose.yml` not found in project root

**Cause**: Committed symlinks may not work across environments

**Fix**:
```bash
cd /home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4
ln -sf /home/ubuntu/event-b/whisper-live-test/docker-compose.yml .
ln -sf /home/ubuntu/event-b/whisper-live-test/Caddyfile .
ln -sf /home/ubuntu/event-b/whisper-live-test/site .
ln -sf /home/ubuntu/event-b/whisper-live-test/.env-http .
```

### Docker Compose "version is obsolete" Warning
This is harmless - Docker Compose v2 ignores the version field.

## Related Scripts

- `305-setup-whisperlive-edge.sh` - Initial edge proxy setup, creates symlinks
- `220-startup-restore.sh` - GPU startup with IP change handling
- `210-shutdown-gpu.sh` - GPU shutdown
- `310-configure-whisperlive-gpu.sh` - WhisperLive deployment to GPU

## Version History

- **2025-10-28**: Added symlink-based automation for IP change handling
- **2025-10-27**: Initial edge proxy setup with Caddy reverse proxy
