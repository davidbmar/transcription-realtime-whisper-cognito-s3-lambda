#!/usr/bin/env python3
"""
Demonstrate live editing: delete and replace text
This simulates how live transcription updates work
"""
import sys
import time
from google.oauth2 import service_account
from googleapiclient.discovery import build

SCOPES = ['https://www.googleapis.com/auth/documents']

def get_document_end(service, document_id):
    """Get the index of the end of the document"""
    doc = service.documents().get(documentId=document_id).execute()
    content = doc.get('body').get('content')
    # Last element's endIndex is the end of the document
    return content[-1].get('endIndex', 1)

def setup_live_section(service, document_id):
    """Setup document with permanent and live sections"""

    # Get current end
    end_index = get_document_end(service, document_id)

    requests = [
        # Add section headers
        {
            'insertText': {
                'text': '\n\n=== PERMANENT TRANSCRIPTION ===\n',
                'location': {'index': end_index - 1}
            }
        },
        {
            'insertText': {
                'text': '\n\n=== LIVE TRANSCRIPTION ===\n',
                'endOfSegmentLocation': {'segmentId': ''}
            }
        },
        # Mark where live section starts (we'll track this)
        {
            'insertText': {
                'text': '[Live updates will appear here]\n',
                'endOfSegmentLocation': {'segmentId': ''}
            }
        }
    ]

    result = service.documents().batchUpdate(
        documentId=document_id,
        body={'requests': requests}
    ).execute()

    # Calculate where live section starts
    # We just added: "\n\n=== PERMANENT ===\n" (28 chars) + "\n\n=== LIVE ===\n" (18 chars)
    live_start = end_index + 28 + 18

    return live_start

def update_live_section(service, document_id, live_start_index, new_text):
    """Replace the live section with new text"""

    # First, get current document to find where live section ends
    doc = service.documents().get(documentId=document_id).execute()
    doc_end = doc.get('body').get('content')[-1].get('endIndex')

    # Live section goes from live_start_index to end of doc
    requests = [
        # Step 1: Delete current live section
        {
            'deleteContentRange': {
                'range': {
                    'startIndex': live_start_index,
                    'endIndex': doc_end - 1  # -1 to avoid deleting the final newline
                }
            }
        },
        # Step 2: Insert new text at that position
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

def finalize_to_permanent(service, document_id, perm_end_index, live_start_index, text):
    """Move text from live section to permanent section"""

    doc = service.documents().get(documentId=document_id).execute()
    doc_end = doc.get('body').get('content')[-1].get('endIndex')

    requests = [
        # Step 1: Add to permanent section
        {
            'insertText': {
                'text': f"[{time.strftime('%H:%M:%S')}] {text}\n",
                'location': {'index': perm_end_index}
            }
        },
        # Step 2: Clear live section
        {
            'deleteContentRange': {
                'range': {
                    'startIndex': live_start_index,
                    'endIndex': doc_end - 1
                }
            }
        },
        # Step 3: Add placeholder back
        {
            'insertText': {
                'text': '[Listening...]\n',
                'location': {'index': live_start_index}
            }
        }
    ]

    result = service.documents().batchUpdate(
        documentId=document_id,
        body={'requests': requests}
    ).execute()

    return result

def run_demo(document_id, credentials_file='credentials.json'):
    """Run a live transcription simulation"""

    # Setup
    creds = service_account.Credentials.from_service_account_file(
        credentials_file, scopes=SCOPES
    )
    service = build('docs', 'v1', credentials=creds)

    print("🎬 Setting up document structure...")
    live_start = setup_live_section(service, document_id)
    print(f"✅ Live section starts at index: {live_start}")

    # Simulate live updates
    print("\n📝 Simulating live transcription updates...")

    partial_texts = [
        "Hello this is a...",
        "Hello this is a test of...",
        "Hello this is a test of live transcription",
    ]

    for i, text in enumerate(partial_texts):
        print(f"\n[{i+1}/3] Updating live section: '{text}'")
        update_live_section(service, document_id, live_start, text)
        time.sleep(2)  # Wait 2 seconds between updates

    print("\n✅ Final transcription, moving to permanent section...")
    final_text = "Hello this is a test of live transcription"

    # For finalize, we need to know where permanent section ends
    # In real implementation, track this. For demo, calculate:
    perm_end = live_start - len("\n\n=== LIVE TRANSCRIPTION ===\n")

    finalize_to_permanent(service, document_id, perm_end, live_start, final_text)

    print("\n✅ Demo complete!")
    print(f"📄 View at: https://docs.google.com/document/d/{document_id}/edit")
    print("\nYou should see:")
    print("  1. Final transcription in PERMANENT section")
    print("  2. Live section cleared back to '[Listening...]'")

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: python test-live-update.py DOCUMENT_ID")
        print("\nThis will:")
        print("  1. Setup document with permanent/live sections")
        print("  2. Update live section 3 times (simulating partial transcriptions)")
        print("  3. Move final text to permanent section")
        print("  4. Clear live section")
        sys.exit(1)

    doc_id = sys.argv[1]

    try:
        run_demo(doc_id)
    except FileNotFoundError:
        print("\n❌ Error: credentials.json not found")
    except Exception as e:
        print(f"\n❌ Error: {e}")
        import traceback
        traceback.print_exc()
