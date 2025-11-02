#!/usr/bin/env python3
"""
Test Google Docs editing with optional user impersonation
Demonstrates how to make edits appear as a specific user (e.g., "Claude")
"""
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
        print("Usage: python test-impersonation.py DOCUMENT_ID 'text' [IMPERSONATE_EMAIL]")
        print("\nExamples:")
        print("  # Edit as service account:")
        print("  python test-impersonation.py 1abc123 'Hello from service account'")
        print("")
        print("  # Edit as Claude user (requires domain-wide delegation setup):")
        print("  python test-impersonation.py 1abc123 'Hello from Claude' claude@yourdomain.com")
        print("\nNote: Domain-wide delegation must be configured for impersonation to work.")
        print("See IMPERSONATION-GUIDE.md for setup instructions.")
        sys.exit(1)

    doc_id = sys.argv[1]
    text = sys.argv[2]
    impersonate_email = sys.argv[3] if len(sys.argv) > 3 else None

    try:
        service = get_service(impersonate_as=impersonate_email)
        append_text(service, doc_id, text)

        if impersonate_email:
            print(f"\n✨ Check version history - the edit should show '{impersonate_email}' as the editor!")
        else:
            print(f"\n⚠️  Using service account - version history will show the service account email")

    except Exception as e:
        print(f"\n❌ Error: {e}")

        error_str = str(e).lower()
        if 'subject' in error_str or 'delegation' in error_str or 'domain-wide' in error_str:
            print("\n⚠️  Domain-wide delegation error!")
            print("\nThis usually means one of:")
            print("1. Domain-wide delegation is not enabled in Google Cloud Console")
            print("2. Service account is not authorized in Google Workspace Admin")
            print("3. The OAuth scope is missing or incorrect")
            print("4. You're trying to impersonate a user outside your organization")
            print("\nSee IMPERSONATION-GUIDE.md for detailed setup instructions.")
        elif '404' in error_str:
            print("\nDocument not found. Make sure:")
            print("1. The document ID is correct")
            print("2. The document is shared with your service account")
            if impersonate_email:
                print(f"3. The document is shared with {impersonate_email}")

        sys.exit(1)
