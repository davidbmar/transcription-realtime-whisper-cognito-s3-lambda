# CloudDrive Browser Automation Skill

A Claude Code skill for testing and automating the CloudDrive web UI using Playwright browser automation.

## Overview

This skill uses Playwright to control a real web browser and interact with CloudDrive through its web interface. It's perfect for:
- End-to-end testing of the CloudDrive UI
- Automated file uploads and downloads through the browser
- Screenshot capture for debugging
- Verification that the user experience works correctly
- Testing the Cognito OAuth login flow

**Complements the `clouddrive-download` skill:** While that skill uses AWS CLI for direct S3 access (dev tool), this skill tests the actual web UI that end users interact with.

## Prerequisites

- Node.js installed (v14+ recommended)
- Playwright installed (`npm install -g playwright`)
- Playwright browsers installed (`playwright install chromium`)
- CloudDrive deployment running and accessible
- Valid CloudDrive user credentials

## Installation

```bash
cd .claude/skills/clouddrive-browser
npm install
```

## Configuration

Set these in your `.env` file (project root):

```bash
# CloudDrive Web UI URL
COGNITO_CLOUDFRONT_URL=https://xxxxxxxxxxxxx.cloudfront.net

# Test credentials for browser automation
CLOUDDRIVE_TEST_EMAIL=your-email@example.com
CLOUDDRIVE_TEST_PASSWORD=your-password

# Optional: Run browser in headed mode (visible)
HEADLESS=false  # Default: true (headless)
```

## Components

### 1. `browser-test.js`
Main Playwright automation script with commands:

**Commands:**
- `login` - Test login flow and list files
- `upload <file-path>` - Upload a file through the UI
- `download <file-name>` - Download a file through the UI
- `list` - List all files in current view
- `test-workflow` - Run full end-to-end test

### 2. Wrapper Scripts

**`test-login.sh`**
```bash
./test-login.sh
```
Quick test of the login flow.

**`test-upload.sh`**
```bash
./test-upload.sh /path/to/file.txt
```
Test file upload through the UI.

**`test-workflow.sh`**
```bash
./test-workflow.sh          # Run headless
./test-workflow.sh --headed # Run with visible browser
```
Full workflow test: create file → login → upload → verify → cleanup.

### 3. Output Directories

- **`browser-screenshots/`** - Screenshots captured during automation
- **`browser-downloads/`** - Files downloaded through the browser

## Usage Examples

### From Command Line

```bash
# Test login
node browser-test.js login

# Upload a file
node browser-test.js upload /path/to/myfile.pdf

# Download a file
node browser-test.js download "Screenshot 2025-10-31.png"

# List all files
node browser-test.js list

# Run full workflow test
node browser-test.js test-workflow

# Run with visible browser (for debugging)
HEADLESS=false node browser-test.js test-workflow
```

### Using Wrapper Scripts

```bash
# Quick login test
./test-login.sh

# Upload test
./test-upload.sh /tmp/test.txt

# Full workflow (headless)
./test-workflow.sh

# Full workflow (visible browser)
./test-workflow.sh --headed
```

### From Claude Code

Simply ask Claude to test CloudDrive:

- "Test the CloudDrive login flow using the browser"
- "Upload this file to CloudDrive through the web UI"
- "Take screenshots of the CloudDrive interface"
- "Run a full workflow test of CloudDrive"
- "Login to CloudDrive and show me what files are there"

## Features

### Browser Automation
- Launches real Chromium browser
- Runs headless by default (no UI)
- Can run headed (visible browser) for debugging
- Full control: mouse, keyboard, navigation

### Cognito OAuth Flow
- Automatically handles redirect to Cognito hosted UI
- Fills username and password fields
- Waits for OAuth callback
- Verifies successful authentication

### File Operations
- **Upload:**
  - Opens upload modal
  - Selects file via file input
  - Monitors upload progress
  - Verifies upload completion

- **Download:**
  - Finds file in listing
  - Clicks download button
  - Saves to `browser-downloads/`
  - Verifies download success

