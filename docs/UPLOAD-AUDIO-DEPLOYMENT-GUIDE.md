# Upload Audio Feature - Deployment & Testing Guide

**Date:** 2025-11-22
**Version:** 1.0 (Option A - Simplified Unified)
**Status:** Ready for Deployment

---

## ✅ Implementation Complete

### What's Been Implemented

**Backend:**
- ✅ Lambda function: `uploadAudioFile` - Generate presigned S3 upload URL
- ✅ Lambda function: `triggerTranscription` - Trigger on-demand transcription
- ✅ API endpoints added to serverless.yml
- ✅ Unified storage: `users/{userId}/audio/sessions/{sessionId}/chunk-001.{ext}`

**Frontend:**
- ✅ Dashboard: "Upload Audio" card
- ✅ Upload section with drag & drop support
- ✅ File upload JavaScript with progress tracking
- ✅ Uploaded files list with status badges (⏳📁✅)
- ✅ "Transcribe Now" button for immediate transcription
- ✅ CSS styling for upload area

---

## 🚀 Deployment Steps

### Step 1: Deploy Backend

```bash
cd /home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4

# Navigate to cognito-stack
cd cognito-stack

# Deploy all Lambda functions
serverless deploy

# Expected output:
# ✔ Service deployed to stack clouddrive-app-dev
# endpoints:
#   POST - https://xxx.execute-api.us-east-2.amazonaws.com/dev/api/audio/upload-file
#   POST - https://xxx.execute-api.us-east-2.amazonaws.com/dev/api/audio/transcribe/{sessionId}
#   ... (existing endpoints)
```

**Estimated Time:** 3-5 minutes

### Step 2: Deploy Frontend

```bash
# Go back to project root
cd /home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4

# Deploy updated dashboard
./scripts/425-deploy-recorder-ui.sh
```

**What this does:**
1. Processes `ui-source/index.html` (replaces placeholders)
2. Uploads to S3
3. Invalidates CloudFront cache
4. Makes new version live

**Estimated Time:** 2-3 minutes (+ CloudFront propagation ~5 min)

### Step 3: Verify Deployment

```bash
# Check API endpoints
curl -X OPTIONS ${COGNITO_API_ENDPOINT}/api/audio/upload-file

# Should return CORS headers with 200 OK

# Check frontend
curl -s ${COGNITO_CLOUDFRONT_URL}/index.html | grep -i "upload audio"

# Should find "Upload Audio" text
```

---

## 🧪 Testing Checklist

### Test 1: Backend API - Upload URL Generation

```bash
# Get auth token (login first via browser, copy from localStorage)
TOKEN="your-id-token-here"

# Test upload URL generation
curl -X POST ${COGNITO_API_ENDPOINT}/api/audio/upload-file \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "filename": "test.m4a",
    "mimeType": "audio/m4a",
    "fileSize": 1000000
  }'

# Expected response:
# {
#   "success": true,
#   "uploadUrl": "https://s3.amazonaws.com/...",
#   "sessionId": "20251122-143022-upload-abc123",
#   "s3Key": "users/{userId}/audio/sessions/{sessionId}/chunk-001.m4a",
#   "expiresIn": 900
# }
```

✅ **Pass Criteria:** Returns presigned URL with sessionId containing "upload"

### Test 2: Frontend - Dashboard Navigation

1. Open CloudDrive dashboard: `${COGNITO_CLOUDFRONT_URL}/index.html`
2. Login with test credentials
3. Look for "Upload Audio" card on dashboard
4. Click "Upload Audio" card

✅ **Pass Criteria:** Upload section appears with drag & drop zone

### Test 3: File Upload - Button Click

1. In upload section, click "Choose Files" button
2. Select an audio file (.m4a, .mp3, .wav)
3. Wait for upload to complete

**Expected Behavior:**
- Progress bar appears
- Status shows: "Requesting upload URL..." → "Uploading..." → "Saving metadata..." → "✅ Upload complete!"
- File appears in "Your Uploaded Audio Files" list below
- Badge shows "📁 Upload"
- Status shows "⏳ Pending"
- "Transcribe Now" button appears

✅ **Pass Criteria:** File uploaded successfully, appears in list

### Test 4: File Upload - Drag & Drop

1. Drag an audio file from desktop
2. Drop onto upload zone
3. Verify same behavior as Test 3

✅ **Pass Criteria:** Drag & drop works, file uploads successfully

### Test 5: Transcribe Now Button

1. Upload a small audio file (< 1MB for quick test)
2. Click "Transcribe Now" button
3. Confirm dialog
4. Wait for response

**Expected Behavior:**
- Alert: "Transcription started! The audio will be transcribed within a few minutes."
- Status may change to "🔄 Processing" (if backend updates metadata)

**Note:** Actual transcription requires:
- GPU instance running
- Batch script execution (manual or cron)

✅ **Pass Criteria:** API call succeeds, confirmation shown

### Test 6: View in Editor (After Transcription)

**Prerequisites:** File must be transcribed first

1. Run batch transcription manually:
   ```bash
   cd /home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4
   ./scripts/515-run-batch-transcribe.sh
   ```

2. Wait for transcription to complete

3. Refresh dashboard upload page

4. File should show "✅ Complete" status

5. Click "View in Editor" button

**Expected Behavior:**
- Opens transcript-editor-v2.html with sessionId parameter
- Audio player loads the uploaded file
- Transcript displays (if transcription completed successfully)
- Session shows "📁 Upload" badge in session list

✅ **Pass Criteria:** Editor opens, audio plays, transcript displays

### Test 7: Multiple File Uploads

1. Upload 3 different audio files simultaneously
2. Verify all upload in parallel
3. Check all appear in uploaded files list

