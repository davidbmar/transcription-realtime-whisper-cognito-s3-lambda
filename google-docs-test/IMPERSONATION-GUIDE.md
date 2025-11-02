# Google Docs Editor Attribution - Showing "Claude" as the Editor

## Problem

By default, when using service account authentication, edits appear in Google Docs version history with the service account's email address (e.g., `docs-test@project-123456.iam.gserviceaccount.com`). This isn't user-friendly.

## Solution: Domain-Wide Delegation with User Impersonation

To show a custom name like "Claude" in version history, you need to:

1. Create a Google Workspace user account (e.g., `claude@yourdomain.com`)
2. Enable domain-wide delegation for your service account
3. Impersonate that user when making API calls

## Prerequisites

- **Google Workspace account** (NOT just Gmail) - Domain-wide delegation only works with Workspace
- **Admin access** to your Google Workspace domain
- Your existing service account credentials

## Setup Steps

### 1. Enable Domain-Wide Delegation

1. Go to [Google Cloud Console](https://console.cloud.google.com)
2. Navigate to **IAM & Admin** → **Service Accounts**
3. Find your service account and click on it
4. Click **"Show Domain-Wide Delegation"**
5. Click **"Enable Google Workspace Domain-Wide Delegation"**
6. Note the **Client ID** (a long number)

### 2. Authorize in Google Workspace Admin

1. Go to [Google Admin Console](https://admin.google.com)
2. Navigate to **Security** → **Access and data control** → **API Controls**
3. Click **"Manage Domain-Wide Delegation"**
4. Click **"Add new"**
5. Enter your service account's **Client ID**
6. Add these OAuth scopes:
   ```
   https://www.googleapis.com/auth/documents
   ```
7. Click **"Authorize"**

### 3. Create a "Claude" User Account

1. In Google Workspace Admin Console
2. Go to **Directory** → **Users**
3. Create a new user: `claude@yourdomain.com`
4. Set a password (you won't need to log in as this user)

### 4. Update Your Code

Modify the `get_service()` function to use impersonation:

```python
def get_service(impersonate_email=None):
    """Create Google Docs API service with optional impersonation"""
    if not os.path.exists(CREDS_PATH):
        print(f"ERROR: Credentials not found at {CREDS_PATH}")
        sys.exit(1)

    creds = service_account.Credentials.from_service_account_file(
        CREDS_PATH, scopes=SCOPES
    )

    # Impersonate a specific user if provided
    if impersonate_email:
        creds = creds.with_subject(impersonate_email)
        print(f"🎭 Impersonating: {impersonate_email}")

    return build('docs', 'v1', credentials=creds)
```

### 5. Use Impersonation When Editing

```python
# Edit as "Claude"
service = get_service(impersonate_email='claude@yourdomain.com')
append_text(service, document_id, 'This will show Claude as the editor')
```

## Example: Updated test.py

```python
#!/usr/bin/env python3
import sys
from google.oauth2 import service_account
from googleapiclient.discovery import build

SCOPES = ['https://www.googleapis.com/auth/documents']

def get_service(credentials_file='credentials.json', impersonate_as=None):
    """Create Google Docs API service with optional impersonation"""
    creds = service_account.Credentials.from_service_account_file(
        credentials_file, scopes=SCOPES
    )

    # Impersonate a user if specified
    if impersonate_as:
        creds = creds.with_subject(impersonate_as)
        print(f"🎭 Acting as: {impersonate_as}")
    else:
        print(f"📧 Using service account directly")

    return build('docs', 'v1', credentials=creds)

def append_text(service, document_id, text):
    """Append text to the end of a Google Doc"""
    requests = [{
        'insertText': {
            'text': text + '\n',
            'endOfSegmentLocation': {'segmentId': ''}
        }
    }]

    result = service.documents().batchUpdate(
        documentId=document_id,
        body={'requests': requests}
    ).execute()

    print(f"✅ Appended text to document")
    print(f"📄 View at: https://docs.google.com/document/d/{document_id}/edit")
    return result

if __name__ == '__main__':
    if len(sys.argv) < 3:
        print("Usage: python test.py DOCUMENT_ID 'text' [IMPERSONATE_EMAIL]")
        print("\nExamples:")
        print("  python test.py 1abc123 'Hello' claude@example.com")
        print("  python test.py 1abc123 'Hello'  # Uses service account")
        sys.exit(1)

    doc_id = sys.argv[1]
    text = sys.argv[2]
    impersonate_email = sys.argv[3] if len(sys.argv) > 3 else None

    try:
        service = get_service(impersonate_as=impersonate_email)
        append_text(service, doc_id, text)
    except Exception as e:
        print(f"❌ Error: {e}")

        if 'subject claims' in str(e).lower() or 'delegation' in str(e).lower():
            print("\n⚠️  Domain-wide delegation error!")
            print("Make sure you:")
            print("1. Enabled domain-wide delegation in Google Cloud Console")
            print("2. Authorized the service account in Google Workspace Admin")
            print("3. Used the correct scope: https://www.googleapis.com/auth/documents")

        sys.exit(1)
```

## Testing

```bash
# Test without impersonation (shows service account email)
python test.py YOUR_DOC_ID "Test message"

# Test with impersonation (shows Claude as editor)
python test.py YOUR_DOC_ID "Test from Claude" claude@yourdomain.com
```

Check version history in Google Docs to see the editor name!

## Alternative: Change Service Account Name

If you don't have Google Workspace or don't want to set up delegation, you can update the service account's display name. This won't affect Google Docs version history, but it makes the service account easier to identify in your Google Cloud Console:

```bash
gcloud iam service-accounts update SERVICE_ACCOUNT_EMAIL \
  --display-name="Claude AI Assistant"
```

**Note:** This only affects the Cloud Console UI, not how it appears in Google Docs.

## Troubleshooting

### "Delegation denied" error
- Make sure you authorized the correct Client ID in Workspace Admin
- Verify the OAuth scope matches exactly: `https://www.googleapis.com/auth/documents`
- Wait a few minutes for changes to propagate

### "Subject not allowed" error
- The email you're impersonating must be a user in your Google Workspace domain
- Service accounts can only impersonate users in the same organization

### Still shows service account email
- Domain-wide delegation only works with Google Workspace (paid), not free Gmail
- Make sure you're using `creds.with_subject(email)` before building the service

## For CloudDrive Live Transcription

If you want real-time transcriptions to show "Claude" as the editor:

1. Set up domain-wide delegation as described above
2. Create `claude@yourdomain.com` user account
3. When initializing the Google Docs writer, pass the impersonation email:

```python
# In your transcription code
writer = GoogleDocsTranscriptionWriter(
    document_id='YOUR_DOC_ID',
    credentials_file='credentials.json',
    impersonate_as='claude@yourdomain.com'  # Add this parameter
)
```

All subsequent edits will appear as being made by Claude!
