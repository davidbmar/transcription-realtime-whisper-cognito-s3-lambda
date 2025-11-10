# CloudDrive Download Skill

**The easiest way to share files with Claude Code.**

Upload files to CloudDrive (screenshots, designs, documents) and Claude can instantly download them using this skill.

## Quick Start for File Sharing

**User → Claude workflow:**
1. Upload file to CloudDrive web UI (any folder, like `images/`)
2. Tell Claude: "Download my screenshot from CloudDrive"
3. Claude automatically finds and downloads it
4. Claude analyzes it and responds

**No need to specify paths or user IDs** - Claude figures it out automatically.

## Overview

This skill uses AWS CLI for fast, direct S3 access to CloudDrive files. It's the **primary method** for Claude to access files you share via CloudDrive.

## Prerequisites

- AWS CLI installed (`pip install awscli` or `brew install awscli`)
- AWS credentials configured with S3 read access to CloudDrive bucket
- Credentials can be via: IAM role, `~/.aws/credentials`, or environment variables

## Components

### 1. `skill.md`
Defines the skill metadata and invocation patterns for Claude Code.

### 2. `download.sh`
Main download script using AWS CLI.

**Usage:**
```bash
./download.sh <filename-or-pattern> [user-id]
```

**Examples:**
```bash
# Download single file by name
./download.sh "test-clouddrive.txt"

# Download file from specific folder
./download.sh "test/myfile.pdf"

# Download with wildcard
./download.sh "*.png"

# Specify user ID explicitly (optional)
./download.sh "myfile.txt" "71fb0520-c0f1-7063-ac62-ad0f00915a3d"
```

**Features:**
- Uses AWS CLI for fast, direct S3 access
- Automatically detects user ID from bucket
- Searches for files by pattern
- Downloads to `./clouddrive-downloads/`
- Preserves folder structure
- Shows download progress and file info

### 3. `file-search.sh`
File search and listing utility.

**Usage:**
```bash
./file-search.sh [options]
```

**Examples:**
```bash
# List all files
./file-search.sh --list

# List folders only
./file-search.sh --folders

# Search by pattern
./file-search.sh "test"
./file-search.sh "*.png"
./file-search.sh "screenshot"

# Help
./file-search.sh --help
```

**Output:**
- Formatted table with date, time, size, and filename
- Color-coded output for easy reading
- File count and total size summary

### 4. `auth-helper.sh`
**Future Enhancement** - Cognito authentication for non-development use.

Currently not used by the skill. This would enable authentication via Cognito API for environments without AWS credentials.

