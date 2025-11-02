#!/usr/bin/env python3
"""Check Google Doc formatting to verify finalized vs live text."""

import json
import base64
import os
from google.oauth2 import service_account
from googleapiclient.discovery import build

# Load credentials from file
with open('credentials.json', 'r') as f:
    creds_dict = json.load(f)

credentials = service_account.Credentials.from_service_account_info(
    creds_dict,
    scopes=['https://www.googleapis.com/auth/documents.readonly']
)

service = build('docs', 'v1', credentials=credentials)

# Get doc ID from environment or use default
doc_id = os.environ.get('GOOGLE_DOC_ID', '1U_dJ9wyr2_RZMFvfJr5zondqqVKey6sOI3kiipB2Qe0')

# Get document
doc = service.documents().get(documentId=doc_id).execute()

# Find the last session header
last_session_start = None
for element in reversed(doc['body']['content']):
    if 'paragraph' in element and 'elements' in element['paragraph']:
        for text_element in element['paragraph']['elements']:
            if 'textRun' in text_element and '🎤 Live Transcription Started:' in text_element['textRun']['content']:
                last_session_start = element['startIndex']
                break
        if last_session_start is not None:
            break

if last_session_start is None:
    print("No session header found")
else:
    print(f"Last session starts at index: {last_session_start}\n")

    # Analyze all text after the session header
    finalized_count = 0
    live_count = 0
    finalized_examples = []
    live_examples = []

    for element in doc['body']['content']:
        if element.get('startIndex', 0) <= last_session_start:
            continue

        if 'paragraph' in element and 'elements' in element['paragraph']:
            for text_element in element['paragraph']['elements']:
                if 'textRun' in text_element:
                    content = text_element['textRun']['content']
                    if not content.strip():
                        continue

                    is_italic = text_element['textRun'].get('textStyle', {}).get('italic', False)
                    start = text_element.get('startIndex', 0)

                    preview = content[:50].replace('\n', '\\n')

                    if is_italic:
                        live_count += 1
                        if len(live_examples) < 3:
                            live_examples.append(f"  [{start}] {preview}")
                    else:
                        finalized_count += 1
                        if len(finalized_examples) < 3:
                            finalized_examples.append(f"  [{start}] {preview}")

    print("FINALIZED (normal text) examples:")
    if finalized_examples:
        for ex in finalized_examples:
            print(ex)
    else:
        print("  (none found)")

    print("\nLIVE (italic text) examples:")
    if live_examples:
        for ex in live_examples:
            print(ex)
    else:
        print("  (none found)")

    print(f"\n📊 Total in current session:")
    print(f"   Finalized (normal text): {finalized_count}")
    print(f"   Live (italic text): {live_count}")
