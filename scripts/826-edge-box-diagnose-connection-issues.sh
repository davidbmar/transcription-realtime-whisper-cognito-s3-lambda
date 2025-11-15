#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# 826: Diagnose Edge Box Connection Issues
# ============================================================================
# Comprehensive diagnostic tool for troubleshooting edge box connectivity,
# SSL certificates, and WhisperLive WebSocket connections.
#
# Use this when:
# - WebSocket connections fail with error 1006
# - Browser shows "connection failed" for wss://
# - SSL certificate warnings appear
# - Recording works but transcription doesn't
#
# This script checks:
# - Edge box IP detection
# - SSL certificate validity
# - Caddy container status
# - GPU connectivity from edge
# - WebSocket endpoint availability
# - Browser requirements
# ============================================================================

# Find repository root
if [ -L "${BASH_SOURCE[0]}" ]; then
    SCRIPT_REAL=$(readlink -f "${BASH_SOURCE[0]}")
else
    SCRIPT_REAL="${BASH_SOURCE[0]}"
fi
REPO_ROOT="$(cd "$(dirname "$SCRIPT_REAL")/.." && pwd)"

source "$REPO_ROOT/scripts/lib/common-functions.sh"

# Source riva-common-library for dynamic IP lookup
if [ -f "$REPO_ROOT/scripts/riva-common-library.sh" ]; then
    source "$REPO_ROOT/scripts/riva-common-library.sh"
fi

load_environment

echo "╔════════════════════════════════════════════════════════════╗"
echo "║                                                            ║"
echo "║       🔍 EDGE BOX CONNECTION DIAGNOSTICS                  ║"
echo "║                                                            ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

ISSUES_FOUND=0

# ============================================================================
# Test 1: Edge Box IP Detection
# ============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Test 1: Edge Box IP Detection"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