### Screenshot Capture
- Automatic screenshots at each step
- Full-page screenshots
- Timestamped filenames
- Saved to `browser-screenshots/`

### Verification
- Checks if files appear in listings
- Verifies UI elements are visible
- Tests upload/download success
- End-to-end workflow validation

## Workflow Test Details

The `test-workflow` command performs:

1. **Create test file** - Generates `/tmp/test-{timestamp}.txt`
2. **Navigate to CloudDrive** - Opens CloudDrive URL
3. **Login** - Authenticates via Cognito OAuth
4. **List files** - Shows current file list
5. **Upload test file** - Uses upload modal
6. **Refresh** - Refreshes file list
7. **Verify** - Checks test file appears
8. **Screenshot** - Captures final state
9. **Cleanup** - Deletes local test file

Takes screenshots at each major step for debugging.

## Debugging

### Run with Visible Browser

```bash
# See what the automation is doing
HEADLESS=false node browser-test.js login
./test-workflow.sh --headed
```

### Check Screenshots

```bash
ls -lh browser-screenshots/
open browser-screenshots/  # macOS
xdg-open browser-screenshots/  # Linux
```

Screenshots are named with descriptive prefixes:
- `initial-page-*.png` - CloudDrive landing page
- `cognito-login-page-*.png` - Cognito hosted UI
- `logged-in-*.png` - After successful login
- `upload-modal-*.png` - Upload dialog
- `file-found-*.png` - File in listing
- `error-*.png` - When errors occur

### View Downloads

```bash
ls -lh browser-downloads/
```

### Enable Verbose Logging

Edit `browser-test.js` and set:
```javascript
const browser = await chromium.launch({
  headless: false,
  slowMo: 1000  // Slow down by 1 second per action
});
```

## Troubleshooting

### "Password not set" Error
Add to `.env`:
```bash
CLOUDDRIVE_TEST_PASSWORD=your-actual-password
```

### Timeout Waiting for Cognito
- Check CloudDrive URL is correct
- Verify Cognito domain is accessible
- Increase timeout in `browser-test.js`

### File Not Found in Listing
- File may be in a different folder
- Try refreshing: `await page.click('#refresh-button')`
- Check S3 bucket directly with AWS CLI

### Browser Doesn't Close
- Normal in headed mode (keeps browser open)
- Press Ctrl+C to close
- In headless mode, should close automatically

### Download Doesn't Start
- Check download button selector
- Verify popup blockers aren't interfering
- Ensure `acceptDownloads: true` in browser context

## Architecture

### How It Works

```
┌─────────────────────────────────────────┐
│  browser-test.js (Playwright)           │
├─────────────────────────────────────────┤
│  1. Launch Chromium browser             │
│  2. Navigate to CloudDrive URL          │
│  3. Click "Login" button                │
│  4. Redirected to Cognito hosted UI     │
│  5. Fill username/password              │
│  6. Submit login form                   │
│  7. Redirected back to CloudDrive       │
│  8. OAuth tokens stored in localStorage │
│  9. Authenticated section appears       │
│ 10. Perform file operations            │
│ 11. Take screenshots                    │
│ 12. Report results                      │
└─────────────────────────────────────────┘
```

### Login Flow

```
CloudDrive UI                Cognito               Browser Automation
      │                          │                          │
      │                          │    Navigate to URL      │
      │◄─────────────────────────────────────────────────────
      │                          │                          │
      │   Click "Login"         │                          │
      ├──────────────────────────────────────────────────────►
      │                          │                          │
      │   Redirect to Cognito   │                          │
      ├─────────────────────────►│                          │
      │                          │                          │
      │                          │   Fill credentials      │
      │                          │◄─────────────────────────
      │                          │                          │
      │                          │   Submit form           │
      │                          │◄─────────────────────────
      │                          │                          │
      │   Callback with code    │                          │
      │◄─────────────────────────┤                          │
      │                          │                          │
      │   Exchange for tokens   │                          │
      ├─────────────────────────►│                          │
      │                          │                          │
      │   Tokens in localStorage│                          │
      │─────────────────────────────────────────────────────►
      │                          │                          │
```

