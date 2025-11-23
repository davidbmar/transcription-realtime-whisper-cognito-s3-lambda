# Upload Audio Feature - Implementation Status

**Date:** 2025-11-22
**Version:** Option A (Simplified Unified)
**Status:** Backend Complete, Frontend In Progress

---

## ✅ Completed

### Backend (100%)

1. **Lambda Functions Added** (`cognito-stack/api/audio.js`)
   - ✅ `uploadAudioFile()` - Generate presigned S3 URL for upload
   - ✅ `triggerTranscription()` - Trigger on-demand transcription

2. **API Endpoints Added** (`cognito-stack/serverless.yml`)
   - ✅ `POST /api/audio/upload-file` - Get upload URL
   - ✅ `POST /api/audio/transcribe/{sessionId}` - Trigger transcription

3. **S3 Path Structure**
   - ✅ Unified: `users/{userId}/audio/sessions/{sessionId}/chunk-001.{ext}`
   - ✅ SessionId format: `{timestamp}-upload-{uuid}`

### Frontend (70%)

1. **Dashboard UI** (`ui-source/index.html`)
   - ✅ Added "Upload Audio" card to dashboard
   - ✅ Created upload audio section with:
     - Drag & drop zone
     - File input with validation
     - Progress container
     - Uploaded files list

2. **Transcript Editor** (`ui-source/transcript-editor.html.template`)
   - ✅ Added dual-source selector with tabs:
     - 🎙️ Live Sessions
     - 📁 Uploaded Files
   - ✅ Session list with filtering by type
   - ✅ Session badges to distinguish upload vs live
   - ✅ Click session to load transcript and audio
   - ✅ Deployed to CloudFront: `transcript-editor.html`

---

## ✅ Recently Completed (2025-11-22)

### Transcript Editor - Dual Source Support

**File:** `ui-source/transcript-editor.html.template`

**What was added:**
1. **Session Selector UI**
   - Tab interface to switch between "Live Sessions" and "Uploaded Files"
   - Session list with scroll support (max-height: 300px)
   - Session badges (📁 Upload, 🎙️ Live)
   - Click-to-select session functionality

2. **JavaScript Logic**
   - `allSessions[]` - Stores all sessions from API
   - `currentSourceType` - Tracks active tab ('live' or 'upload')
   - `getFilteredSessions()` - Filters sessions by type
   - `switchSource(sourceType)` - Switches between tabs
   - `populateSessionList()` - Renders session list
   - `selectSession(session)` - Loads selected session

3. **Session Type Detection**
   - Uploaded files: sessionId contains `-upload-` OR `metadata.source === 'upload'`
   - Live sessions: Does NOT contain `-upload-` AND `metadata.source !== 'upload'`

4. **UI Styling**
   - `.source-tabs` - Tab container with border-bottom
   - `.source-tab.active` - Active tab styling (blue underline)
   - `.session-item` - Individual session card
   - `.session-item.selected` - Selected session highlighting
   - `.badge-live` - Blue badge for live sessions
   - `.badge-upload` - Yellow badge for uploads

**Deployment:**
- ✅ Deployed via `./scripts/425-deploy-recorder-ui.sh`
- ✅ Available at: https://d2l28rla2hk7np.cloudfront.net/transcript-editor.html

---

## 🚧 In Progress

### Frontend JavaScript (Dashboard - Still Needed)

**Add to `ui-source/index.html` before `</script>`:**

