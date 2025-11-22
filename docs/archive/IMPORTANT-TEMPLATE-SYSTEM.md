# ⚠️ CRITICAL: Template System Documentation

**Last Updated:** 2025-11-18
**Version:** 6.7.0

---

## 🚨 READ THIS FIRST

If you're about to edit `audio.html`, **STOP!**

You probably want to edit `audio.html.template` instead.

---

## Quick Reference

### ✅ DO EDIT THESE FILES:
```
ui-source/
├── audio.html.template          ← EDIT THIS (3,444 lines, full-featured)
├── transcript-editor.html.template
├── transcript-editor-v2.html.template
└── app.js.template
```

### ⚠️ DO NOT EDIT THESE FILES:
```
ui-source/
├── audio.html                   ← DO NOT EDIT (deprecated)
└── audio.html.with-google-docs-backup

cognito-stack/web/
└── *.html                       ← DO NOT EDIT (auto-generated)
```

---

## How It Works

### 1. Template System Flow

```
┌─────────────────────────────────────────────────────────────┐
│                                                             │
│  ui-source/audio.html.template                             │
│  (Source of Truth - 3,444 lines)                           │
│                                                             │
│  Contains placeholders:                                     │
│  - TO_BE_REPLACED_USER_POOL_ID                            │
│  - TO_BE_REPLACED_REGION                                  │
│  - etc.                                                     │
│                                                             │
└─────────────────┬───────────────────────────────────────────┘
                  │
                  │ ./scripts/425-deploy-recorder-ui.sh
                  │
                  ▼
┌─────────────────────────────────────────────────────────────┐
│                                                             │
│  cognito-stack/web/audio.html                              │
│  (Auto-generated during deployment)                         │
│                                                             │
│  Placeholders replaced with .env values:                    │
│  - us-east-2_6sN45GbIh                                     │
│  - us-east-2                                               │
│  - etc.                                                     │
│                                                             │
└─────────────────┬───────────────────────────────────────────┘
                  │
                  │ aws s3 sync + CloudFront invalidation
                  │
                  ▼
┌─────────────────────────────────────────────────────────────┐
│                                                             │
│  S3 / CloudFront                                           │
│  https://d2l28rla2hk7np.cloudfront.net/audio.html         │
│                                                             │
│  Live production site                                       │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 2. Why Templates?

**Problem Without Templates:**
```javascript
// Hardcoded credentials in source code
const config = {
  userPoolId: 'us-east-2_6sN45GbIh',  // ❌ Exposed in git
  apiUrl: 'https://5x0ygivhe1...',     // ❌ Hard to change
};
```

**Solution With Templates:**
```javascript
// Placeholders in template
const config = {
  userPoolId: 'TO_BE_REPLACED_USER_POOL_ID',  // ✅ Safe for git
  apiUrl: 'TO_BE_REPLACED_AUDIO_API_URL',     // ✅ Flexible
};
```

During deployment, `sed` replaces placeholders with values from `.env`.

---

## Making Changes

### Step-by-Step Guide

**1. Edit the template:**
```bash
vim ui-source/audio.html.template

# Make your changes
# - Update version number
# - Add features
# - Fix bugs
```

**2. Deploy:**
```bash
./scripts/425-deploy-recorder-ui.sh

# This will:
# - Copy template to cognito-stack/web/audio.html
# - Replace TO_BE_REPLACED_* with .env values
# - Upload to S3
# - Invalidate CloudFront cache
```

**3. Verify:**
```bash
# Wait 1-2 minutes for CloudFront cache to clear
# Then check deployment:
curl -s https://d2l28rla2hk7np.cloudfront.net/audio.html | head -30
```

---

## Common Mistakes

### ❌ Mistake #1: Editing the Wrong File
```bash
# WRONG
vim ui-source/audio.html        # This file gets overwritten!

# CORRECT
vim ui-source/audio.html.template
```

### ❌ Mistake #2: Forgetting to Deploy
```bash
# Made changes to template but...
git add ui-source/audio.html.template
git commit -m "Updated feature"

# Users still see old version! Need to deploy:
./scripts/425-deploy-recorder-ui.sh
```

### ❌ Mistake #3: Editing Generated Files
```bash
# WRONG
vim cognito-stack/web/audio.html   # Auto-generated, will be overwritten!

# CORRECT
vim ui-source/audio.html.template
```

---

## File Identification

### How to Tell Which File You're Looking At

**Template File (Source of Truth):**
```html
<!doctype html>
<!--
  ✅ THIS IS THE SOURCE OF TRUTH - ALWAYS EDIT THIS FILE ✅

  File: ui-source/audio.html.template
  Version: 6.7.0 (2025-11-18)
  ...
