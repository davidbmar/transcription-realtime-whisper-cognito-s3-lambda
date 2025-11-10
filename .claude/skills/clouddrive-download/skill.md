---
name: clouddrive-download
description: Download files shared via CloudDrive - the primary way for users to share screenshots, designs, and documents with Claude
---

# CloudDrive File Download Skill

**Primary file sharing method:** Users upload files to CloudDrive, Claude downloads them automatically.

## Quick Start

**User workflow:**
1. Upload screenshot/file to CloudDrive web UI
2. Tell Claude: "Check my latest screenshot" or "Download that design I uploaded"
3. Claude finds and downloads it automatically
4. Claude analyzes and responds

**No paths, no user IDs needed** - just natural conversation.

## Overview

This skill uses AWS CLI for instant S3 access to CloudDrive files. It's the **fastest and easiest** way to share files with Claude.

**Prerequisites:**
- AWS CLI installed and configured
- IAM credentials with S3 read access to the CloudDrive bucket

## Configuration

The skill uses configuration from the project's `.env` file:
- **S3 Bucket**: `COGNITO_S3_BUCKET` (from .env)
- **Region**: `AWS_REGION` (from .env)

**AWS Credentials:**
Ensure your AWS credentials are configured via:
- IAM role (if running on EC2)
- `~/.aws/credentials` file
- Environment variables (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY)

## Usage - Natural Language

**Just ask naturally! Claude handles everything:**

### User → Claude File Sharing (Primary Use)
- "I uploaded a screenshot to CloudDrive"
- "Check that design mockup I just uploaded"
- "Download my latest screenshot"
- "Get the PDF from /documents/"
- "Show me what I uploaded today"

### Alternative Commands
- "Download `filename.png` from CloudDrive"
- "Search for screenshots"
- "List my CloudDrive files"
- "Find files with 'design' in the name"

## Features

1. **Direct S3 Access**
   - Fast downloads using AWS CLI
   - No token management needed
   - Uses existing IAM permissions

2. **File Discovery**
   - Search by filename or pattern
   - List directory contents
   - Show file metadata (size, modified date)
   - Support for wildcards and regex

3. **Download Options**
   - Single file download
   - Batch download (entire folders)
   - Wildcard/pattern matching
   - Progress indicators

4. **Smart User Detection**
   - Automatically finds user ID from available users
   - Or uses authenticated user ID from token

## Scripts

- `download.sh` - Main download script using AWS CLI
- `file-search.sh` - File search and listing utility
- `auth-helper.sh` - (Future: Cognito authentication for non-dev use)

## How It Works

Uses AWS CLI to directly access S3:
```bash
aws s3 sync s3://bucket/users/{userId}/{path} ./downloads/
```

## Download Location

Files are downloaded to: `./clouddrive-downloads/`

## Error Handling

- Validates file existence before download
- Handles expired tokens (auto-refresh)
- Provides clear error messages
- Retries on transient failures

## Security Notes

- AWS credentials used from standard AWS credential chain
- IAM permissions control access to S3 bucket
- For development/internal use only
- Production users should use CloudDrive web UI (OAuth/SRP authentication)

## Examples

```bash
# Download single file
./download.sh "Screenshot 2025-10-31 at 11.38.37 AM.png"

# Download from specific folder
./download.sh "test/myfile.pdf"

# Search for files
./file-search.sh "*.png"

# List all user files
./file-search.sh --list
```

## Implementation Notes

When invoked through Claude Code, the skill:
1. Verifies AWS CLI credentials are available
2. Searches for requested files in S3
3. Downloads to `./clouddrive-downloads/`
4. Reports success and file location
5. For images, offers to display them

**Note:** This is a development tool. End users should access files through the CloudDrive web UI.
