---
name: google-docs-edit
description: Edit Google Docs by appending text or updating sections. Use this when the user asks you to write to a Google Doc, update a document, or add content to their shared doc. Credentials and doc IDs come from .env file - never hardcoded.
---

# Google Docs Edit Skill

This skill allows Claude to edit Google Docs on your behalf using secure configuration from .env.

## Prerequisites

1. **Google Cloud Service Account Credentials**
   - Default location: `google-docs-test/credentials.json`
   - Can be overridden via `.env`: `GOOGLE_CREDENTIALS_PATH=/path/to/credentials.json`
   - See `google-docs-test/README.md` for setup instructions

2. **Google Doc Configuration (optional)**
   - Set `GOOGLE_DOC_ID` in `.env` for default document
   - Or pass document ID as argument when invoking skill
   - Document must be shared with the service account email

3. **Document Sharing**
   - Share doc with service account email (found in credentials.json under `client_email`)
   - Give "Editor" permissions

## Security

This skill follows zero-hardcoding principles:
- ✅ Credentials path from `.env` (GOOGLE_CREDENTIALS_PATH)
- ✅ Document ID from `.env` (GOOGLE_DOC_ID) or arguments
- ✅ Service account email extracted from credentials.json
- ❌ No secrets or IDs hardcoded in skill files

## Usage

When invoked, this skill will:
1. Load credentials from .env configuration
2. Use GOOGLE_DOC_ID from .env (or ask for doc ID if not set)
3. Ask what operation to perform (append, read, clear, url)
4. Ask for the text content (if appending)
5. Execute the operation and report results

## Operations

- **append**: Add text to the end of the document (with "by Claude AI" attribution)
- **read**: Read current document content
- **clear**: Delete all content from the document
- **url**: Generate shareable link

## Example Configurations

### Option 1: Set default doc in .env (recommended)
```bash
# .env
GOOGLE_DOC_ID=1a2b3c4d5e6f
GOOGLE_CREDENTIALS_PATH=/home/user/project/google-docs-test/credentials.json
```

Then invoke skill without specifying doc ID:
```bash
./run.sh append "Meeting notes from today"
./run.sh read
```

### Option 2: Pass doc ID as argument
```bash
./run.sh append 1a2b3c4d5e6f "Meeting notes from today"
./run.sh read 1a2b3c4d5e6f
```

## Example Interaction

User: "Claude, add 'Meeting notes from today' to my doc"
Claude:
1. Loads GOOGLE_DOC_ID from .env (or asks if not set)
2. Invokes skill with append operation
3. Adds text with "by Claude AI" attribution
4. Reports success with doc URL
