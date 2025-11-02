# Google Docs Edit Skill

This skill allows Claude to edit Google Docs on your behalf.

## Setup (One-Time)

1. **Get Google Cloud credentials** (if not done already):
   ```bash
   cd google-docs-test
   # Follow README.md instructions to get credentials.json
   ```

2. **Test the skill**:
   ```bash
   cd .claude/skills/google-docs-edit
   ./run.sh url YOUR_DOC_ID
   ```

## Usage

Once set up, you can ask Claude to edit documents:

### Examples

**Append text:**
```
You: "Claude, add 'Meeting notes: Discussed project timeline' to doc 1a2b3c4d"
Claude: [Uses skill] → Appends text
```

**Read document:**
```
You: "Claude, what's in doc 1a2b3c4d?"
Claude: [Uses skill] → Shows content
```

**Get URL:**
```
You: "Claude, give me the link to doc 1a2b3c4d"
Claude: [Uses skill] → Returns shareable link
```

## Operations

| Operation | Command | Description |
|-----------|---------|-------------|
| `append` | `./run.sh append DOC_ID "text"` | Add text to end |
| `read` | `./run.sh read DOC_ID` | Read full content |
| `clear` | `./run.sh clear DOC_ID` | Delete all content |
| `url` | `./run.sh url DOC_ID` | Get shareable link |

## Requirements

- **Google Cloud credentials**
  - Default: `google-docs-test/credentials.json`
  - Override in `.env`: `GOOGLE_CREDENTIALS_PATH=/path/to/creds.json`
- **Document must be shared** with service account (email in credentials.json)
- **Python packages**: `google-api-python-client`, `google-auth`
  ```bash
  pip install google-api-python-client google-auth
  ```

## Configuration (.env)

Optional environment variables for zero-hardcoding:

```bash
# Google Docs Integration
GOOGLE_DOC_ID=1a2b3c4d5e6f                    # Default document ID
GOOGLE_CREDENTIALS_PATH=/path/to/credentials.json  # Custom credentials location
```

If not set, skill will:
- Use `google-docs-test/credentials.json` for credentials
- Ask for document ID when needed

## Manual Testing

```bash
# Test append
./run.sh append 1a2b3c4d5e6f "Test from CLI"

# Test read
./run.sh read 1a2b3c4d5e6f

# Get URL
./run.sh url 1a2b3c4d5e6f
```
