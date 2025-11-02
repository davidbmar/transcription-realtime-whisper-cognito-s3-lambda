# Google Docs API Test

Minimal setup to test editing Google Docs via API.

## Quick Setup (5 minutes)

### 1. Create Google Cloud Project & Credentials

1. **Go to**: https://console.cloud.google.com/
2. **Create new project** (or use existing)
3. **Enable Google Docs API**:
   - Go to "APIs & Services" → "Library"
   - Search "Google Docs API"
   - Click "Enable"

4. **Create Service Account**:
   - Go to "APIs & Services" → "Credentials"
   - Click "Create Credentials" → "Service Account"
   - Name it (e.g., "docs-test")
   - Click "Create and Continue"
   - Skip optional steps, click "Done"

5. **Download Credentials**:
   - Click on the service account you just created
   - Go to "Keys" tab
   - Click "Add Key" → "Create new key"
   - Choose "JSON"
   - Save as `credentials.json` in this directory

### 2. Install Dependencies

```bash
cd google-docs-test
pip install -r requirements.txt
```

### 3. Create a Test Document

1. Go to https://docs.google.com/
2. Create a new blank document
3. Copy the document ID from the URL:
   ```
   https://docs.google.com/document/d/DOCUMENT_ID_HERE/edit
                                      ^^^^^^^^^^^^^^^^^^
   ```

4. **IMPORTANT**: Share the document with your service account email
   - Click "Share" button in the doc
   - Paste the service account email (looks like: `xxx@yyy.iam.gserviceaccount.com`)
   - Find it in `credentials.json` under `client_email`
   - Give it "Editor" access

### 4. Run the Test

```bash
python test.py YOUR_DOCUMENT_ID "Hello from API!"
```

You should see text appear in your Google Doc!

## Usage Examples

```bash
# Append a message
python test.py 1a2b3c4d5e6f "Test message"

# Append with timestamp (default if no text provided)
python test.py 1a2b3c4d5e6f
```

## Troubleshooting

**"credentials.json not found"**
- Make sure you downloaded the JSON key file and saved it as `credentials.json`

**"Permission denied" or "404 Not Found"**
- Make sure you shared the document with the service account email
- Check the document ID is correct

**"API not enabled"**
- Make sure Google Docs API is enabled in your Cloud Console

## Next Steps

Once this works, you can:
- Implement live transcription updates
- Add delete/replace operations
- Use named ranges for section management
- See `../output/google-docs-integration.md` for advanced patterns
