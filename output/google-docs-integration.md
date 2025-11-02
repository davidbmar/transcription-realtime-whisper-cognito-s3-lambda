# Google Docs API Integration for Real-Time Transcription

## Executive Summary

Google Docs API can support real-time transcription updates with some important constraints:
- **Rate limits**: 60 writes/minute per user (1 update per second max)
- **Latency**: Expect 1-3 seconds for updates to appear
- **Pattern recommendation**: Use **named ranges** with a "permanent + live" section approach
- **Batch operations**: Combine multiple operations to stay within limits

## 1. Can Google Docs API Support "Live Section" + "Permanent Section" Pattern?

### ✅ YES - The API fully supports this pattern

**Key Operations Available:**
- Insert text at specific positions
- Delete ranges of text
- Batch multiple operations atomically
- Use named ranges to track sections dynamically

### Recommended Architecture:

```
Document Structure:
┌─────────────────────────────────┐
│ === PERMANENT TRANSCRIPTION === │ ← Named Range: "permanent_section"
│ Speaker 1: Hello everyone...    │
│ Speaker 2: Thank you for...     │
│ [content continues...]          │
│                                  │
│ === LIVE TRANSCRIPTION ===      │ ← Named Range: "live_section"
│ Speaker 3: Currently speaking.. │ ← Gets updated/replaced
└─────────────────────────────────┘
```

### Implementation Code:

```python
def setup_document_structure(service, document_id):
    """Initial setup with named ranges"""
    requests = [
        # Insert section headers
        {
            'insertText': {
                'text': '=== PERMANENT TRANSCRIPTION ===\n\n',
                'location': {'index': 1}
            }
        },
        {
            'insertText': {
                'text': '\n\n=== LIVE TRANSCRIPTION ===\n',
                'endOfSegmentLocation': {'segmentId': ''}
            }
        },
        # Create named range for permanent section (starts after header)
        {
            'createNamedRange': {
                'name': 'permanent_section',
                'range': {
                    'startIndex': 35,  # After header
                    'endIndex': 36     # Initially empty
                }
            }
        },
        # Create named range for live section
        {
            'createNamedRange': {
                'name': 'live_section',
                'range': {
                    'startIndex': 70,  # After live header
                    'endIndex': 71     # Initially empty
                }
            }
        }
    ]

    return service.documents().batchUpdate(
        documentId=document_id,
        body={'requests': requests}
    ).execute()
```

## 2. Rate Limits and Constraints

### Official Google Docs API Limits (2024)

| Operation Type | Per Project/Minute | Per User/Minute | Effective Rate |
|---------------|-------------------|-----------------|----------------|
| **Read Requests** | 3,000 | 300 | 5 reads/second |
| **Write Requests** | 600 | 60 | **1 write/second** |
| **Batch Size** | - | - | 100 operations max |

### Practical Implications:
- **Maximum update frequency**: 1 update per second per user
- **Batch strategy required**: Combine delete + insert in single request
- **Error handling**: Must implement exponential backoff for 429 errors

### Rate Limit Management Strategy:

```python
import time
from typing import List, Dict
import random

class RateLimitedDocsUpdater:
    def __init__(self, service, document_id):
        self.service = service
        self.document_id = document_id
        self.last_update = 0
        self.min_interval = 1.0  # 1 second between updates
        self.pending_updates = []

    def queue_update(self, requests: List[Dict]):
        """Queue updates for batching"""
        self.pending_updates.extend(requests)

    def flush_updates(self):
        """Send batched updates with rate limiting"""
        if not self.pending_updates:
            return

        # Ensure minimum interval between requests
        elapsed = time.time() - self.last_update
        if elapsed < self.min_interval:
            time.sleep(self.min_interval - elapsed)

        # Batch up to 100 operations
        batch = self.pending_updates[:100]
        self.pending_updates = self.pending_updates[100:]

        # Execute with retry logic
        return self._execute_with_backoff(batch)

    def _execute_with_backoff(self, requests, max_retries=5):
        """Execute with exponential backoff for rate limits"""
        for attempt in range(max_retries):
            try:
                result = self.service.documents().batchUpdate(
                    documentId=self.document_id,
                    body={'requests': requests}
                ).execute()
                self.last_update = time.time()
                return result

            except Exception as e:
                if '429' in str(e):  # Rate limited
                    # Exponential backoff: 2^n + random milliseconds
                    delay = min((2 ** attempt) + random.random(), 30)
                    time.sleep(delay)
                else:
                    raise e

        raise Exception(f"Failed after {max_retries} retries")
```