```javascript
// === Upload Audio Functions ===

function showUploadAudio() {
    hideAllSections();
    document.getElementById('upload-audio-section').style.display = 'block';
    loadUploadedFiles();
}

async function loadUploadedFiles() {
    try {
        // Call sessions API
        const token = localStorage.getItem('id_token');
        const response = await fetch(`${config.apiUrl}/api/audio/sessions`, {
            headers: {
                'Authorization': `Bearer ${token}`
            }
        });

        if (!response.ok) throw new Error('Failed to load uploaded files');

        const data = await response.json();

        // Filter for uploaded files only
        const uploadedFiles = data.sessions.filter(s =>
            s.sessionId && s.sessionId.includes('-upload-')
        );

        renderUploadedFilesList(uploadedFiles);
    } catch (error) {
        console.error('Error loading uploaded files:', error);
    }
}

function renderUploadedFilesList(files) {
    const container = document.getElementById('uploaded-files-list');

    if (files.length === 0) {
        container.innerHTML = `
            <div style="text-align: center; padding: 2rem; color: #999;">
                <i class="fas fa-music" style="font-size: 2rem; margin-bottom: 1rem;"></i>
                <p>No uploaded files yet. Upload an audio file to get started.</p>
            </div>
        `;
        return;
    }

    container.innerHTML = files.map(file => {
        const metadata = file.metadata || {};
        const transcriptionStatus = metadata.transcription?.status || 'pending';
        const statusBadge = {
            'pending': '<span style="color: #f59e0b;">⏳ Pending</span>',
            'processing': '<span style="color: #3b82f6;">🔄 Processing</span>',
            'complete': '<span style="color: #10b981;">✅ Complete</span>',
            'error': '<span style="color: #ef4444;">❌ Error</span>'
        }[transcriptionStatus] || '<span style="color: #6b7280;">❓ Unknown</span>';

        return `
            <div class="file-item" style="margin-bottom: 1rem; padding: 1rem; border: 1px solid #e5e7eb; border-radius: 8px;">
                <div style="display: flex; justify-content: space-between; align-items: center;">
                    <div style="flex: 1;">
                        <div style="display: flex; align-items: center; gap: 0.5rem;">
                            <i class="fas fa-music" style="color: #667eea;"></i>
                            <strong>${metadata.originalFilename || file.sessionId}</strong>
                            <span style="background: #f3f4f6; padding: 2px 8px; border-radius: 4px; font-size: 0.85rem;">📁 Upload</span>
                        </div>
                        <div style="margin-top: 0.5rem; font-size: 0.9rem; color: #6b7280;">
                            Uploaded: ${new Date(metadata.createdAt).toLocaleString()}
                            <span style="margin-left: 1rem;">${statusBadge}</span>
                        </div>
                    </div>
                    <div style="display: flex; gap: 0.5rem;">
                        ${transcriptionStatus === 'pending' ? `
                            <button class="btn btn-primary" onclick="transcribeNow('${file.sessionId}')">
                                <i class="fas fa-play"></i>
                                Transcribe Now
                            </button>
                        ` : ''}
                        ${transcriptionStatus === 'complete' ? `
                            <button class="btn" onclick="window.location.href='transcript-editor-v2.html?sessionId=${file.sessionId}'">
                                <i class="fas fa-edit"></i>
                                View in Editor
                            </button>
                        ` : ''}
                        <button class="btn" onclick="deleteUpload('${file.sessionId}')">
                            <i class="fas fa-trash"></i>
                        </button>
                    </div>
                </div>
            </div>
        `;
    }).join('');
}

async function transcribeNow(sessionId) {
    try {
        const token = localStorage.getItem('id_token');
        const response = await fetch(`${config.apiUrl}/api/audio/transcribe/${sessionId}`, {
            method: 'POST',
            headers: {
                'Authorization': `Bearer ${token}`,
                'Content-Type': 'application/json'
            }
        });

        if (!response.ok) throw new Error('Failed to trigger transcription');

        const data = await response.json();
        alert(`Transcription started for ${sessionId}!\n\nThe audio will be transcribed within a few minutes.`);
        loadUploadedFiles(); // Refresh list
    } catch (error) {
        console.error('Error triggering transcription:', error);
        alert('Failed to start transcription. Please try again.');
    }
}

// File upload handling
document.getElementById('audio-file-input').addEventListener('change', async (e) => {
    const files = Array.from(e.target.files);
    await uploadFiles(files);
});

// Drag and drop support
const dropZone = document.getElementById('upload-drop-zone');

dropZone.addEventListener('dragover', (e) => {
    e.preventDefault();
    dropZone.style.borderColor = '#667eea';
    dropZone.style.background = '#f0f4ff';
});

dropZone.addEventListener('dragleave', (e) => {
    e.preventDefault();
    dropZone.style.borderColor = '#e5e7eb';
    dropZone.style.background = 'white';
});

dropZone.addEventListener('drop', async (e) => {
    e.preventDefault();
    dropZone.style.borderColor = '#e5e7eb';
    dropZone.style.background = 'white';

    const files = Array.from(e.dataTransfer.files).filter(file =>
        file.type.startsWith('audio/')
    );

    if (files.length > 0) {
        await uploadFiles(files);
    } else {
        alert('Please drop audio files only');
    }
});

async function uploadFiles(files) {
    const progressContainer = document.getElementById('upload-progress-container');
    const progressList = document.getElementById('upload-progress-list');

    progressContainer.style.display = 'block';
    progressList.innerHTML = '';

    for (const file of files) {
        await uploadSingleFile(file, progressList);
    }

    // Refresh uploaded files list
    await loadUploadedFiles();
}

async function uploadSingleFile(file, progressList) {
    const MAX_FILE_SIZE = 500 * 1024 * 1024; // 500MB

    if (file.size > MAX_FILE_SIZE) {
        alert(`${file.name} is too large. Maximum size is 500MB.`);
        return;
    }

    const progressItem = document.createElement('div');
    progressItem.style.cssText = 'margin-bottom: 1rem; padding: 1rem; border: 1px solid #e5e7eb; border-radius: 8px;';
    progressItem.innerHTML = `
        <div style="display: flex; justify-content: space-between; margin-bottom: 0.5rem;">
            <strong>${file.name}</strong>
            <span id="status-${file.name}">Requesting upload URL...</span>
        </div>
        <div style="background: #f3f4f6; border-radius: 4px; height: 8px; overflow: hidden;">
            <div id="progress-${file.name}" style="background: #667eea; height: 100%; width: 0%; transition: width 0.3s;"></div>
        </div>
    `;
    progressList.appendChild(progressItem);

    try {
        // Step 1: Get presigned upload URL
        const token = localStorage.getItem('id_token');
        const uploadInfoResponse = await fetch(`${config.apiUrl}/api/audio/upload-file`, {
            method: 'POST',
            headers: {
                'Authorization': `Bearer ${token}`,
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({
                filename: file.name,
                mimeType: file.type || 'audio/mpeg',
                fileSize: file.size
            })
        });

        if (!uploadInfoResponse.ok) {
            throw new Error('Failed to get upload URL');
        }

        const uploadInfo = await uploadInfoResponse.json();
        const { uploadUrl, sessionId } = uploadInfo;

        document.getElementById(`status-${file.name}`).textContent = 'Uploading...';
        document.getElementById(`progress-${file.name}`).style.width = '10%';

        // Step 2: Upload file to S3
        const uploadResponse = await fetch(uploadUrl, {
            method: 'PUT',
            headers: {
                'Content-Type': file.type || 'audio/mpeg'
            },
            body: file
        });

        if (!uploadResponse.ok) {
            throw new Error('Failed to upload file');
        }

        document.getElementById(`progress-${file.name}`).style.width = '90%';
        document.getElementById(`status-${file.name}`).textContent = 'Saving metadata...';

        // Step 3: Save metadata
        const metadataResponse = await fetch(`${config.apiUrl}/api/audio/session-metadata`, {
            method: 'POST',
            headers: {
                'Authorization': `Bearer ${token}`,
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({
                sessionId: sessionId,
                source: 'upload',
                originalFilename: file.name,
                chunks: [{
                    chunkNumber: 1,
                    filename: `chunk-001.${file.name.split('.').pop()}`,
                    size: file.size
                }],
                transcription: {
                    status: 'pending'
                }
            })
        });

        if (!metadataResponse.ok) {
            throw new Error('Failed to save metadata');
        }

        document.getElementById(`progress-${file.name}`).style.width = '100%';
        document.getElementById(`status-${file.name}`).innerHTML = '<span style="color: #10b981;">✅ Upload complete!</span>';

    } catch (error) {
        console.error('Upload error:', error);
        document.getElementById(`status-${file.name}`).innerHTML = '<span style="color: #ef4444;">❌ Upload failed</span>';
    }
}
```

