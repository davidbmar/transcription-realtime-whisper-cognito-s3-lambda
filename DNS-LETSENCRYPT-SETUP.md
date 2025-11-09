# DNS and Let's Encrypt SSL Setup Guide

## Overview

This guide explains how to configure a custom domain with Let's Encrypt SSL for the WhisperLive edge box, eliminating browser certificate warnings.

## Current Configuration

- **Domain:** `transcribe.davidbmar.com`
- **SSL Certificate:** Let's Encrypt (trusted by all browsers)
- **WebSocket URL:** `wss://transcribe.davidbmar.com/ws`
- **Edge Box IP:** `3.16.164.228`

## One-Time Setup (Already Completed)

### 1. DNS Configuration (Route53)

**Created DNS A record:**
```
Record name: transcribe.davidbmar.com
Type: A
Value: 3.16.164.228
TTL: 300 seconds
```

This points your domain to the edge box public IP address.

### 2. Edge Box Configuration

**Ran script:** `./scripts/306-setup-edge-domain-letsencrypt.sh transcribe.davidbmar.com`

**What it did:**
1. ✅ Verified DNS is configured correctly
2. ✅ Updated Caddyfile to use domain instead of IP
3. ✅ Caddy automatically obtained Let's Encrypt certificate
4. ✅ Updated `.env` with new WebSocket URL
5. ✅ Restarted Caddy container
6. ✅ Certificate auto-renews every 90 days

### 3. UI Deployment

**Ran script:** `./scripts/425-deploy-recorder-ui.sh`

**What it did:**
1. ✅ Updated `app.js` with new WebSocket URL: `wss://transcribe.davidbmar.com/ws`
2. ✅ Deployed files to S3
3. ✅ Invalidated CloudFront cache

## Benefits of This Setup

### Before (IP-Based SSL)

- ❌ Self-signed certificate
- ❌ Browser security warnings
- ❌ Must manually accept certificate in every browser
- ❌ Certificate breaks when IP changes
- ❌ Need to regenerate and re-accept after each IP change

### After (Domain-Based Let's Encrypt)