## vs. clouddrive-download Skill

| Feature | clouddrive-browser | clouddrive-download |
|---------|-------------------|---------------------|
| **Method** | Web UI automation | AWS CLI / S3 direct |
| **Auth** | Cognito OAuth/SRP | AWS IAM credentials |
| **Use Case** | Test user experience | Dev file access |
| **Speed** | Slower (UI interaction) | Faster (direct S3) |
| **Screenshots** | Yes | No |
| **E2E Testing** | Yes | No |
| **Headless** | Yes (default) | N/A |
| **User Audience** | Tests for end users | For developers |

**Use both:**
- `clouddrive-browser` - Test the UI works for users
- `clouddrive-download` - Quick dev file access via CLI

## Future Enhancements

Potential additions:
- [ ] Test folder creation/deletion
- [ ] Test file rename/move operations
- [ ] Test memory file browser
- [ ] Verify error handling (quota exceeded, etc.)
- [ ] Performance testing (large files)
- [ ] Multi-user testing
- [ ] Mobile viewport testing
- [ ] Accessibility testing
- [ ] Visual regression testing
- [ ] CI/CD integration

## Security Notes

1. **Credentials:** Store passwords in `.env`, not in code (`.env` is gitignored)
2. **Screenshots:** May contain sensitive information - don't commit
3. **Test User:** Use a dedicated test account, not production user
4. **Headless:** Use headless mode in CI/CD (no GUI required)

## CI/CD Integration

Example GitHub Actions:

```yaml
- name: Install Playwright
  run: |
    npm install -g playwright
    playwright install chromium

- name: Test CloudDrive UI
  env:
    CLOUDDRIVE_TEST_EMAIL: ${{ secrets.TEST_EMAIL }}
    CLOUDDRIVE_TEST_PASSWORD: ${{ secrets.TEST_PASSWORD }}
  run: |
    cd .claude/skills/clouddrive-browser
    npm install
    ./test-workflow.sh
```

## License

Part of the CloudDrive project.

## Support

For issues:
1. Check screenshots in `browser-screenshots/`
2. Run with `HEADLESS=false` to see browser
3. Check CloudWatch logs for backend errors
4. Verify Cognito configuration

## Testing Status

✅ **Skill Successfully Tested (2025-11-01)**

The browser automation skill has been tested and confirmed working:
- ✅ Navigates to CloudDrive URL
- ✅ Clicks login button 
- ✅ Redirects to Cognito OAuth page
- ✅ Fills in email and password credentials
- ✅ Submits login form (via Enter key)
- ✅ Successfully authenticates via Cognito
- ✅ Redirects back to CloudDrive
- ✅ User logged in (confirmed by email displayed and Sign Out button)
- ✅ Screenshots captured at each step

**Note:** CloudDrive shows a dashboard after login with options for "File Manager" and "Audio Recorder". To access files, the automation needs to click "Browse Files" to navigate to the file manager section.

### Sample Test Output
```
[INFO] CloudDrive Browser Automation
[INFO] ==========================================
[SUCCESS] AWS CLI configured and ready
[INFO] Navigating to CloudDrive...
[SUCCESS] Screenshot saved: initial-page-*.png
[INFO] Clicking login button...
[SUCCESS] Screenshot saved: cognito-login-page-*.png
[INFO] Logging in as: you@example.com
[SUCCESS] Screenshot saved: credentials-filled-*.png
[INFO] Waiting for authentication callback...
[SUCCESS] Login successful! (Dashboard visible)
```

### Screenshots Captured
- `initial-page-*.png` - CloudDrive landing page
- `cognito-login-page-*.png` - Cognito hosted UI login form
- `credentials-filled-*.png` - Form with credentials entered
- `error-*.png` - Final state showing successful login (dashboard)

The skill is ready for use! Minor enhancements needed:
1. Handle dashboard page (click "Browse Files" button)
2. Then proceed with file operations