## 3. Index Management with Named Ranges

### How Indices Work

**Key Concepts:**
- Indices are in **UTF-16 code units** (important for emoji/unicode)
- Inserting text shifts all higher indices by the insertion length
- Deleting text shifts all higher indices down
- Named ranges **automatically update** their indices

### Named Range Solution:

```python
def update_live_transcription(service, document_id, new_text, is_final=False):
    """Update live section or move to permanent"""

    # Step 1: Get current document to find named ranges
    doc = service.documents().get(documentId=document_id).execute()

    # Find our named ranges
    live_range = None
    permanent_range = None

    for nr in doc.get('namedRanges', {}).values():
        if nr[0]['name'] == 'live_section':
            live_range = nr[0]['namedRangeId']
            live_start = nr[0]['ranges'][0]['startIndex']
            live_end = nr[0]['ranges'][0]['endIndex']
        elif nr[0]['name'] == 'permanent_section':
            permanent_range = nr[0]['namedRangeId']
            perm_end = nr[0]['ranges'][0]['endIndex']

    requests = []

    if is_final:
        # Move text from live to permanent
        requests = [
            # Step 1: Insert at end of permanent section
            {
                'insertText': {
                    'text': new_text + '\n',
                    'location': {'index': perm_end}
                }
            },
            # Step 2: Clear live section
            {
                'deleteContentRange': {
                    'range': {
                        'startIndex': live_start,
                        'endIndex': live_end
                    }
                }
            },
            # Step 3: Update permanent range end
            {
                'deleteNamedRange': {
                    'namedRangeId': permanent_range
                }
            },
            {
                'createNamedRange': {
                    'name': 'permanent_section',
                    'range': {
                        'startIndex': 35,
                        'endIndex': perm_end + len(new_text) + 1
                    }
                }
            }
        ]
    else:
        # Update live section (replace current content)
        requests = [
            # Delete current live content
            {
                'deleteContentRange': {
                    'range': {
                        'startIndex': live_start,
                        'endIndex': live_end
                    }
                }
            },
            # Insert new content
            {
                'insertText': {
                    'text': new_text,
                    'location': {'index': live_start}
                }
            }
        ]

    return service.documents().batchUpdate(
        documentId=document_id,
        body={'requests': requests}
    ).execute()
```

### Alternative: Using Bookmarks (Not Recommended)
- **Issue**: Bookmarks cannot be retrieved via Docs API (as of 2024)
- **Workaround**: Would require Google Apps Script proxy
- **Recommendation**: Use named ranges instead

## 4. Alternative Implementation Patterns

### Pattern A: Append-Only (Simplest)
**Pros:** No index management, simple implementation
**Cons:** No live preview updates, just final text

```python
def append_only_pattern(service, document_id, text):
    """Simply append new text to end of document"""
    request = [{
        'insertText': {
            'text': f"\n[{timestamp}] {speaker}: {text}",
            'endOfSegmentLocation': {'segmentId': ''}
        }
    }]
    return service.documents().batchUpdate(
        documentId=document_id,
        body={'requests': request}
    ).execute()
```

### Pattern B: Table-Based (Structured)
**Pros:** Clear structure, easy to scan
**Cons:** Complex index management, limited formatting

```python
def table_based_pattern(service, document_id, timestamp, speaker, text):
    """Add new row to transcription table"""

    # First, find the table
    doc = service.documents().get(documentId=document_id).execute()

    # Assuming table is first element
    table = doc['body']['content'][1]['table']
    last_row_index = table['rows'][-1]['tableCells'][0]['content'][0]['endIndex']

    requests = [
        # Insert new table row
        {
            'insertTableRow': {
                'tableCellLocation': {
                    'tableStartLocation': {'index': 2},
                    'rowIndex': len(table['rows']),
                    'columnIndex': 0
                }
            }
        },
        # Add content to cells (in reverse order!)
        {
            'insertText': {
                'text': text,
                'location': {'index': last_row_index + 10}  # Adjust for new row
            }
        },
        {
            'insertText': {
                'text': speaker,
                'location': {'index': last_row_index + 5}
            }
        },
        {
            'insertText': {
                'text': timestamp,
                'location': {'index': last_row_index + 2}
            }
        }
    ]

    return service.documents().batchUpdate(
        documentId=document_id,
        body={'requests': requests}
    ).execute()
```

