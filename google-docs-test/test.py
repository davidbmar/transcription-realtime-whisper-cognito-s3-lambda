#!/usr/bin/env python3
"""
Minimal Google Docs API test - Append text to a document
"""
import sys
import time
from google.oauth2 import service_account
from googleapiclient.discovery import build

# Scopes required for editing docs
SCOPES = ['https://www.googleapis.com/auth/documents']

def append_text(document_id, text, credentials_file='credentials.json'):
    """Append text to the end of a Google Doc"""

    # Load credentials
    creds = service_account.Credentials.from_service_account_file(
        credentials_file, scopes=SCOPES
    )

    # Build the service
    service = build('docs', 'v1', credentials=creds)

    # Append text to the document
    requests = [{
        'insertText': {
            'text': text + '\n',
            'endOfSegmentLocation': {
                'segmentId': ''  # Empty string means main body
            }
        }
    }]

    # Execute the request
    result = service.documents().batchUpdate(
        documentId=document_id,
        body={'requests': requests}
    ).execute()

    return result

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: python test.py DOCUMENT_ID [text]")
        print("\nExample:")
        print("  python test.py 1a2b3c4d5e6f 'Hello from API!'")
        print("\nDocument ID is from the URL:")
        print("  https://docs.google.com/document/d/DOCUMENT_ID/edit")
        sys.exit(1)

    doc_id = sys.argv[1]
    text = sys.argv[2] if len(sys.argv) > 2 else f"Test message at {time.strftime('%Y-%m-%d %H:%M:%S')}"

    print(f"Appending to document: {doc_id}")
    print(f"Text: {text}")

    try:
        result = append_text(doc_id, text)
        print("\n✅ Success! Text appended to document.")
        print(f"📄 View at: https://docs.google.com/document/d/{doc_id}/edit")
    except FileNotFoundError:
        print("\n❌ Error: credentials.json not found")
        print("See README.md for setup instructions")
    except Exception as e:
        print(f"\n❌ Error: {e}")
        print("\nTroubleshooting:")
        print("1. Make sure the document ID is correct")
        print("2. Make sure the service account has edit access to the document")
        print("3. Make sure Google Docs API is enabled in your project")
