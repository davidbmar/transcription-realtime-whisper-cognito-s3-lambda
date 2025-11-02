#!/usr/bin/env python3
"""
Google Docs editing script for Claude Code skill

This script uses credentials and doc IDs from .env file (via environment variables).
Never hardcodes sensitive information.
"""
import sys
import os
from google.oauth2 import service_account
from googleapiclient.discovery import build

SCOPES = ['https://www.googleapis.com/auth/documents']

# Find credentials file - check env var first, fallback to default location
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, '../../..'))

# Support GOOGLE_CREDENTIALS_PATH from .env
CREDS_PATH = os.environ.get('GOOGLE_CREDENTIALS_PATH')
if not CREDS_PATH:
    # Fallback to default location
    CREDS_PATH = os.path.join(REPO_ROOT, 'google-docs-test/credentials.json')

def get_service():
    """Create Google Docs API service"""
    if not os.path.exists(CREDS_PATH):
        print(f"ERROR: Credentials not found at {CREDS_PATH}")
        print("Run setup first: cd google-docs-test && follow README.md")
        sys.exit(1)

    creds = service_account.Credentials.from_service_account_file(
        CREDS_PATH, scopes=SCOPES
    )
    return build('docs', 'v1', credentials=creds)

def append_text(service, document_id, text):
    """Append text to end of document"""
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

def read_document(service, document_id):
    """Read document content"""
    doc = service.documents().get(documentId=document_id).execute()

    title = doc.get('title', 'Untitled')
    print(f"\n📄 Document: {title}")
    print(f"🔗 URL: https://docs.google.com/document/d/{document_id}/edit")
    print("\n" + "="*60)

    # Extract text content
    content = doc.get('body').get('content')
    text_parts = []

    for element in content:
        if 'paragraph' in element:
            para = element['paragraph']
            for text_run in para.get('elements', []):
                if 'textRun' in text_run:
                    text_parts.append(text_run['textRun']['content'])

    full_text = ''.join(text_parts)
    print(full_text)
    print("="*60)
    print(f"\nTotal characters: {len(full_text)}")

    return full_text

def clear_document(service, document_id):
    """Clear all content from document"""
    doc = service.documents().get(documentId=document_id).execute()
    doc_end = doc.get('body').get('content')[-1].get('endIndex')

    if doc_end <= 2:
        print("Document is already empty")
        return

    requests = [{
        'deleteContentRange': {
            'range': {
                'startIndex': 1,
                'endIndex': doc_end - 1
            }
        }
    }]

    result = service.documents().batchUpdate(
        documentId=document_id,
        body={'requests': requests}
    ).execute()

    print(f"✅ Cleared document content")
    print(f"📄 View at: https://docs.google.com/document/d/{document_id}/edit")
    return result

def main():
    if len(sys.argv) < 2:
        print("Usage: python edit-doc.py OPERATION [DOCUMENT_ID] [TEXT]")
        print("\nOperations:")
        print("  append [DOC_ID] 'text' - Append text to document")
        print("  read [DOC_ID]          - Read document content")
        print("  clear [DOC_ID]         - Clear all content")
        print("  url [DOC_ID]           - Get document URL")
        print("\nDocument ID:")
        print("  - Can be passed as argument")
        print("  - Or set in .env as GOOGLE_DOC_ID")
        print("  - Argument takes precedence over .env")
        sys.exit(1)

    operation = sys.argv[1]

    # Get document ID from args or environment
    if len(sys.argv) >= 3:
        document_id = sys.argv[2]
    else:
        document_id = os.environ.get('GOOGLE_DOC_ID')
        if not document_id:
            print("ERROR: Document ID required")
            print("Either:")
            print("  1. Pass as argument: python edit-doc.py OPERATION DOC_ID")
            print("  2. Set in .env: GOOGLE_DOC_ID=your-doc-id")
            sys.exit(1)

    service = get_service()

    try:
        if operation == 'append':
            # Text is either 3rd or 4th arg depending on whether doc_id was passed
            text_arg_index = 3 if len(sys.argv) >= 3 else 2
            if len(sys.argv) <= text_arg_index:
                print("ERROR: Missing text argument")
                sys.exit(1)
            text = sys.argv[text_arg_index]
            append_text(service, document_id, text)

        elif operation == 'read':
            read_document(service, document_id)

        elif operation == 'clear':
            confirm = input("⚠️  This will delete all content. Type 'yes' to confirm: ")
            if confirm.lower() == 'yes':
                clear_document(service, document_id)
            else:
                print("Cancelled")

        elif operation == 'url':
            print(f"https://docs.google.com/document/d/{document_id}/edit")

        else:
            print(f"ERROR: Unknown operation '{operation}'")
            sys.exit(1)

    except Exception as e:
        print(f"\n❌ Error: {e}")
        if '404' in str(e):
            print("\nTroubleshooting:")
            print("1. Check the document ID is correct")
            print("2. Make sure the document is shared with the service account")
        sys.exit(1)

if __name__ == '__main__':
    main()