### Pattern C: Comments/Suggestions (Not Viable)
- Google Docs API doesn't support creating suggestions programmatically
- Comments API is separate and limited
- **Not recommended** for this use case

## 5. Recommended Implementation Approach

### Architecture Decision: Named Ranges with Dual Sections

**Why this approach:**
1. **Clear separation** between final and live content
2. **Automatic index tracking** via named ranges
3. **Efficient batching** of operations
4. **Visual clarity** for viewers

### Complete Implementation Example:

```python
import time
import threading
from queue import Queue
from typing import Optional, Dict, Any
from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build

class GoogleDocsTranscriptionWriter:
    """Real-time transcription writer for Google Docs"""

    def __init__(self, credentials: Credentials, document_id: str):
        self.service = build('docs', 'v1', credentials=credentials)
        self.document_id = document_id
        self.update_queue = Queue()
        self.last_update_time = 0
        self.update_interval = 1.0  # Respect rate limit: 1 update/second

        # Start background updater thread
        self.updater_thread = threading.Thread(target=self._update_worker, daemon=True)
        self.updater_thread.start()

        # Initialize document structure
        self._initialize_document()

    def _initialize_document(self):
        """Set up document with named ranges"""
        try:
            # Check if already initialized
            doc = self.service.documents().get(documentId=self.document_id).execute()
            if 'permanent_section' in doc.get('namedRanges', {}):
                return  # Already initialized

            requests = [
                # Add headers
                {
                    'insertText': {
                        'text': '=== PERMANENT TRANSCRIPTION ===\n\n',
                        'location': {'index': 1}
                    }
                },
                {
                    'insertText': {
                        'text': '\n\n=== LIVE TRANSCRIPTION ===\n',
                        'endOfSegmentLocation': {'segmentId': ''}
                    }
                },
                # Create named ranges
                {
                    'createNamedRange': {
                        'name': 'permanent_section',
                        'range': {'startIndex': 35, 'endIndex': 36}
                    }
                },
                {
                    'createNamedRange': {
                        'name': 'live_section',
                        'range': {'startIndex': 70, 'endIndex': 71}
                    }
                }
            ]

            self.service.documents().batchUpdate(
                documentId=self.document_id,
                body={'requests': requests}
            ).execute()

        except Exception as e:
            print(f"Initialization error: {e}")

    def _update_worker(self):
        """Background worker to batch and rate-limit updates"""
        while True:
            updates = []

            # Collect updates for batching (up to 100 or 500ms worth)
            start_collect = time.time()
            while len(updates) < 100 and time.time() - start_collect < 0.5:
                try:
                    update = self.update_queue.get(timeout=0.1)
                    updates.append(update)
                except:
                    break

            if updates:
                # Rate limit: ensure 1 second between API calls
                elapsed = time.time() - self.last_update_time
                if elapsed < self.update_interval:
                    time.sleep(self.update_interval - elapsed)

                # Process batch
                self._execute_batch(updates)
                self.last_update_time = time.time()

    def _execute_batch(self, updates):
        """Execute a batch of updates"""
        try:
            # Get current document state
            doc = self.service.documents().get(documentId=self.document_id).execute()

            # Find named ranges
            ranges = self._get_named_ranges(doc)

            requests = []

            for update in updates:
                if update['type'] == 'partial':
                    # Update live section
                    requests.extend(self._create_live_update_requests(
                        update['text'],
                        ranges['live_section']
                    ))

                elif update['type'] == 'final':
                    # Move to permanent and clear live
                    requests.extend(self._create_finalize_requests(
                        update['text'],
                        ranges['permanent_section'],
                        ranges['live_section']
                    ))

            if requests:
                self.service.documents().batchUpdate(
                    documentId=self.document_id,
                    body={'requests': requests}
                ).execute()

        except Exception as e:
            print(f"Batch execution error: {e}")
            # Implement exponential backoff here if needed

    def _get_named_ranges(self, doc: Dict) -> Dict:
        """Extract named range positions"""
        ranges = {}
        for nr_list in doc.get('namedRanges', {}).values():
            nr = nr_list[0]
            name = nr['name']
            if name in ['permanent_section', 'live_section']:
                ranges[name] = {
                    'id': nr['namedRangeId'],
                    'start': nr['ranges'][0]['startIndex'],
                    'end': nr['ranges'][0]['endIndex']
                }
        return ranges

    def _create_live_update_requests(self, text: str, live_range: Dict) -> list:
        """Create requests to update live section"""
        return [
            # Clear current live content
            {
                'deleteContentRange': {
                    'range': {
                        'startIndex': live_range['start'],
                        'endIndex': live_range['end']
                    }
                }
            },
            # Insert new live content
            {
                'insertText': {
                    'text': text,
                    'location': {'index': live_range['start']}
                }
            }
        ]

    def _create_finalize_requests(self, text: str, perm_range: Dict, live_range: Dict) -> list:
        """Create requests to finalize transcription"""
        return [
            # Append to permanent section
            {
                'insertText': {
                    'text': text + '\n',
                    'location': {'index': perm_range['end']}
                }
            },
            # Clear live section
            {
                'deleteContentRange': {
                    'range': {
                        'startIndex': live_range['start'],
                        'endIndex': live_range['end']
                    }
                }
            }
        ]

    # Public API methods

    def update_partial(self, text: str):
        """Update live transcription (non-final)"""
        self.update_queue.put({
            'type': 'partial',
            'text': text,
            'timestamp': time.time()
        })

    def finalize_transcription(self, text: str):
        """Move transcription to permanent section"""
        self.update_queue.put({
            'type': 'final',
            'text': text,
            'timestamp': time.time()
        })

# Usage Example
def transcription_handler(docs_writer):
    """Example handler for WhisperLive events"""

    def on_partial_transcription(text, speaker):
        # Update live section with partial text
        docs_writer.update_partial(f"[{speaker}]: {text}")

    def on_final_transcription(text, speaker):
        # Move to permanent section
        timestamp = time.strftime("%H:%M:%S")
        docs_writer.finalize_transcription(
            f"[{timestamp}] {speaker}: {text}"
        )

    return on_partial_transcription, on_final_transcription
```