-->
```

**Deprecated File (DO NOT EDIT):**
```html
<!doctype html>
<!--
  ⚠️ WARNING: DO NOT EDIT THIS FILE DIRECTLY ⚠️

  This file is DEPRECATED and should NOT be modified.
  ALWAYS EDIT: audio.html.template instead!
  ...
-->
```

**Generated File (Auto-created):**
```html
<!doctype html>
<!--
  ✅ THIS IS THE SOURCE OF TRUTH - ALWAYS EDIT THIS FILE ✅
  ...
-->
<html lang="en">
<head>
  ...
  const config = {
    userPoolId: 'us-east-2_6sN45GbIh',  // ← Real values, not placeholders
```

---

## Placeholders Reference

| Placeholder | .env Variable | Example |
|-------------|---------------|---------|
| `TO_BE_REPLACED_USER_POOL_ID` | `COGNITO_USER_POOL_ID` | `us-east-2_6sN45GbIh` |
| `TO_BE_REPLACED_USER_POOL_CLIENT_ID` | `COGNITO_USER_POOL_CLIENT_ID` | `7sjtp1gd6buhs...` |
| `TO_BE_REPLACED_IDENTITY_POOL_ID` | `COGNITO_IDENTITY_POOL_ID` | `us-east-2:43b4ec...` |
| `TO_BE_REPLACED_REGION` | `AWS_REGION` | `us-east-2` |
| `TO_BE_REPLACED_AUDIO_API_URL` | `COGNITO_API_ENDPOINT` | `https://5x0ygiv...` |
| `TO_BE_REPLACED_APP_URL` | `COGNITO_CLOUDFRONT_URL` | `https://d2l28r...` |
| `TO_BE_REPLACED_WHISPERLIVE_WS_URL` | `WHISPERLIVE_WS_URL` | `wss://3.144.125.139/ws` |
| `TO_BE_REPLACED_GOOGLE_DOC_ID` | `GOOGLE_DOC_ID` | `1U_dJ9wyr2_RZ...` |

---

## Troubleshooting

### Problem: Changes Not Appearing

**Symptoms:**
- Edited template
- Deployed
- Still seeing old version

**Solution:**
```bash
# 1. Check which file you edited
head -20 ui-source/audio.html.template  # Should see "SOURCE OF TRUTH"

# 2. Verify deployment used template
grep "audio.html.template" scripts/425-deploy-recorder-ui.sh
# Should show: cp "$SOURCE_UI_DIR/audio.html.template" ./audio.html

# 3. Clear CloudFront cache (deployment should do this)
./scripts/425-deploy-recorder-ui.sh

# 4. Hard refresh browser
# Chrome/Firefox: Ctrl+Shift+R
# Safari: Cmd+Shift+R
```

### Problem: Placeholders Not Replaced

**Symptoms:**
- Deployed but seeing `TO_BE_REPLACED_USER_POOL_ID` in browser

**Solution:**
```bash
# 1. Check .env has values
cat .env | grep COGNITO_USER_POOL_ID
# Should show: COGNITO_USER_POOL_ID=us-east-2_...

# 2. Check sed commands ran
tail -100 logs/425-deploy-*.log | grep "Configuration updated"

# 3. Check generated file
cat cognito-stack/web/audio.html | grep userPoolId
# Should show real value, not placeholder
```

---

## Version History

- **v6.7.0** (2025-11-18) - Template system fixed, Wake Lock API, chunk validation
- **v6.6.0** - Google Docs integration
- **v6.5.0** - Earlier version

See `CHANGELOG-v6.7.0.md` for detailed version history.

---

## Related Documentation

- `ui-source/README.md` - Detailed template documentation
- `CHANGELOG-v6.7.0.md` - Recent changes and fixes
- `CLAUDE.md` - Full repository documentation
- `scripts/425-deploy-recorder-ui.sh` - Deployment script

---

## Quick Commands

```bash
# Edit source template
vim ui-source/audio.html.template

# Deploy changes
./scripts/425-deploy-recorder-ui.sh

# Verify deployment
curl -s https://d2l28rla2hk7np.cloudfront.net/audio.html | grep -i version

# Check which file is which
head -20 ui-source/audio.html.template    # Source of truth
head -20 ui-source/audio.html              # Deprecated
head -20 cognito-stack/web/audio.html     # Auto-generated
```

---

**Remember:** When in doubt, edit `ui-source/audio.html.template` and run the deployment script!