- ✅ Trusted SSL certificate (Let's Encrypt)
- ✅ No browser warnings
- ✅ Works in all browsers automatically
- ✅ Certificate stays valid when IP changes
- ✅ Auto-renewal every 90 days (zero maintenance)

## How It Works

### SSL Certificate

**Certificate is tied to DOMAIN, not IP:**
- Certificate: `transcribe.davidbmar.com` ✅ Valid
- Works even if IP changes: `3.16.164.228` → `new-ip` ✅ Still valid
- Browser trusts Let's Encrypt certificate authority

### When Edge Box IP Changes

**What happens:**
1. Edge box stops/starts → New IP assigned (e.g., `3.16.164.228` → `3.137.2.81`)
2. DNS still points to old IP → Domain unreachable
3. SSL certificate still valid (tied to domain, not IP)
4. **You manually update Route53** to point to new IP
5. DNS propagates (1-5 minutes)
6. Everything works - no certificate changes needed!

**What does NOT happen:**
- ❌ Certificate doesn't break
- ❌ No need to regenerate certificate
- ❌ No need to re-accept in browser
- ❌ No code changes needed

## Manual DNS Update Procedure

### When Edge Box IP Changes

**Step 1: Get New IP**
```bash
# From edge box
curl http://checkip.amazonaws.com

# Output example
3.137.2.81
```

**Step 2: Update Route53**

1. **Log into AWS Console** (your Route53 account)
2. **Go to Route53 → Hosted Zones → davidbmar.com**
3. **Find record:** `transcribe.davidbmar.com` (Type: A)
4. **Click Edit**
5. **Update Value:** Change to new IP (e.g., `3.137.2.81`)
6. **Save**

**Step 3: Verify DNS Propagation**
```bash
# Wait 1-5 minutes, then test
nslookup transcribe.davidbmar.com 8.8.8.8

# Should show new IP
Server:		8.8.8.8
Address:	8.8.8.8#53

Name:	transcribe.davidbmar.com
Address: 3.137.2.81
```

**Step 4: Test**
```bash
# Test HTTPS (should work immediately)
curl https://transcribe.davidbmar.com/healthz

# Output
OK
```

**That's it!** No certificate changes, no UI redeployment, no browser acceptance needed.

### Time Required

- **Manual DNS update:** 2 minutes
- **DNS propagation:** 1-5 minutes
- **Total:** ~7 minutes

## Automation Options

### Option 1: Keep Manual Updates (Current)

**Pros:**
- ✅ Simple
- ✅ No cross-account permissions needed
- ✅ IP changes are rare (only when stopping/starting edge box)
- ✅ Takes ~5 minutes

**Cons:**
- ⚠️ Manual intervention required

**Best for:** Development, infrequent IP changes

### Option 2: Elastic IP (Static IP)

**Setup:**
```bash
# Allocate Elastic IP (one-time)
aws ec2 allocate-address --region us-east-2

# Output
{
  "PublicIp": "3.137.2.81",
  "AllocationId": "eipalloc-1234567890abcdef0"
}

# Associate with edge box
aws ec2 associate-address \
    --instance-id i-YOUR-EDGE-BOX-ID \
    --allocation-id eipalloc-1234567890abcdef0

# Update Route53 once to point to Elastic IP
# Never update again - IP never changes!
```

**Pros:**
- ✅ IP never changes (even when stopping/starting)
- ✅ Zero maintenance
- ✅ One-time Route53 update

**Cons:**
- ⚠️ Cost: $3.60/month when instance is stopped (free when running)

**Best for:** Production, frequent stop/start cycles

### Option 3: Cross-Account IAM Access (Fully Automated)

**Setup:**

1. **In Route53 AWS account**, create IAM user with Route53 update permissions
2. **Generate access keys**
3. **On edge box**, configure AWS credentials
4. **Create auto-update script** that runs on boot

**Script:**
```bash
#!/bin/bash
# /usr/local/bin/update-dns-on-boot.sh

NEW_IP=$(curl -s http://checkip.amazonaws.com)
HOSTED_ZONE_ID="Z1234567890ABC"
DOMAIN="transcribe.davidbmar.com"

aws route53 change-resource-record-sets \
    --profile route53 \
    --hosted-zone-id "$HOSTED_ZONE_ID" \
    --change-batch '{
        "Changes": [{
            "Action": "UPSERT",
            "ResourceRecordSet": {
                "Name": "'$DOMAIN'",
                "Type": "A",
                "TTL": 300,
                "ResourceRecords": [{"Value": "'$NEW_IP'"}]
            }
        }]
    }'
```

**Pros:**
- ✅ Fully automated
- ✅ No manual intervention
- ✅ Works across AWS accounts

**Cons:**
- ⚠️ Requires IAM setup and credentials
- ⚠️ Security consideration (access keys on edge box)

**Best for:** Automation enthusiasts, frequent IP changes

## Current Setup Details

### Files Modified

**`/home/ubuntu/event-b/whisper-live-test/Caddyfile`**
```
transcribe.davidbmar.com {
    # Caddy automatically obtains Let's Encrypt certificate

    @websockets {
        path /ws*
    }

    handle @websockets {
        reverse_proxy {env.GPU_HOST}:{env.GPU_PORT} {
            header_up Connection {http.request.header.Connection}
            header_up Upgrade {http.request.header.Upgrade}
        }
    }

    handle /healthz {
        respond "OK" 200
    }
}

http://transcribe.davidbmar.com {
    redir https://{host}{uri} permanent
}
```

**`.env`**
```bash
EDGE_BOX_DNS=transcribe.davidbmar.com
WHISPERLIVE_WS_URL=wss://transcribe.davidbmar.com/ws
```

**`ui-source/app.js.template`** (deployed to CloudFront)
```javascript
whisperLiveWsUrl: 'wss://transcribe.davidbmar.com/ws'
```

### Certificate Details

**Issuer:** Let's Encrypt Authority X3
**Valid:** 90 days (auto-renews at 60 days)
**Renewal:** Automatic (Caddy handles)
**Trust:** All major browsers

## Testing

### Test HTTPS Endpoint
```bash
curl https://transcribe.davidbmar.com/healthz

# Expected output
OK
```

### Test WebSocket Connection
```bash
# Python test
python3 << 'EOF'
import asyncio
import websockets

async def test():
    async with websockets.connect('wss://transcribe.davidbmar.com/ws') as ws:
        print("✅ WebSocket connected!")
        await ws.send('{"uid":"test","language":"en","task":"transcribe","model":"small.en"}')
        response = await ws.recv()
        print(f"Response: {response}")

asyncio.run(test())
EOF
```

### Test in Browser

1. **Open:** `https://d2l28rla2hk7np.cloudfront.net/audio.html`
2. **Login** with Cognito credentials
3. **Open browser console** (F12)
4. **Click "Start Recording"**
5. **Look for:**
   ```
   Connecting to: wss://transcribe.davidbmar.com/ws
   ✅ WhisperLive WebSocket connected
   ```
6. **Speak** and see transcriptions appear
7. **No certificate warnings!** ✅

## Troubleshooting

### Issue: DNS not resolving

**Check:**
```bash
nslookup transcribe.davidbmar.com 8.8.8.8
```

**Fix:**
- Verify Route53 A record exists
- Check TTL (300 seconds = 5 minutes)
- Wait for DNS propagation

### Issue: Certificate not trusted

**Check:**
```bash
docker logs whisperlive-edge | grep -i certificate
```

**Fix:**
```bash
# Restart Caddy to re-obtain certificate
cd /home/ubuntu/event-b/whisper-live-test
docker compose restart
```

### Issue: WebSocket connection fails

**Check:**
```bash
# Test WebSocket endpoint
curl -v https://transcribe.davidbmar.com/ws
```

**Fix:**
- Verify Caddyfile has correct domain
- Check Caddy logs: `docker logs whisperlive-edge -f`
- Ensure GPU WhisperLive is running

### Issue: Port 80/443 blocked

Let's Encrypt requires ports 80 and 443 for verification.

**Check security group:**
```bash
aws ec2 describe-security-groups \
    --group-ids sg-YOUR-EDGE-BOX-SG \
    --query 'SecurityGroups[0].IpPermissions'
```

**Required rules:**
- Port 80 (HTTP): 0.0.0.0/0 ✅ (for Let's Encrypt verification)
- Port 443 (HTTPS): 0.0.0.0/0 ✅ (for WebSocket connections)

## Maintenance

### Let's Encrypt Certificate Renewal

**Automatic:** Caddy handles renewal every 90 days
**No action required**

**Verify renewal is working:**
```bash
docker logs whisperlive-edge | grep -i "renewal\|renew"
```

### Certificate Expiration Check

**Check expiration date:**
```bash
echo | openssl s_client -connect transcribe.davidbmar.com:443 2>/dev/null | \
    openssl x509 -noout -dates
```

**Expected output:**
```
notBefore=Nov  9 19:21:00 2025 GMT
notAfter=Feb  7 19:20:59 2026 GMT
```

### Manual Certificate Renewal (if needed)

**Force renewal:**
```bash
cd /home/ubuntu/event-b/whisper-live-test
docker exec whisperlive-edge caddy reload --config /etc/caddy/Caddyfile
```

## Summary

### What You Have Now

✅ Domain: `transcribe.davidbmar.com`
✅ SSL: Let's Encrypt (trusted, auto-renewing)
✅ WebSocket: `wss://transcribe.davidbmar.com/ws`
✅ No browser warnings
✅ Works across all devices/browsers

### When IP Changes

**Manual Steps (5-7 minutes):**
1. Get new IP: `curl http://checkip.amazonaws.com`
2. Update Route53 A record to new IP
3. Wait 1-5 minutes for DNS propagation
4. Everything works - no certificate changes!

### Future Options

- **Add Elastic IP** ($3.60/month when stopped) → Never update DNS again
- **Automate DNS updates** (IAM cross-account) → Zero manual intervention
- **Keep manual updates** (current) → Simple, works great

## Related Scripts

- `scripts/306-setup-edge-domain-letsencrypt.sh` - Initial domain setup
- `scripts/425-deploy-recorder-ui.sh` - Deploy UI with new WebSocket URL
- `scripts/825-update-edge-box-ip.sh` - Update IP (for self-signed cert setup)
- `scripts/826-diagnose-edge-connection.sh` - Troubleshooting tool

## Support

If you have issues:

1. **Check Caddy logs:** `docker logs whisperlive-edge -f`
2. **Verify DNS:** `nslookup transcribe.davidbmar.com 8.8.8.8`
3. **Test HTTPS:** `curl -v https://transcribe.davidbmar.com/healthz`
4. **Check certificate:** View in browser (click lock icon in address bar)
