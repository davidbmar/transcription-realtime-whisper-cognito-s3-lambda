# UI Source Files - Important!

## ✅ Source of Truth (ALWAYS EDIT THESE)

These are template files with `TO_BE_REPLACED_*` placeholders:

- **`audio.html.template`** - Main audio recorder (v6.7.0) ← **EDIT THIS**
- **`transcript-editor.html.template`** - Transcript editor ← **EDIT THIS**
- **`transcript-editor-v2.html.template`** - Transcript editor v2 ← **EDIT THIS**
- **`app.js.template`** - App configuration ← **EDIT THIS**

## ⚠️ Deprecated Files (DO NOT EDIT)

These files are kept for reference/backwards compatibility only:

- `audio.html` - Old version (gets overwritten by template during deployment)
- `audio.html.with-google-docs-backup` - Backup from previous version

## 📝 How to Make Changes

### 1. Edit the Template
```bash
# Edit the source template
vim ui-source/audio.html.template

# Make your changes (version updates, features, etc.)
```

### 2. Deploy
```bash
# Run deployment script
./scripts/425-deploy-recorder-ui.sh

# This will:
# - Copy audio.html.template → cognito-stack/web/audio.html
# - Replace TO_BE_REPLACED_* with values from .env
# - Upload to S3
# - Invalidate CloudFront cache
```

### 3. Verify
```bash
# Check deployed version
curl -s https://d2l28rla2hk7np.cloudfront.net/audio.html | grep -i version
```

## 🔧 Placeholders Used

| Placeholder | .env Variable | Example Value |
|-------------|---------------|---------------|
| `TO_BE_REPLACED_USER_POOL_ID` | `COGNITO_USER_POOL_ID` | `us-east-2_6sN45GbIh` |
| `TO_BE_REPLACED_USER_POOL_CLIENT_ID` | `COGNITO_USER_POOL_CLIENT_ID` | `7sjtp1gd6buhs...` |
| `TO_BE_REPLACED_IDENTITY_POOL_ID` | `COGNITO_IDENTITY_POOL_ID` | `us-east-2:43b4ec...` |
| `TO_BE_REPLACED_REGION` | `AWS_REGION` | `us-east-2` |
| `TO_BE_REPLACED_AUDIO_API_URL` | `COGNITO_API_ENDPOINT` | `https://5x0ygiv...` |
| `TO_BE_REPLACED_APP_URL` | `COGNITO_CLOUDFRONT_URL` | `https://d2l28r...` |
| `TO_BE_REPLACED_WHISPERLIVE_WS_URL` | `WHISPERLIVE_WS_URL` | `wss://3.144.125.139/ws` |
| `TO_BE_REPLACED_GOOGLE_DOC_ID` | `GOOGLE_DOC_ID` | `1U_dJ9wyr2_RZ...` |

## 📦 Version History

- **v6.7.0** (2025-11-18) - Added Wake Lock API + Chunk Size Validation
- **v6.6.0** - Previous version with Google Docs integration
- **v6.5.0** - Earlier version

## 🚫 Common Mistakes

❌ **DON'T DO THIS:**
```bash
# Editing the deprecated file
vim ui-source/audio.html  # WRONG! Gets overwritten
```

✅ **DO THIS:**
```bash
# Editing the template
vim ui-source/audio.html.template  # CORRECT!
```

## 🔍 How to Tell Which File is Which

**Template files:**
- Have header comment: `✅ THIS IS THE SOURCE OF TRUTH`
- Contain `TO_BE_REPLACED_*` placeholders
- Should be edited for changes

**Deprecated files:**
- Have header comment: `⚠️ WARNING: DO NOT EDIT`
- May have hardcoded values or old placeholders
- Kept for reference only