---

## 📋 TODO List

### 1. Complete Dashboard Implementation
- [ ] Add JavaScript functions to `ui-source/index.html`
- [ ] Add CSS for upload-area styling
- [ ] Test file upload flow

### 2. ~~Add Upload to Transcript Editor~~ ✅ COMPLETED
- [x] Add session selector to `ui-source/transcript-editor.html.template`
- [x] Add session badges (📁 Upload, 🎙️ Live)
- [x] Add JavaScript to filter and display sessions by type
- [x] Deploy to CloudFront

### 3. Batch Script Extension
- [ ] Modify `scripts/515-run-batch-transcribe.sh` to accept `--session-id` flag
- [ ] Add logic to process single session if flag provided

### 4. CSS Additions

Add to `<style>` section in `ui-source/index.html`:

```css
.upload-area {
    border: 2px dashed #e5e7eb;
    border-radius: 12px;
    padding: 3rem;
    text-align: center;
    background: white;
    transition: all 0.3s;
    cursor: pointer;
}

.upload-area:hover {
    border-color: #667eea;
    background: #f0f4ff;
}

.upload-area.drag-over {
    border-color: #667eea;
    background: #f0f4ff;
    transform: scale(1.02);
}
```

---

## Testing Checklist

### Backend
- [ ] Deploy Lambda functions: `cd cognito-stack && serverless deploy`
- [ ] Test upload URL generation: `POST /api/audio/upload-file`
- [ ] Test transcription trigger: `POST /api/audio/transcribe/{sessionId}`

