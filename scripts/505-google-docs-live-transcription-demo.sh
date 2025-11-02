#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Script 505: Google Docs Live Transcription Demo
# ============================================================================
# Demonstrates real-time transcription updates to a Google Doc with Claude AI
# attribution. Interactively prompts for doc ID and credentials, validates
# dependencies, then simulates live transcription.
#
# What this does:
# 1. Load environment and validate common functions
# 2. Check for Python packages (google-api-python-client, google-auth)
# 3. Validate credentials.json exists
# 4. Extract and display service account email
# 5. Prompt for Google Doc ID (if not in .env)
# 6. Save doc ID to .env for future use
# 7. Generate Python demo script
# 8. Run live transcription simulation
# 9. Display success message with doc URL
#
# Requirements:
# - .env variables: GOOGLE_DOC_ID (optional - will prompt if missing)
# - .env variables: GOOGLE_CREDENTIALS_PATH (optional - defaults to google-docs-test/credentials.json)
# - Python packages: google-api-python-client, google-auth
# - Google Doc shared with service account
#
# See: google-docs-test/README.md for setup instructions
#
# Total time: ~2 minutes (including user interaction)
# ============================================================================

# Resolve script path (handles symlinks)
if [ -L "${BASH_SOURCE[0]}" ]; then
    SCRIPT_REAL=$(readlink -f "${BASH_SOURCE[0]}")
else
    SCRIPT_REAL="${BASH_SOURCE[0]}"
fi
PROJECT_ROOT="$(cd "$(dirname "$SCRIPT_REAL")/.." && pwd)"

# Load environment and common functions
source "$PROJECT_ROOT/.env"
source "$PROJECT_ROOT/scripts/lib/common-functions.sh"

echo "============================================"
echo "505: Google Docs Live Transcription Demo"
echo "============================================"
echo ""

log_info "This script demonstrates live transcription with Claude AI attribution"
log_info "See: google-docs-test/README.md for setup details"
echo ""

log_info "This script will:"
log_info "  1. Validate Python dependencies"
log_info "  2. Check Google Cloud credentials"
log_info "  3. Prompt for Google Doc ID (if not configured)"
log_info "  4. Generate and run live transcription demo"
log_info "  5. Show real-time updates in your Google Doc"
echo ""

# ============================================================================
# Main Implementation
# ============================================================================

# Step 1: Check Python dependencies
log_info "Step 1: Validating Python dependencies"

if ! command -v python3 &> /dev/null; then
    log_error "python3 is not installed"
    exit 1
fi

MISSING_PACKAGES=()

if ! python3 -c "import googleapiclient.discovery" 2>/dev/null; then
    MISSING_PACKAGES+=("google-api-python-client")
fi

if ! python3 -c "from google.oauth2 import service_account" 2>/dev/null; then
    MISSING_PACKAGES+=("google-auth")
fi

if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
    log_error "Missing required Python packages: ${MISSING_PACKAGES[*]}"
    echo ""
    log_info "Install with:"
    log_info "  pip install ${MISSING_PACKAGES[*]}"
    exit 1
fi

log_success "Python dependencies installed"
echo ""

# Step 2: Check for credentials
log_info "Step 2: Validating Google Cloud credentials"

CREDS_PATH="${GOOGLE_CREDENTIALS_PATH:-$PROJECT_ROOT/google-docs-test/credentials.json}"

if [ ! -f "$CREDS_PATH" ]; then
    log_error "Google Cloud credentials not found at $CREDS_PATH"
    echo ""
    log_info "Setup required:"
    log_info "  1. Go to https://console.cloud.google.com"
    log_info "  2. Create a service account with Google Docs API access"
    log_info "  3. Download credentials.json"
    log_info "  4. Save to: $CREDS_PATH"
    echo ""
    log_info "See google-docs-test/README.md for detailed instructions"
    exit 1
fi

log_success "Found credentials at $CREDS_PATH"
echo ""

# Step 3: Extract service account email
log_info "Step 3: Extracting service account information"

SERVICE_ACCOUNT_EMAIL=$(python3 -c "import json; print(json.load(open('$CREDS_PATH'))['client_email'])" 2>/dev/null || echo "unknown")

if [ "$SERVICE_ACCOUNT_EMAIL" = "unknown" ]; then
    log_warn "Could not extract service account email from credentials.json"
    log_info "Check credentials.json manually for the 'client_email' field"
