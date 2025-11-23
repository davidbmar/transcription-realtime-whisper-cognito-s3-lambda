# Quick Start: Upload Audio Feature Testing

**Date:** 2025-11-22
**Ready to Deploy and Test!**

---

## 🚀 Deploy in 3 Commands

```bash
# 1. Deploy backend (3-5 min)
cd /home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/cognito-stack
serverless deploy

# 2. Deploy frontend (2-3 min)
cd /home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4
./scripts/425-deploy-recorder-ui.sh

# 3. Wait for CloudFront cache (~5 min), then test!
```

---

## ✅ Quick Test (5 Minutes)

### Test 1: Access Upload Feature

1. Open your CloudDrive dashboard:
   ```
   https://YOUR-CLOUDFRONT-URL/index.html
   ```

2. Login with your test credentials

3. Look for the **"Upload Audio"** card (4th card)

4. Click it

**Expected:** Upload section appears with drag & drop zone

---

### Test 2: Upload a File

1. Click **"Choose Files"** button

2. Select a small audio file (.m4a, .mp3, .wav - under 10MB for quick test)

3. Watch the progress bar

**Expected:**
- Status shows: "Requesting..." → "Uploading..." → "Saving..." → "✅ Complete!"
- File appears in list below with:
  - 📁 Upload badge
  - ⏳ Pending status
  - "Transcribe Now" button

---

### Test 3: Trigger Transcription (Optional)

1. Click **"Transcribe Now"** button on uploaded file

2. Confirm the dialog

3. Wait for success message

**Expected:** Alert shows "Transcription started!"

**Note:** Actual transcription requires:
```bash
# Run manually to transcribe
./scripts/515-run-batch-transcribe.sh
```

---

## 🎯 What to Look For

### ✅ Success Indicators

- [ ] "Upload Audio" card visible on dashboard
- [ ] Upload section loads without errors
- [ ] Drag & drop zone appears
- [ ] File upload completes (progress bar reaches 100%)
- [ ] File shows in "Your Uploaded Audio Files" list
- [ ] "Transcribe Now" button clickable
- [ ] No JavaScript errors in browser console (F12)

### ❌ Common Issues

**"Upload Audio" card not showing**
- Clear browser cache (Ctrl+Shift+R)
- Wait 5 more minutes for CloudFront

**Upload fails**
- Check browser console (F12) for errors
- Check file size (must be < 500MB)
- Check file type (must be audio/*)

**List is empty after upload**
- Click "Refresh" button
- Check S3: `aws s3 ls s3://${COGNITO_S3_BUCKET}/users/ --recursive | grep upload`

---

## 📁 Files Changed

### Backend
- `cognito-stack/api/audio.js` - Added 2 new functions
- `cognito-stack/serverless.yml` - Added 2 endpoints

### Frontend
- `ui-source/index.html` - Added upload UI + JavaScript + CSS

### Total Lines Added: ~350 lines

---

## 🧪 Full Test After Transcription

### Step 1: Upload File
```
Upload test.m4a via dashboard
```

### Step 2: Transcribe
```bash
cd /home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4
./scripts/515-run-batch-transcribe.sh
```

### Step 3: Verify
```
1. Refresh upload page
2. Status should show: ✅ Complete
3. Click "View in Editor"
4. Editor opens with audio playback
5. Transcript displays
```

---

## 🐛 Troubleshooting

### Check Backend Deployed

```bash
cd cognito-stack
serverless info | grep uploadAudioFile
# Should show: uploadAudioFile: clouddrive-app-dev-uploadAudioFile
```

### Check Frontend Deployed

```bash
curl -s ${COGNITO_CLOUDFRONT_URL}/index.html | grep -c "Upload Audio"
# Should show: 2 (or more)
```

### View Logs

```bash
cd cognito-stack

# Upload function logs
serverless logs -f uploadAudioFile --tail

# Transcription trigger logs
serverless logs -f triggerTranscription --tail
```

---

## 📚 Documentation

- **Design:** `docs/UPLOADED-AUDIO-DESIGN.md`
- **Deployment:** `docs/UPLOAD-AUDIO-DEPLOYMENT-GUIDE.md`
- **Implementation Status:** `docs/UPLOAD-AUDIO-IMPLEMENTATION-STATUS.md`

---

## 🎉 Ready to Test!

Run the 3 deployment commands above, then follow the Quick Test steps.

**Estimated Time:**
- Deployment: 10 minutes
- Testing: 5 minutes
- **Total: 15 minutes**

Good luck! 🚀