CURRENT_IP=$(curl -s http://checkip.amazonaws.com 2>/dev/null || echo "FAILED")
CONFIGURED_IP=$(grep "^EDGE_BOX_DNS=" .env 2>/dev/null | cut -d'=' -f2 || echo "NOT_SET")
WS_URL=$(grep "^WHISPERLIVE_WS_URL=" .env 2>/dev/null | cut -d'=' -f2 || echo "NOT_SET")

echo "  Current Public IP:  $CURRENT_IP"
echo "  Configured IP:      $CONFIGURED_IP"
echo "  WebSocket URL:      $WS_URL"
echo ""

if [ "$CURRENT_IP" = "FAILED" ]; then
    echo "  ❌ ISSUE: Cannot detect public IP"
    echo "     → Are you running this on the edge box?"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
elif [ "$CURRENT_IP" != "$CONFIGURED_IP" ]; then
    echo "  ❌ ISSUE: IP mismatch detected"
    echo "     → Run: ./scripts/825-update-edge-box-ip.sh"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
else
    echo "  ✅ PASS: IP configuration matches"
fi
echo ""

# ============================================================================
# Test 2: SSL Certificate Validity
# ============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Test 2: SSL Certificate Validity"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ -f "/opt/riva/certs/server.crt" ]; then
    CERT_CN=$(openssl x509 -in /opt/riva/certs/server.crt -noout -subject 2>/dev/null | grep -oP 'CN\s*=\s*\K[^,]+' || echo "INVALID")
    CERT_EXPIRY=$(openssl x509 -in /opt/riva/certs/server.crt -noout -enddate 2>/dev/null | cut -d'=' -f2)
    CERT_ISSUER=$(openssl x509 -in /opt/riva/certs/server.crt -noout -issuer 2>/dev/null | grep -oP 'CN\s*=\s*\K[^,]+' || echo "UNKNOWN")

    echo "  Certificate CN:     $CERT_CN"
    echo "  Certificate Issuer: $CERT_ISSUER (self-signed)"
    echo "  Expires:            $CERT_EXPIRY"
    echo ""

    if [ "$CERT_CN" != "$CURRENT_IP" ]; then
        echo "  ❌ ISSUE: Certificate CN doesn't match current IP"
        echo "     → Certificate is for: $CERT_CN"
        echo "     → Current IP is:      $CURRENT_IP"
        echo "     → Run: ./scripts/825-update-edge-box-ip.sh"
        ISSUES_FOUND=$((ISSUES_FOUND + 1))
    else
        echo "  ✅ PASS: Certificate matches current IP"
    fi
else
    echo "  ❌ ISSUE: Certificate not found at /opt/riva/certs/server.crt"
    echo "     → Run: ./scripts/010-setup-edge-box.sh"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
fi
echo ""

# ============================================================================
# Test 3: Caddy Container Status
# ============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Test 3: Caddy Container Status"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if docker ps --filter name=whisperlive-edge --format '{{.Names}}' 2>/dev/null | grep -q "whisperlive-edge"; then
    CONTAINER_STATUS=$(docker ps --filter name=whisperlive-edge --format '{{.Status}}')
    CONTAINER_PORTS=$(docker ps --filter name=whisperlive-edge --format '{{.Ports}}' | grep -oP '\d+:\d+' | head -2 | tr '\n' ', ' | sed 's/,$//')

    echo "  Container Name:     whisperlive-edge"
    echo "  Status:             $CONTAINER_STATUS"
    echo "  Ports:              $CONTAINER_PORTS"
    echo ""
    echo "  ✅ PASS: Caddy container is running"
else
    echo "  ❌ ISSUE: Caddy container not running"
    echo "     → Check: docker ps -a | grep whisperlive"
    echo "     → Start: cd ~/event-b/whisper-live-test && docker compose up -d"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
fi
echo ""

# ============================================================================
# Test 4: HTTPS Health Check
# ============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Test 4: HTTPS Health Check"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

HEALTH_CHECK=$(curl -k -s https://localhost/healthz 2>/dev/null || echo "FAILED")
echo "  Local Test:         curl -k https://localhost/healthz"
echo "  Response:           $HEALTH_CHECK"
echo ""

if [ "$HEALTH_CHECK" = "OK" ]; then
    echo "  ✅ PASS: HTTPS endpoint responding"
else
    echo "  ❌ ISSUE: HTTPS endpoint not responding"
    echo "     → Check Caddy logs: docker logs whisperlive-edge --tail 50"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
fi
echo ""

# ============================================================================
# Test 5: GPU Connectivity from Edge
# ============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Test 5: GPU Connectivity from Edge"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Dynamic IP lookup from instance ID (preferred)
GPU_IP=""
if [ -n "${GPU_INSTANCE_ID:-}" ] && command -v get_instance_ip >/dev/null 2>&1; then
    log_info "Looking up GPU IP from instance ID: $GPU_INSTANCE_ID"
    GPU_IP=$(get_instance_ip "$GPU_INSTANCE_ID")
    if [ -n "$GPU_IP" ] && [ "$GPU_IP" != "None" ]; then
        echo "  GPU Instance ID:    $GPU_INSTANCE_ID"
        echo "  GPU IP (dynamic):   $GPU_IP"
    else
        echo "  ⚠️  Dynamic IP lookup failed"
        GPU_IP="${GPU_INSTANCE_IP:-}"
    fi
else
    # Fallback to static variable (deprecated)
    GPU_IP="${GPU_INSTANCE_IP:-}"
    if [ -n "$GPU_IP" ]; then
        echo "  ⚠️  Using static GPU_INSTANCE_IP (deprecated)"
        echo "  GPU IP (static):    $GPU_IP"
        echo "     → Recommended: Set GPU_INSTANCE_ID in .env for dynamic lookup"
    fi
fi

if [ -n "$GPU_IP" ]; then
    echo "  GPU Port:           ${GPU_PORT:-9090}"
    echo ""

    GPU_TEST=$(curl -s http://$GPU_IP:${GPU_PORT:-9090} 2>&1 | grep -o "426 Upgrade Required" || echo "FAILED")

    if [ "$GPU_TEST" = "426 Upgrade Required" ]; then
        echo "  ✅ PASS: GPU WhisperLive is reachable"
        echo "     (426 is expected - WebSocket requires upgrade)"
    else
        echo "  ❌ ISSUE: Cannot connect to GPU WhisperLive"
        if [ -n "${GPU_INSTANCE_ID:-}" ]; then
            echo "     → Check GPU is running: aws ec2 describe-instances --instance-ids $GPU_INSTANCE_ID"
        fi
        echo "     → Check security groups allow edge→GPU on port ${GPU_PORT:-9090}"
        echo "     → Run: ./scripts/030-configure-gpu-security.sh"
        ISSUES_FOUND=$((ISSUES_FOUND + 1))
    fi
else
    echo "  ⚠️  SKIP: GPU not configured in .env"
    echo "     → Set GPU_INSTANCE_ID in .env for dynamic lookup"
    echo "     → Or set GPU_INSTANCE_IP for static configuration"
    echo "     (Transcription will not work without GPU)"
fi
echo ""

# ============================================================================
# Test 6: WebSocket Endpoint
# ============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Test 6: WebSocket Endpoint Test"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Test WebSocket upgrade (simulated)
WS_TEST=$(curl -k -s -i -N \
    -H "Connection: Upgrade" \
    -H "Upgrade: websocket" \
    -H "Sec-WebSocket-Version: 13" \
    -H "Sec-WebSocket-Key: test" \
    https://localhost/ws 2>&1 | head -1 | grep -oP 'HTTP/\S+ \K\d+' || echo "FAILED")

echo "  WebSocket URL:      wss://$CURRENT_IP/ws"
echo "  Response Code:      $WS_TEST"
echo ""

if [ "$WS_TEST" = "426" ] || [ "$WS_TEST" = "101" ]; then
    echo "  ✅ PASS: WebSocket endpoint available"
    echo "     (426 = requires proper WebSocket client)"
else
    echo "  ❌ ISSUE: WebSocket endpoint not responding correctly"
    echo "     → Check Caddyfile reverse_proxy config"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
fi
echo ""

# ============================================================================
# Test 7: Browser Certificate Trust Check
# ============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Test 7: Browser Certificate Trust Instructions"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "  ⚠️  IMPORTANT: Browser must accept self-signed certificate"
echo ""
echo "  To test from your browser:"
echo "    1. Open: https://$CURRENT_IP/healthz"
echo "    2. Accept certificate warning (Advanced → Proceed)"
echo "    3. You should see: OK"
echo "    4. Now WebSocket connections will work"
echo ""
echo "  To verify WebSocket in browser console:"
echo "    - Open DevTools → Console"
echo "    - Look for: 'WhisperLive WebSocket connected'"
echo "    - NOT: 'WebSocket connection failed'"
echo ""

# ============================================================================
# Summary
# ============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "DIAGNOSTIC SUMMARY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ $ISSUES_FOUND -eq 0 ]; then
    echo "  ✅ ALL TESTS PASSED"
    echo ""
    echo "  Your edge box appears to be configured correctly!"
    echo ""
    echo "  If WebSocket still fails in browser:"
    echo "    1. Make sure you accepted the certificate at: https://$CURRENT_IP/healthz"
    echo "    2. Do a hard refresh: Ctrl+Shift+R (Cmd+Shift+R on Mac)"
    echo "    3. Check browser console for error messages"
    echo ""
else
    echo "  ❌ FOUND $ISSUES_FOUND ISSUE(S)"
    echo ""
    echo "  Recommended Actions:"
    echo "    1. Run: ./scripts/825-update-edge-box-ip.sh"
    echo "    2. Review error messages above"
    echo "    3. Run this diagnostic again to verify fixes"
    echo ""
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
