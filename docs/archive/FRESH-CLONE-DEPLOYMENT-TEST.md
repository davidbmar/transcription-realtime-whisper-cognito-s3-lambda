# Fresh Clone Deployment Test - Google Docs v6.4.0

## ✅ VERIFIED: Everything needed is in git

This documents what someone would experience starting from a fresh `git clone`.

## Prerequisites (User Must Provide)

These are **intentionally NOT in git** (sensitive/user-specific):

1. **AWS Account** with credentials configured (`aws configure`)
2. **Google Cloud Project** with Docs API enabled
3. **Service Account credentials.json** - Download from Google Cloud Console
4. **Google Doc** - Create a blank doc, copy the ID from URL

## Step-by-Step Deployment Path

### 1. Clone Repository
```bash
git clone https://github.com/davidbmar/transcription-realtime-whisper-cognito-s3-lambda.git
cd transcription-realtime-whisper-cognito-s3-lambda
```

**What's already there:**
- ✅ `cognito-stack/api/google-docs.js` - v6.4.0 with dynamic positioning fix
- ✅ `cognito-stack/serverless.yml` - All 3 Google Docs Lambda functions defined
- ✅ `cognito-stack/package.json` - googleapis@^128.0.0 dependency
- ✅ `scripts/510-setup-google-docs-integration.sh` - Complete automated setup
- ✅ `ui-source/audio.html` - v6.4.0 with `TO_BE_REPLACED_GOOGLE_DOC_ID` placeholder
- ✅ `scripts/425-deploy-recorder-ui.sh` - Handles GOOGLE_DOC_ID injection
- ✅ `.env.example` - Template with Google vars documented

### 2. Initial Configuration
```bash
./scripts/005-setup-configuration.sh
```

**What it does:**
- Creates `.env` from `.env.example`
- Prompts for AWS region, service name, etc.
- Does NOT prompt for Google Docs vars yet (that's in script 510)

### 3. Deploy Cognito Backend
```bash
./scripts/410-questions-setup-cognito-s3-lambda.sh
./scripts/420-deploy-cognito-stack.sh
```

**What it does:**
- Creates Cognito User Pool, S3 bucket, CloudFront distribution
- Deploys Lambda functions (including Google Docs ones, but not configured yet)
- Updates `.env` with `COGNITO_API_ENDPOINT`, `COGNITO_CLOUDFRONT_URL`, etc.
- **NOTE:** Google Docs functions deploy but won't work yet (no credentials)

### 4. Google Docs Integration Setup
```bash
./scripts/510-setup-google-docs-integration.sh
```

**What it prompts for:**
1. Google Doc ID (paste from `https://docs.google.com/document/d/YOUR_ID/edit`)
2. Path to credentials.json (defaults to `google-docs-test/credentials.json`)

**What it does automatically:**
1. Validates credentials.json is valid JSON
2. Base64-encodes credentials → saves to `.env` as `GOOGLE_CREDENTIALS_BASE64`
3. Saves `GOOGLE_DOC_ID` to `.env`
4. Saves `GOOGLE_CREDENTIALS_PATH` to `.env`
5. Runs `npm install` in cognito-stack/ (installs googleapis)
6. Exports `COGNITO_CLOUDFRONT_URL` and `GOOGLE_CREDENTIALS_BASE64` env vars
7. Runs `npx serverless deploy` (deploys v6.4.0 Lambda code)
8. Calls `./scripts/425-deploy-recorder-ui.sh` (deploys v6.4.0 UI with Google Doc ID)
9. Shows instructions for sharing doc with service account

### 5. Share Google Doc with Service Account
```bash
# Script 510 output will show:
# "Service Account Email: your-service-account@project.iam.gserviceaccount.com"
```

**Manual step:**
1. Open Google Doc
2. Click "Share"
3. Paste service account email
4. Grant "Editor" permissions
5. Click "Send"

### 6. Test the Integration
```bash
# Open in browser:
https://YOUR_CLOUDFRONT_URL/audio.html

# Or use check-formatting utility:
cd google-docs-test
./check-formatting.py
```

## Verification Checklist

After following the above steps, verify:

- [ ] `cognito-stack/api/google-docs.js` contains "IGNORE stale frontend index" comment (v6.4.0 fix)
- [ ] `cognito-stack/serverless.yml` has `initializeGoogleDocsLiveSection`, `updateGoogleDocsLiveTranscription`, `finalizeGoogleDocsTranscription`
- [ ] `cognito-stack/package.json` has `"googleapis": "^128.0.0"`
- [ ] `.env` contains `GOOGLE_DOC_ID`, `GOOGLE_CREDENTIALS_BASE64`, `GOOGLE_CREDENTIALS_PATH`
- [ ] Audio recorder UI shows "v6.4.0" in header
- [ ] Recording shows live text as italic in Google Doc
- [ ] Finalized text appears as normal (non-italic) in Google Doc
- [ ] Lambda logs show "Update: Found session at X, live at Y"

## What's NOT in Git (By Design)

These files are gitignored for security:
- ❌ `.env` - Contains sensitive credentials
- ❌ `google-docs-test/credentials.json` - Google service account key
- ❌ `cognito-stack/web/*` - Generated deployment artifacts
- ❌ `logs/*` - Script execution logs

## Common Issues

### "GOOGLE_CREDENTIALS_BASE64 not set"
**Cause:** Script 420 deployed before script 510 ran
**Fix:** Run script 510 - it will redeploy with credentials

### "Failed to initialize live section"
**Cause:** Google Doc not shared with service account
**Fix:** Share doc with the email shown in script 510 output

### "Index X must be less than Y"
**Cause:** Old version of google-docs.js without v6.4.0 fix
**Fix:** Verify git is on latest commit, re-run script 510

### Finalized text appears italic
**Cause:** Old version without dynamic positioning fix
**Fix:** Verify google-docs.js has "IGNORE stale frontend index" comment

## Files Modified During Deployment

Script 510 automatically generates these (NOT in git):
- `cognito-stack/web/audio.html` - From `ui-source/audio.html` with GOOGLE_DOC_ID injected
- `cognito-stack/web/app.js` - From `ui-source/app.js.template` with config injected
- `.env` - Updated with Google Docs variables

## Summary

**YES**, someone can clone the repo and reach the current v6.4.0 state by running:

```bash
git clone <repo>
./scripts/005-setup-configuration.sh          # Configure AWS/region
./scripts/410-questions-setup-cognito-s3-lambda.sh  # Prepare backend
./scripts/420-deploy-cognito-stack.sh         # Deploy backend
./scripts/510-setup-google-docs-integration.sh  # Setup Google Docs (includes redeployment)
```

The only things they need to provide:
1. AWS credentials
2. Google Cloud credentials.json
3. Google Doc ID
4. Share the doc with the service account

Everything else is automated and in git!