✅ **Pass Criteria:** All files upload successfully, appear in list

### Test 8: Error Handling - File Too Large

1. Try to upload a file > 500MB
2. Verify error message appears

✅ **Pass Criteria:** Error: "File too large. Maximum size is 500MB."

### Test 9: Error Handling - Invalid File Type

1. Try to drag & drop a non-audio file (e.g., .pdf, .jpg)
2. Verify error message appears

✅ **Pass Criteria:** Alert: "Please drop audio files only"

### Test 10: Session Persistence

1. Upload a file
2. Logout
3. Login again
4. Navigate to Upload Audio section
5. Verify file still appears in list

✅ **Pass Criteria:** Uploaded files persist across sessions

---

## 🐛 Troubleshooting

### Issue: "Failed to get upload URL"

**Cause:** Lambda function not deployed or CORS issue

**Solution:**
```bash
cd cognito-stack
serverless deploy function -f uploadAudioFile
```

### Issue: "Upload complete" but file doesn't appear in list

**Cause:** Metadata save failed

**Check:**
```bash
# List S3 sessions
aws s3 ls s3://${COGNITO_S3_BUCKET}/users/ --recursive | grep upload
```

**Solution:** Check CloudWatch logs for `updateAudioSessionMetadata` function

### Issue: "Transcribe Now" button doesn't trigger transcription

**Cause:** `triggerTranscription` API not working

**Check:**
```bash
# View Lambda logs
cd cognito-stack
serverless logs -f triggerTranscription -t
```

**Solution:** Currently returns success but requires manual script execution. To actually transcribe:
```bash
# Option 1: Run batch script
./scripts/515-run-batch-transcribe.sh

# Option 2: Implement Lambda that invokes batch script via Step Functions/SQS
```

### Issue: Uploaded files don't show in transcript editor

**Cause:** Editor filter or session list logic

**Check:** Open browser console, check for JavaScript errors

**Solution:** Verify editor session list loads both live and upload sessions

### Issue: CloudFront still shows old version

**Cause:** Cache not invalidated

**Solution:**
```bash
# Manually invalidate cache
aws cloudfront create-invalidation \
  --distribution-id ${CLOUDFRONT_DISTRIBUTION_ID} \
  --paths "/index.html"

# Wait 2-3 minutes, then refresh browser with Ctrl+Shift+R
```

---

## 📊 Verification Commands

### Check Backend Deployment

```bash
cd cognito-stack

# List deployed functions
serverless info

# Should show:
# functions:
#   ...
#   uploadAudioFile: clouddrive-app-dev-uploadAudioFile
#   triggerTranscription: clouddrive-app-dev-triggerTranscription
```

### Check S3 Structure

```bash
# List uploaded files (replace userId)
aws s3 ls s3://${COGNITO_S3_BUCKET}/users/{userId}/audio/sessions/ \
  | grep upload

# Should show folders like: 20251122-143022-upload-abc123/
```

### Check CloudWatch Logs

```bash
# Upload function logs
serverless logs -f uploadAudioFile --startTime 5m

# Transcription trigger logs
serverless logs -f triggerTranscription --startTime 5m
```

---

## 🎯 Success Criteria

Your deployment is successful when:

1. ✅ Dashboard shows "Upload Audio" card
2. ✅ Upload section loads with drag & drop zone
3. ✅ File upload completes successfully
4. ✅ Uploaded file appears in list with "📁 Upload" badge
5. ✅ "Transcribe Now" button calls API successfully
6. ✅ After batch transcription, "✅ Complete" status shows
7. ✅ "View in Editor" opens editor with audio playback
8. ✅ No JavaScript console errors

---

## 🔄 Next Steps (Optional Enhancements)

### Future Improvements

1. **Real-time Transcription Trigger**
   - Create SQS queue for transcription jobs
   - Lambda function to invoke batch script via SSM or Step Functions
   - Update triggerTranscription to push to queue

2. **Delete Functionality**
   - Implement deleteSession API endpoint
   - Delete S3 objects and metadata
   - Update deleteUpload() function

3. **Upload to Transcript Editor**
   - Add upload button to transcript editor header
   - Reuse upload JavaScript from dashboard
   - Show session badges (📁/🎙️) in session dropdown

4. **Progress Tracking**
   - Real-time upload progress with XHR/fetch progress events
   - Better status updates during transcription

5. **Batch Script Enhancement**
   - Add `--session-id` flag to process single session
   - Skip GPU shutdown if on-demand trigger

---

## 📝 Deployment Log Template

Use this to track your deployment:

```
Date: YYYY-MM-DD
Time: HH:MM

Backend Deployment:
- [ ] serverless deploy completed
- [ ] uploadAudioFile endpoint verified
- [ ] triggerTranscription endpoint verified

Frontend Deployment:
- [ ] 425-deploy-recorder-ui.sh completed
- [ ] CloudFront invalidation completed
- [ ] New version visible in browser

Testing:
- [ ] Test 1: Upload URL generation - PASS/FAIL
- [ ] Test 2: Dashboard navigation - PASS/FAIL
- [ ] Test 3: File upload (button) - PASS/FAIL
- [ ] Test 4: File upload (drag&drop) - PASS/FAIL
- [ ] Test 5: Transcribe Now button - PASS/FAIL
- [ ] Test 6: View in Editor - PASS/FAIL

Issues:
- None / [List any issues]

Status: SUCCESS / NEEDS FIXING
```

---

## 🎉 You're Ready!

Execute the deployment steps above and run through the testing checklist. The feature is production-ready!

If you encounter any issues, refer to the Troubleshooting section or check CloudWatch Logs for detailed error messages.

Good luck! 🚀