## 6. Error Handling Strategies

### Rate Limit Handling:
```python
def handle_rate_limit(func):
    """Decorator for automatic rate limit retry"""
    def wrapper(*args, **kwargs):
        max_retries = 5
        base_delay = 1

        for attempt in range(max_retries):
            try:
                return func(*args, **kwargs)
            except Exception as e:
                if '429' in str(e):
                    # Exponential backoff with jitter
                    delay = base_delay * (2 ** attempt) + random.uniform(0, 1)
                    time.sleep(min(delay, 30))
                else:
                    raise e

        raise Exception(f"Max retries exceeded for {func.__name__}")
    return wrapper
```

### Connection Recovery:
```python
def with_reconnect(service_builder):
    """Rebuild service on connection errors"""
    def decorator(func):
        def wrapper(self, *args, **kwargs):
            try:
                return func(self, *args, **kwargs)
            except Exception as e:
                if 'connection' in str(e).lower():
                    # Rebuild service
                    self.service = service_builder()
                    return func(self, *args, **kwargs)
                raise e
        return wrapper
    return decorator
```

## 7. Best Practices

### DO:
1. **Batch operations** - Combine multiple updates in single request
2. **Use named ranges** - Let API handle index management
3. **Implement queuing** - Buffer updates to respect rate limits
4. **Add retry logic** - Handle transient failures gracefully
5. **Monitor quotas** - Track usage to avoid hitting limits
6. **Use `endOfSegmentLocation`** - For appending without knowing index

### DON'T:
1. **Don't exceed 1 update/second** - Will trigger rate limits
2. **Don't calculate indices manually** - Use named ranges instead
3. **Don't use bookmarks** - Not accessible via API
4. **Don't create huge batches** - Max 100 operations per request
5. **Don't ignore UTF-16** - Emoji/unicode affect index calculations

## 8. Limitations and Gotchas

### API Limitations:
- **No real-time push**: Viewers must refresh to see updates
- **No collaborative cursors**: Can't show who's editing
- **No suggestions API**: Can't create tracked changes
- **No bookmark access**: Must use named ranges
- **UTF-16 indices**: Character count != index count for unicode

### Performance Considerations:
- **Latency**: 1-3 seconds typical for updates to appear
- **Document size**: Large documents (>1MB) slower to update
- **Named range limits**: Unclear max number (use sparingly)
- **Viewer limits**: Many simultaneous viewers may slow updates