### Frontend
- [ ] Test dashboard upload card navigation
- [ ] Test file upload (drag & drop)
- [ ] Test file upload (button click)
- [ ] Test "Transcribe Now" button
- [ ] Test file list display with badges
- [ ] Test view in editor link

### Integration
- [ ] Upload .m4a file → verify S3 storage
- [ ] Click "Transcribe Now" → verify transcription starts
- [ ] Wait for completion → verify transcript appears
- [ ] Open in editor → verify playback works
- [ ] Test with multiple file types (.mp3, .wav, .aac)

---

## Deployment Commands

```bash
# 1. Deploy backend
cd cognito-stack
serverless deploy

# 2. Deploy frontend
cd ..
./scripts/425-deploy-recorder-ui.sh

# 3. Test
# - Open dashboard
# - Click "Upload Audio"
# - Upload a file
# - Click "Transcribe Now"
# - Check transcript editor
```

---

## Next Steps

1. **Complete JavaScript implementation** in `ui-source/index.html`
2. **Add CSS styling** for upload area
3. **Add upload to transcript editor**
4. **Extend batch script** with --session-id flag
5. **Test end-to-end workflow**
6. **Deploy and verify**

---

## Notes

- Upload files stored at: `users/{userId}/audio/sessions/{sessionId}/chunk-001.{ext}`
- SessionId format: `{timestamp}-upload-{uuid}` (contains "upload" marker)
- Metadata schema same as live sessions (with `source: "upload"` field)
- Batch transcription runs every 2 hours (or on-demand via API)
- Frontend displays badges: 📁 Upload, 🎙️ Live
