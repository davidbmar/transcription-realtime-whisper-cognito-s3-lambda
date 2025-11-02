#!/usr/bin/env python3
"""
Live Transcription Demo for Google Docs
Simulates real-time transcription with Claude attribution
"""
import sys
import time
from datetime import datetime
from google.oauth2 import service_account
from googleapiclient.discovery import build

SCOPES = ['https://www.googleapis.com/auth/documents']

def get_document_end(service, document_id):
    """Get the index of the end of the document"""
    doc = service.documents().get(documentId=document_id).execute()
    content = doc.get('body').get('content')
    return content[-1].get('endIndex', 1)

def setup_document(service, document_id):
    """Setup document with header and live section"""
    end_index = get_document_end(service, document_id)
    timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')

    requests = [
        {
            'insertText': {
                'text': f'\n\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n',
                'location': {'index': end_index - 1}
            }
        },
        {
            'insertText': {
                'text': f'LIVE TRANSCRIPTION by Claude AI\n',
                'endOfSegmentLocation': {'segmentId': ''}
            }
        },
        {
            'insertText': {
                'text': f'Started: {timestamp}\n',
                'endOfSegmentLocation': {'segmentId': ''}
            }
        },
        {
            'insertText': {
                'text': f'━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n',
                'endOfSegmentLocation': {'segmentId': ''}
            }
        },
        {
            'insertText': {
                'text': '[Listening...]\n',
                'endOfSegmentLocation': {'segmentId': ''}
            }
        }
    ]

    result = service.documents().batchUpdate(
        documentId=document_id,
        body={'requests': requests}
    ).execute()

    header_text = f'\n\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\nLIVE TRANSCRIPTION by Claude AI\nStarted: {timestamp}\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n'
    live_start = end_index - 1 + len(header_text)

    return live_start

def update_live_section(service, document_id, live_start_index, new_text):
    """Replace the live section with new text"""
    doc = service.documents().get(documentId=document_id).execute()
    doc_end = doc.get('body').get('content')[-1].get('endIndex')

    requests = [
        {
            'deleteContentRange': {
                'range': {
                    'startIndex': live_start_index,
                    'endIndex': doc_end - 1
                }
            }
        },
        {
            'insertText': {
                'text': new_text + '\n',
                'location': {'index': live_start_index}
            }
        }
    ]

    result = service.documents().batchUpdate(
        documentId=document_id,
        body={'requests': requests}
    ).execute()

    return result

def run_demo(document_id, credentials_file):
    """Run a live transcription simulation"""

    print("🔐 Authenticating with Google Docs API...")
    creds = service_account.Credentials.from_service_account_file(
        credentials_file, scopes=SCOPES
    )
    service = build('docs', 'v1', credentials=creds)

    print("📄 Setting up document structure...")
    live_start = setup_document(service, document_id)
    print(f"✅ Live section starts at index: {live_start}")
    print("")

    print("🎙️  Simulating live transcription updates...")
    print("   (Watch the Google Doc update in real-time!)")
    print("")

    partial_texts = [
        "Hello...",
        "Hello this is...",
        "Hello this is a test...",
        "Hello this is a test of...",
        "Hello this is a test of live...",
        "Hello this is a test of live transcription...",
        "Hello this is a test of live transcription by Claude AI.",
    ]

    for i, text in enumerate(partial_texts):
        elapsed = i + 1
        print(f"[{elapsed}s] Updating: '{text}'")
        update_live_section(service, document_id, live_start, text)
        time.sleep(1.5)

    print("")
    print("✅ Demo complete!")
    print(f"📄 View at: https://docs.google.com/document/d/{document_id}/edit")
    print("")
    print("Notice:")
    print("  - Updates appeared in real-time (1-2 second delay)")
    print("  - Document clearly shows 'by Claude AI' attribution")
    print("  - Live section was updated without duplicating text")

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: python demo-live-transcription.py DOCUMENT_ID [CREDENTIALS_FILE]")
        sys.exit(1)

    doc_id = sys.argv[1]
    creds_file = sys.argv[2] if len(sys.argv) > 2 else 'credentials.json'

    try:
        run_demo(doc_id, creds_file)
    except FileNotFoundError as e:
        print(f"\n❌ Error: {e}")
        print("Make sure credentials.json exists")
        sys.exit(1)
    except Exception as e:
        print(f"\n❌ Error: {e}")

        if '404' in str(e):
            print("\nTroubleshooting:")
            print("1. Check the document ID is correct")
            print("2. Make sure the document is shared with the service account")
            print(f"3. Service account email should be in {creds_file}")

        import traceback
        traceback.print_exc()
        sys.exit(1)