## 9. Alternative Solutions

### Google Sheets (If tabular data works):
- **Pros**: Better for structured data, easier cell updates
- **Cons**: Less readable for prose, limited formatting

### Firebase + Custom Web App:
- **Pros**: True real-time, full control, no rate limits
- **Cons**: More complex, requires hosting

### Google Cloud Firestore + Docs Sync:
- **Pros**: Real-time database, periodic sync to Docs
- **Cons**: Not truly live in Docs, additional infrastructure

## 10. Implementation Checklist

### Prerequisites:
- [ ] Google Cloud Project with Docs API enabled
- [ ] OAuth2 credentials or Service Account
- [ ] Document ID (create new or use existing)
- [ ] Python environment with `google-api-python-client`

### Development Steps:
1. [ ] Set up authentication (OAuth2 or Service Account)
2. [ ] Create document structure with named ranges
3. [ ] Implement rate-limited update queue
4. [ ] Add error handling with exponential backoff
5. [ ] Create WhisperLive event handlers
6. [ ] Test with simulated transcription events
7. [ ] Monitor rate limit usage in production
8. [ ] Add logging and monitoring

### Testing Scenarios:
- [ ] Rapid partial updates (test rate limiting)
- [ ] Long transcription sessions (test stability)
- [ ] Network interruptions (test recovery)
- [ ] Multiple speakers (test formatting)
- [ ] Unicode/emoji content (test index handling)

## Sample Integration Code

### Complete WhisperLive to Google Docs Bridge:

```python
import asyncio
import websocket
import json
from google.oauth2 import service_account
from googleapiclient.discovery import build

class WhisperLiveToGoogleDocs:
    """Bridge WhisperLive transcription to Google Docs"""

    def __init__(self, whisper_ws_url: str, document_id: str, credentials_file: str):
        # Initialize Google Docs writer
        creds = service_account.Credentials.from_service_account_file(
            credentials_file,
            scopes=['https://www.googleapis.com/auth/documents']
        )
        self.docs_writer = GoogleDocsTranscriptionWriter(creds, document_id)

        # WhisperLive WebSocket URL
        self.ws_url = whisper_ws_url
        self.ws = None

        # Track current transcription state
        self.current_segment = ""
        self.last_segment_id = None

    def connect(self):
        """Connect to WhisperLive WebSocket"""
        self.ws = websocket.WebSocketApp(
            self.ws_url,
            on_open=self.on_open,
            on_message=self.on_message,
            on_error=self.on_error,
            on_close=self.on_close
        )
        self.ws.run_forever()

    def on_open(self, ws):
        """WebSocket opened"""
        print("Connected to WhisperLive")

    def on_message(self, ws, message):
        """Handle transcription message"""
        try:
            data = json.loads(message)

            if 'segments' in data:
                for segment in data['segments']:
                    segment_id = f"{segment['start']}-{segment['end']}"

                    if segment.get('partial', False):
                        # Partial transcription - update live section
                        self.current_segment = segment['text']
                        self.docs_writer.update_partial(self.current_segment)

                    else:
                        # Final transcription - move to permanent
                        if segment_id != self.last_segment_id:
                            self.docs_writer.finalize_transcription(segment['text'])
                            self.last_segment_id = segment_id
                            self.current_segment = ""

        except Exception as e:
            print(f"Message processing error: {e}")

    def on_error(self, ws, error):
        """Handle WebSocket error"""
        print(f"WebSocket error: {error}")
        # Implement reconnection logic here

    def on_close(self, ws, close_status_code, close_msg):
        """WebSocket closed"""
        print(f"WebSocket closed: {close_msg}")

# Usage
if __name__ == "__main__":
    bridge = WhisperLiveToGoogleDocs(
        whisper_ws_url="wss://your-whisperlive-server/ws",
        document_id="your-google-doc-id",
        credentials_file="service-account-key.json"
    )
    bridge.connect()
```

## Conclusion

Google Docs API can effectively support real-time transcription with proper implementation:

1. **Use named ranges** for robust position tracking
2. **Respect rate limits** (1 update/second maximum)
3. **Batch operations** for efficiency
4. **Implement proper error handling** with exponential backoff
5. **Consider alternatives** if sub-second latency is required

The recommended pattern (named ranges with permanent/live sections) provides a good balance of functionality, maintainability, and user experience for real-time transcription display.