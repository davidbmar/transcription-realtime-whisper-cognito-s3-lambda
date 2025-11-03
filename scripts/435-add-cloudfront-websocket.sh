#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Script 435: Add CloudFront WebSocket Support for WhisperLive
# ============================================================================
# Adds the edge box as a custom origin to CloudFront and creates a /ws
# behavior to route WebSocket traffic through CloudFront instead of direct
# connection to the edge box.
#
# What this does:
# 1. Gets current CloudFront distribution configuration
# 2. Adds edge box as a custom origin (HTTPS with proper headers)
# 3. Creates /ws cache behavior with WebSocket support
# 4. Updates CloudFront distribution
# 5. Updates .env with new WSS URL (wss://cloudfront-domain/ws)
# 6. Waits for CloudFront deployment to complete
#
# Benefits:
# - Better certificate management (CloudFront cert vs self-signed)
# - DDoS protection
# - Consistent domain for static assets and WebSocket
# - Better error handling and monitoring
# ============================================================================

# Find repository root
if [ -L "${BASH_SOURCE[0]}" ]; then
    SCRIPT_REAL=$(readlink -f "${BASH_SOURCE[0]}")
else
    SCRIPT_REAL="${BASH_SOURCE[0]}"
fi
REPO_ROOT="$(cd "$(dirname "$SCRIPT_REAL")/.." && pwd)"

source "$REPO_ROOT/scripts/lib/common-functions.sh"
load_environment

# Validate required variables
if [ -z "${COGNITO_CLOUDFRONT_URL:-}" ]; then
    log_error "COGNITO_CLOUDFRONT_URL not set in .env"
    exit 1
fi

if [ -z "${EDGE_BOX_DNS:-}" ]; then
    log_error "EDGE_BOX_DNS not set in .env"
    exit 1
fi

CLOUDFRONT_DOMAIN=$(echo "$COGNITO_CLOUDFRONT_URL" | sed 's|https://||' | sed 's|/.*||')
DISTRIBUTION_ID=$(aws cloudfront list-distributions --query "DistributionList.Items[?DomainName=='$CLOUDFRONT_DOMAIN'].Id" --output text)

if [ -z "$DISTRIBUTION_ID" ]; then
    log_error "Could not find CloudFront distribution for $CLOUDFRONT_DOMAIN"
    exit 1
fi

log_info "🌐 Adding WebSocket support to CloudFront"
log_info "Distribution ID: $DISTRIBUTION_ID"
log_info "Edge Box: $EDGE_BOX_DNS"
echo ""

# ============================================================================
# Step 1: Get current CloudFront configuration
# ============================================================================
log_info "Step 1/6: Fetching current CloudFront configuration..."

aws cloudfront get-distribution-config --id "$DISTRIBUTION_ID" > /tmp/cf-config.json

ETAG=$(jq -r '.ETag' /tmp/cf-config.json)
jq '.DistributionConfig' /tmp/cf-config.json > /tmp/cf-dist-config.json

log_success "✅ Retrieved configuration (ETag: $ETAG)"
echo ""

# ============================================================================
# Step 2: Add edge box as custom origin (if not exists)
# ============================================================================
log_info "Step 2/6: Adding edge box as custom origin..."

# Check if edge origin already exists
EDGE_ORIGIN_EXISTS=$(jq --arg domain "$EDGE_BOX_DNS" '.Origins.Items[] | select(.Id=="EdgeBoxOrigin") | .Id' /tmp/cf-dist-config.json || echo "")

if [ -n "$EDGE_ORIGIN_EXISTS" ]; then
    log_info "Edge box origin already exists, updating..."

    # Update existing origin
    jq --arg domain "$EDGE_BOX_DNS" '
        .Origins.Items |= map(
            if .Id == "EdgeBoxOrigin" then
                .DomainName = $domain |
                .CustomOriginConfig.HTTPSPort = 443 |
                .CustomOriginConfig.OriginProtocolPolicy = "https-only"
            else . end
        )
    ' /tmp/cf-dist-config.json > /tmp/cf-dist-config-updated.json
else
    log_info "Adding new edge box origin..."

    # Add new origin
    jq --arg domain "$EDGE_BOX_DNS" '
        .Origins.Quantity += 1 |
        .Origins.Items += [{
            "Id": "EdgeBoxOrigin",
            "DomainName": $domain,
            "OriginPath": "",
            "CustomHeaders": {
                "Quantity": 0
            },
            "CustomOriginConfig": {
                "HTTPPort": 80,
                "HTTPSPort": 443,
                "OriginProtocolPolicy": "https-only",
                "OriginSslProtocols": {
                    "Quantity": 3,
                    "Items": ["TLSv1", "TLSv1.1", "TLSv1.2"]
                },
                "OriginReadTimeout": 30,
                "OriginKeepaliveTimeout": 5
            },
            "ConnectionAttempts": 3,
            "ConnectionTimeout": 10,
            "OriginShield": {
                "Enabled": false
            }
        }]
    ' /tmp/cf-dist-config.json > /tmp/cf-dist-config-updated.json
fi

mv /tmp/cf-dist-config-updated.json /tmp/cf-dist-config.json
log_success "✅ Edge box origin configured"
echo ""

# ============================================================================
# Step 3: Add /ws cache behavior for WebSocket (if not exists)
# ============================================================================
log_info "Step 3/6: Configuring /ws cache behavior for WebSocket..."