**Implementation needed:**
- SRP authentication flow (Cognito's secure method)
- Or enable USER_PASSWORD_AUTH in Cognito client config
- Token management and refresh logic

## Configuration

The skill uses configuration from the project's `.env` file:

```bash
COGNITO_S3_BUCKET=your-s3-bucket-name
COGNITO_API_ENDPOINT=https://xxxxxxxxxx.execute-api.us-east-2.amazonaws.com/dev
COGNITO_USER_POOL_ID=us-east-2_XXXXXXXXX
COGNITO_USER_POOL_CLIENT_ID=xxxxxxxxxxxxxxxxxx
AWS_REGION=us-east-2
```

Copy `.env.example` to `.env` and fill in your deployment values.

## How It Works

The skill uses AWS CLI to directly access S3:

```bash
# Verify AWS CLI works (replace with your bucket from .env)
aws s3 ls s3://$COGNITO_S3_BUCKET/

# Check configured credentials
aws configure list
```

**Authentication:**
- Uses standard AWS credential chain (IAM role, ~/.aws/credentials, env vars)
- Requires S3 read permissions for the CloudDrive bucket
- No separate login required if AWS credentials are configured

**For Production Users:**
- End users should access files through CloudDrive web UI
- Web UI uses secure Cognito OAuth/SRP authentication
- This skill is for developers and internal access only

## Using with Claude Code

### For User → Claude File Sharing

**Just upload and tell Claude!** No technical details needed:

**You say:**
- "I uploaded a screenshot to CloudDrive, can you check it?"
- "Download that design mockup I just uploaded"
- "Get my latest screenshot from /images/"
- "Find the PDF I uploaded yesterday"

**Claude responds:**
- Automatically searches your CloudDrive
- Downloads the file(s)
- Analyzes content (images, code, etc.)
- Gives you feedback/answers

### For Development/Scripting

**Manual usage:**
```bash
./download.sh "screenshot"                    # Search by name
./download.sh "Screenshot 2025-11-09"         # Partial match
./download.sh "images/*.png"                  # Pattern match
```

Claude automatically:
1. Detects user ID from bucket
2. Searches for files matching your description
3. Downloads to `./clouddrive-downloads/`
4. Opens/analyzes files (images, code, etc.)
5. Provides relevant insights

## File Structure

```
.claude/skills/clouddrive-download/
├── skill.md              # Skill definition for Claude Code
├── README.md             # This file
├── download.sh           # Main download script (executable)
├── file-search.sh        # File search utility (executable)
└── auth-helper.sh        # Cognito auth helper (executable)

clouddrive-downloads/     # Downloaded files (auto-created)
└── test/
    └── test-clouddrive.txt

~/.clouddrive/            # Authentication tokens (gitignored)
├── token                 # JWT ID token
├── refresh_token         # Refresh token
└── user_info             # User info from JWT
```

## Security Notes

1. **Development Only**: This skill is for internal development use with AWS credentials
2. **Production Access**: End users should use CloudDrive web UI (secure OAuth/SRP)
3. **AWS Credentials**: Uses standard AWS credential chain - keep credentials secure
4. **Access Control**: IAM permissions determine what files can be accessed
5. **Web UI Security**: CloudDrive web UI uses Cognito with SRP (no password transmission)

## Troubleshooting

### "No files found"
- Check that files exist in S3: `aws s3 ls s3://$COGNITO_S3_BUCKET/users/{userId}/ --recursive`
- Verify user ID is correct
- Check file search pattern

### "Cannot access bucket"
- Ensure AWS credentials are configured: `aws configure list`
- For API mode, authenticate first: `./auth-helper.sh`
- Check bucket name in `.env` file

### "Token has expired"
- Refresh token: `./auth-helper.sh --refresh`
- Or login again: `./auth-helper.sh`

### "Failed to download via AWS CLI"
- Check S3 key path is correct
- Verify IAM permissions for S3 GetObject
- Try API mode instead (will auto-fallback)

## Testing

Test the skill with a sample file:

```bash
# Upload test file (replace {userId} with your user ID)
echo "Test content" > /tmp/test.txt
aws s3 cp /tmp/test.txt s3://$COGNITO_S3_BUCKET/users/{userId}/test.txt

# Search for it
./file-search.sh "test"

# Download it
./download.sh "test.txt"

# Verify
cat ./clouddrive-downloads/test.txt
```

## Future Enhancements

Potential improvements:
- [ ] Batch upload functionality
- [ ] File preview (images, PDFs)
- [ ] Progress bars for large files
- [ ] Parallel downloads
- [ ] File metadata editing
- [ ] Folder sync (bidirectional)
- [ ] Claude Memory integration
- [ ] Automatic token refresh in download script
- [ ] Support for shared/public files

## Architecture Details

### S3 Bucket Structure
```
s3://{COGNITO_S3_BUCKET}/
├── users/
│   └── {userId}/           # User-specific files
│       ├── file1.pdf
│       ├── folder1/
│       │   └── file2.txt
│       └── .folder         # Folder marker
├── claude-memory/
│   ├── public/             # Public memory files
│   └── {userId}/           # User memory files
└── (CloudFront assets)     # Website files
```

### Authentication Flow (API Mode)

1. **Login**:
   - User provides email/password
   - Script calls `aws cognito-idp initiate-auth`
   - Returns ID token, access token, refresh token
   - Tokens stored locally

2. **Download**:
   - Script calls `GET /api/s3/download/{key}` with `Authorization: Bearer {idToken}`
   - Lambda validates token via Cognito
   - Lambda checks user permission (file must be under `users/{userId}/`)
   - Lambda generates S3 presigned URL (15 min)
   - Script downloads directly from S3

3. **Token Refresh**:
   - When token expires, use refresh token
   - Calls `aws cognito-idp initiate-auth` with `REFRESH_TOKEN_AUTH`
   - Returns new ID and access tokens

## License

Part of the CloudDrive project. See main project LICENSE.

## Support

For issues or questions:
1. Check this README
2. Review the CloudDrive API documentation
3. Check AWS CloudWatch logs for Lambda errors
4. File an issue in the project repository