else
    log_info "Service Account Email: $SERVICE_ACCOUNT_EMAIL"
    echo ""
    log_warn "IMPORTANT: Your Google Doc must be shared with this email address!"
fi
echo ""

# Step 4: Get Google Doc ID
log_info "Step 4: Configuring Google Doc ID"

if [ -z "${GOOGLE_DOC_ID:-}" ]; then
    log_warn "GOOGLE_DOC_ID not found in .env"
    echo ""
    log_info "Please provide a Google Doc ID for testing."
    log_info "You can:"
    log_info "  1. Create a new Google Doc at https://docs.google.com"
    log_info "  2. Share it with: $SERVICE_ACCOUNT_EMAIL"
    log_info "     (Click 'Share' button, paste email, give 'Editor' access)"
    log_info "  3. Copy the document ID from the URL"
    echo ""
    log_info "Example URL: https://docs.google.com/document/d/1a2b3c4d5e6f/edit"
    log_info "Document ID: 1a2b3c4d5e6f"
    echo ""
    read -p "Enter Google Doc ID: " doc_id

    if [ -z "$doc_id" ]; then
        log_error "Document ID is required"
        exit 1
    fi

    # Add to .env
    log_info "Saving GOOGLE_DOC_ID to .env..."

    # Check if GOOGLE_DOC_ID already exists in .env
    if grep -q "^GOOGLE_DOC_ID=" "$PROJECT_ROOT/.env" 2>/dev/null; then
        # Update existing line
        sed -i "s|^GOOGLE_DOC_ID=.*|GOOGLE_DOC_ID=$doc_id|" "$PROJECT_ROOT/.env"
    else
        # Add new line
        echo "" >> "$PROJECT_ROOT/.env"
        echo "# Google Docs Integration" >> "$PROJECT_ROOT/.env"
        echo "GOOGLE_DOC_ID=$doc_id" >> "$PROJECT_ROOT/.env"
    fi

    export GOOGLE_DOC_ID="$doc_id"
    log_success "Saved to .env"
else
    log_info "Using GOOGLE_DOC_ID from .env: $GOOGLE_DOC_ID"
    doc_id="$GOOGLE_DOC_ID"
fi
echo ""

log_info "Document URL: https://docs.google.com/document/d/$doc_id/edit"
echo ""

# Step 5: Create the Python demo script
log_info "Step 5: Creating live transcription demo script"

DEMO_SCRIPT="$PROJECT_ROOT/google-docs-test/demo-live-transcription.py"

cat > "$DEMO_SCRIPT" << 'PYTHON_SCRIPT'
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
PYTHON_SCRIPT

chmod +x "$DEMO_SCRIPT"
log_success "Created demo script"
echo ""

# Step 6: Run the demo
log_info "Step 6: Running live transcription demo"
log_warn "Open the Google Doc in your browser to watch the updates in real-time!"
echo ""
log_info "Document URL: https://docs.google.com/document/d/$doc_id/edit"
echo ""
read -p "Press ENTER when you're ready to start the demo..."
echo ""

cd "$PROJECT_ROOT/google-docs-test"
python3 demo-live-transcription.py "$doc_id" "$CREDS_PATH"

echo ""

# ============================================================================
# Success Reporting
# ============================================================================

echo ""
log_info "==================================================================="
log_success "✅ GOOGLE DOCS LIVE TRANSCRIPTION DEMO COMPLETED"
log_info "==================================================================="
echo ""
log_info "Summary:"
log_info "  - Live transcription demo executed successfully"
log_info "  - Document updated with 'by Claude AI' attribution"
log_info "  - GOOGLE_DOC_ID saved to .env for future use"
echo ""
log_info "Next Steps:"
log_info "  1. Check the Google Doc to see the live transcription section"
log_info "  2. Integrate with audio.html for real-time transcription"
log_info "  3. Run again to test with different doc: ./scripts/505-google-docs-live-transcription-demo.sh"
log_info "  4. Use .claude/skills/google-docs-edit/ to edit docs programmatically"
echo ""
log_info "Related Files:"
log_info "  - google-docs-test/README.md - Setup instructions"
log_info "  - google-docs-test/demo-live-transcription.py - Generated demo script"
log_info "  - .claude/skills/google-docs-edit/ - Claude skill for doc editing"
echo ""