# Check if /ws behavior already exists
WS_BEHAVIOR_EXISTS=$(jq '.CacheBehaviors.Items[] | select(.PathPattern=="/ws") | .PathPattern' /tmp/cf-dist-config.json || echo "")

if [ -n "$WS_BEHAVIOR_EXISTS" ]; then
    log_info "WebSocket behavior already exists, updating..."

    jq '
        .CacheBehaviors.Items |= map(
            if .PathPattern == "/ws" then
                .TargetOriginId = "EdgeBoxOrigin" |
                .ViewerProtocolPolicy = "https-only" |
                .AllowedMethods.Quantity = 7 |
                .AllowedMethods.Items = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"] |
                .AllowedMethods.CachedMethods.Quantity = 2 |
                .AllowedMethods.CachedMethods.Items = ["GET", "HEAD"] |
                .Compress = false |
                .ForwardedValues.QueryString = true |
                .ForwardedValues.Headers.Quantity = 4 |
                .ForwardedValues.Headers.Items = ["Upgrade", "Connection", "Sec-WebSocket-Key", "Sec-WebSocket-Version"] |
                .ForwardedValues.Cookies.Forward = "none" |
                .MinTTL = 0 |
                .DefaultTTL = 0 |
                .MaxTTL = 0
            else . end
        )
    ' /tmp/cf-dist-config.json > /tmp/cf-dist-config-updated.json
else
    log_info "Adding new WebSocket behavior..."

    jq '
        .CacheBehaviors.Quantity += 1 |
        .CacheBehaviors.Items += [{
            "PathPattern": "/ws",
            "TargetOriginId": "EdgeBoxOrigin",
            "TrustedSigners": {
                "Enabled": false,
                "Quantity": 0
            },
            "TrustedKeyGroups": {
                "Enabled": false,
                "Quantity": 0
            },
            "ViewerProtocolPolicy": "https-only",
            "AllowedMethods": {
                "Quantity": 7,
                "Items": ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"],
                "CachedMethods": {
                    "Quantity": 2,
                    "Items": ["GET", "HEAD"]
                }
            },
            "SmoothStreaming": false,
            "Compress": false,
            "LambdaFunctionAssociations": {
                "Quantity": 0
            },
            "FunctionAssociations": {
                "Quantity": 0
            },
            "FieldLevelEncryptionId": "",
            "ForwardedValues": {
                "QueryString": true,
                "Cookies": {
                    "Forward": "none"
                },
                "Headers": {
                    "Quantity": 4,
                    "Items": ["Upgrade", "Connection", "Sec-WebSocket-Key", "Sec-WebSocket-Version"]
                }
            },
            "MinTTL": 0,
            "DefaultTTL": 0,
            "MaxTTL": 0
        }]
    ' /tmp/cf-dist-config.json > /tmp/cf-dist-config-updated.json
fi

mv /tmp/cf-dist-config-updated.json /tmp/cf-dist-config.json
log_success "✅ WebSocket behavior configured"
echo ""

# ============================================================================
# Step 4: Update CloudFront distribution
# ============================================================================
log_info "Step 4/6: Updating CloudFront distribution..."

aws cloudfront update-distribution \
    --id "$DISTRIBUTION_ID" \
    --if-match "$ETAG" \
    --distribution-config file:///tmp/cf-dist-config.json \
    > /tmp/cf-update-result.json

NEW_ETAG=$(jq -r '.ETag' /tmp/cf-update-result.json)
log_success "✅ CloudFront distribution updated (new ETag: $NEW_ETAG)"
echo ""

# ============================================================================
# Step 5: Update .env with new WebSocket URL
# ============================================================================
log_info "Step 5/6: Updating .env with CloudFront WebSocket URL..."

NEW_WS_URL="wss://$CLOUDFRONT_DOMAIN/ws"

if grep -q "^WHISPERLIVE_WS_URL=" .env 2>/dev/null; then
    sed -i "s|^WHISPERLIVE_WS_URL=.*|WHISPERLIVE_WS_URL=$NEW_WS_URL|" .env
else
    echo "WHISPERLIVE_WS_URL=$NEW_WS_URL" >> .env
fi

log_success "✅ Updated WHISPERLIVE_WS_URL=$NEW_WS_URL"
echo ""

# ============================================================================
# Step 6: Wait for CloudFront deployment
# ============================================================================
log_info "Step 6/6: Waiting for CloudFront deployment..."
log_info "This typically takes 3-5 minutes..."

aws cloudfront wait distribution-deployed --id "$DISTRIBUTION_ID"

log_success "✅ CloudFront deployment complete"
echo ""

# ============================================================================
# Summary
# ============================================================================
log_success "========================================="
log_success "✅ CLOUDFRONT WEBSOCKET SETUP COMPLETE"
log_success "========================================="
echo ""
log_info "WebSocket Configuration:"
echo "  CloudFront Domain: $CLOUDFRONT_DOMAIN"
echo "  WebSocket URL: $NEW_WS_URL"
echo "  Edge Box Origin: $EDGE_BOX_DNS"
echo ""
log_info "Next Steps:"
echo "  1. Redeploy UI: ./scripts/425-deploy-recorder-ui.sh"
echo "  2. Test WebSocket: Open browser at $COGNITO_CLOUDFRONT_URL/audio.html"
echo "  3. Monitor: Check browser console for WebSocket connection"
echo ""
log_warn "Note: You may need to clear browser cache or hard refresh (Ctrl+Shift+R)"
echo ""
