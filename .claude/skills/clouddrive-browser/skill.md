---
name: clouddrive-browser
description: Automate and test CloudDrive web UI using Playwright browser automation
---

# CloudDrive Browser Testing Skill

Automates interaction with the CloudDrive web UI using Playwright for testing, uploading files, downloading files, and verifying functionality.

## Overview

This skill uses Playwright to control a real web browser and interact with the CloudDrive web interface. It can:
- Login to CloudDrive via Cognito OAuth
- Upload files through the UI
- Download files through the UI
- Navigate folders and verify file listings
- Take screenshots for debugging
- Test UI functionality end-to-end

## Prerequisites

- Node.js and Playwright installed
- CloudDrive deployment running
- Valid CloudDrive user credentials

## Usage

Ask Claude to test or interact with CloudDrive through the browser:

### Login and Navigation
- "Login to CloudDrive and show me what's on the page"
- "Open CloudDrive in the browser and take a screenshot"
- "Test the CloudDrive login flow"

### File Operations
- "Upload a test file to CloudDrive using the browser"
- "Download the screenshot file using the CloudDrive UI"
- "Navigate to the test folder in CloudDrive"

### Testing
- "Test if I can upload and download files in CloudDrive"
- "Verify the file listing shows my uploaded files"
- "Take screenshots of each step of the upload process"

## Features

1. **Browser Automation**
   - Launches real Chrome/Chromium browser
   - Can run headed (visible) or headless
   - Full control over mouse, keyboard, navigation

2. **Cognito OAuth Flow**
   - Handles redirect to Cognito hosted UI
   - Fills in username and password
   - Waits for callback and token storage

3. **File Operations**
   - Upload files via drag-and-drop or file picker
   - Download files and verify downloads
   - Navigate folder structure

4. **Screenshot Capture**
   - Take full page screenshots
   - Capture specific elements
   - Save to `./browser-screenshots/`

5. **Verification**
   - Check if files appear in listings
   - Verify upload/download success
   - Test UI element visibility

## Configuration

Uses configuration from `.env`:
- `COGNITO_CLOUDFRONT_URL` - CloudDrive web UI URL
- Cognito credentials for login

## Scripts

- `browser-test.js` - Main Playwright automation script
- `test-login.sh` - Quick login test wrapper
- `test-upload.sh` - Test file upload flow
- `test-download.sh` - Test file download flow

## Output

- Screenshots saved to `./browser-screenshots/`
- Download files saved to `./browser-downloads/`
- Console output shows progress and results

## Examples

```bash
# Test login
./test-login.sh

# Upload a file
node browser-test.js upload test.txt

# Download a file
node browser-test.js download "Screenshot 2025-10-31.png"

# Full workflow test
node browser-test.js test-workflow
```

## Implementation Notes

When invoked through Claude Code, the skill:
1. Launches browser (headless by default, headed if debugging)
2. Navigates to CloudDrive URL
3. Performs requested actions (login, upload, download, etc.)
4. Takes screenshots at each step
5. Reports success/failure with evidence

This skill tests the actual user experience through the web UI, complementing the AWS CLI-based clouddrive-download skill.
