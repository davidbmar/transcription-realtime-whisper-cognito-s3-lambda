#!/bin/bash
set -e

cat << 'EOF'

╔════════════════════════════════════════════════════════════════════════╗
║                    300 Series: WhisperLive Edge Proxy                 ║
╚════════════════════════════════════════════════════════════════════════╝

This series deploys the WhisperLive edge proxy architecture:

  Browser (Mac/PC) --HTTPS/WSS--> Edge EC2 (Caddy) --WS--> GPU EC2 (WhisperLive)
                    :443                              :9090

ARCHITECTURE:
  - Edge Proxy: Caddy reverse proxy with SSL termination
  - GPU Worker: WhisperLive faster-whisper streaming ASR
  - Browser Client: Real-time speech recognition UI

SCRIPTS IN THIS SERIES:

  305-setup-whisperlive-edge.sh
    Deploy Caddy reverse proxy on edge EC2 instance
    - Install Docker and Docker Compose
    - Create Caddyfile for WebSocket proxying
    - Mount SSL certificates from /opt/riva/certs/
    - Deploy browser clients (index.html, test-whisper.html)
    - Start Caddy container

  310-configure-whisperlive-gpu.sh
    Install and configure WhisperLive on GPU instance
    - Install WhisperLive from Collabora repository
    - Download faster-whisper models
    - Configure WhisperLive server (port 9090)
    - Create systemd service for auto-start
    - Test WhisperLive is responding

  325-test-whisperlive-connection.sh
    Test end-to-end WhisperLive connectivity
    - Test GPU WhisperLive locally (localhost:9090)
    - Test Edge→GPU connection
    - Test Browser→Edge→GPU full path
    - Send test audio file and verify transcription
    - Validate Float32 PCM audio format

  320-update-edge-clients.sh
    Update browser client files on edge proxy
    - Deploy updated HTML/CSS/JS files
    - Restart Caddy to pick up changes
    - Test browser client connectivity

PREREQUISITES:
  Before running these scripts, ensure:
  - Scripts 005-040 have been run successfully
  - GPU instance is running with NVIDIA Riva
  - Edge EC2 instance is available
  - Security groups configured (scripts 030, 031, 040)
  - SSL certificates exist at /opt/riva/certs/

DEPLOYMENT ORDER:
  1. Run 305-setup-whisperlive-edge.sh     (on edge EC2)
  2. Run 310-configure-whisperlive-gpu.sh  (sets up GPU)
  3. Run 040-configure-edge-security.sh    (configure security groups)
  4. Run 315-test-whisperlive-connection.sh (validate deployment)

IMPORTANT NOTES:
  - WhisperLive expects Float32 PCM audio @ 16kHz, NOT Int16 or WebM
  - Browser clients use AudioContext to send raw Float32 audio
  - Transcriptions come back as JSON with segments array
  - Edge proxy uses existing SSL certs from /opt/riva/certs/
  - Port 9090 on GPU must be accessible from edge IP only (security)

TROUBLESHOOTING:
  - No transcriptions? Check audio format (Float32 vs Int16)
  - Connection refused? Check security groups and WhisperLive status
  - SSL errors? Verify certs exist at /opt/riva/certs/
  - WebSocket 404? Check Caddyfile handle /ws block

For detailed documentation, see:
  - FLOAT32_FIX.md - Audio format requirements
  - EDGE-DEPLOYMENT.md - Deployment guide
  - CHATGPT_PROMPT.md - Debugging guide

═══════════════════════════════════════════════════════════════════════

EOF

exit 0
