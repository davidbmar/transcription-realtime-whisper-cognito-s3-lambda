#!/usr/bin/env node

/**
 * CloudDrive Browser Automation
 * Uses Playwright to test and interact with CloudDrive web UI
 */

const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
const readline = require('readline');
require('dotenv').config({ path: path.join(__dirname, '../../..', '.env') });

// Configuration - all from .env, no hardcoded defaults
const CLOUDDRIVE_URL = process.env.COGNITO_CLOUDFRONT_URL;
const EMAIL = process.env.CLOUDDRIVE_TEST_EMAIL;
const PASSWORD = process.env.CLOUDDRIVE_TEST_PASSWORD;
const HEADLESS = process.env.HEADLESS !== 'false'; // Run headless by default
const SCREENSHOT_DIR = path.join(__dirname, '../../..', 'browser-screenshots');
const DOWNLOAD_DIR = path.join(__dirname, '../../..', 'browser-downloads');

// Create directories
[SCREENSHOT_DIR, DOWNLOAD_DIR].forEach(dir => {
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
});

// Utility functions
function log(message, level = 'INFO') {
  const colors = {
    'INFO': '\x1b[34m',
    'SUCCESS': '\x1b[32m',
    'WARN': '\x1b[33m',
    'ERROR': '\x1b[31m'
  };
  const reset = '\x1b[0m';
  console.log(`${colors[level]}[${level}]${reset} ${message}`);
}

/**
 * Prompt for credentials and save to .env
 */
async function promptForCredentials() {
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout
  });

  const question = (query) => new Promise((resolve) => rl.question(query, resolve));

  log('CloudDrive credentials not found in .env file', 'WARN');
  log('Please provide your CloudDrive login credentials:', 'INFO');
  log('These will be saved to .env (which is gitignored)', 'INFO');
  console.log('');

  const email = await question('Email: ');
  const password = await question('Password: ');

  rl.close();

  // Append to .env file
  const envPath = path.join(__dirname, '../../..', '.env');
  const envContent = `\n# CloudDrive Browser Testing (auto-generated)\nCLOUDDRIVE_TEST_EMAIL=${email}\nCLOUDDRIVE_TEST_PASSWORD=${password}\n`;

  fs.appendFileSync(envPath, envContent);

  log('Credentials saved to .env file', 'SUCCESS');
  log('You can update them by editing .env or deleting these lines to re-prompt', 'INFO');
  console.log('');

  return { email, password };
}

async function takeScreenshot(page, name) {
  const filename = `${name}-${Date.now()}.png`;
  const filepath = path.join(SCREENSHOT_DIR, filename);
  await page.screenshot({ path: filepath, fullPage: true });
  log(`Screenshot saved: ${filepath}`, 'SUCCESS');
  return filepath;
}

/**
 * Login to CloudDrive via Cognito
 */
async function login(page, email, password) {
  log('Navigating to CloudDrive...');
  await page.goto(CLOUDDRIVE_URL, { waitUntil: 'networkidle' });

  await takeScreenshot(page, 'initial-page');

  // Check if already logged in
  const logoutButton = await page.$('#logout-button');
  if (logoutButton && await logoutButton.isVisible()) {
    log('Already logged in!', 'SUCCESS');
    return true;
  }

  log('Clicking login button...');
  await page.click('#login-button');

  // Wait for Cognito hosted UI
  log('Waiting for Cognito login page...');
  await page.waitForURL(/.*amazoncognito\.com.*/, { timeout: 10000 });

  await takeScreenshot(page, 'cognito-login-page');

  // Fill in credentials
  log(`Logging in as: ${email}`);

  // Cognito has duplicate forms - use .last() to get the visible one
  await page.getByPlaceholder('name@host.com').last().fill(email);
  await page.getByPlaceholder('Password').last().fill(password);

  await takeScreenshot(page, 'credentials-filled');

  // Submit login - press Enter on password field (simpler than finding button)
  await page.getByPlaceholder('Password').last().press('Enter');

  // Wait for redirect back to CloudDrive
  log('Waiting for authentication callback...');
  await page.waitForURL(`${CLOUDDRIVE_URL}/**`, { timeout: 15000 });

  // Wait for authenticated section to appear
  await page.waitForSelector('#authenticated-section', { state: 'visible', timeout: 10000 });

  await takeScreenshot(page, 'logged-in');

  log('Login successful!', 'SUCCESS');
  return true;
}

/**
 * Upload a file to CloudDrive
 */
async function uploadFile(page, filePath) {
  const fileName = path.basename(filePath);
  log(`Uploading file: ${fileName}`);

  // Click upload button
  await page.click('#upload-button');
  await page.waitForSelector('#upload-modal', { state: 'visible' });

  await takeScreenshot(page, 'upload-modal');

  // Set file input
  const fileInput = await page.$('input[type="file"]#file-input');
  await fileInput.setInputFiles(filePath);

  // Wait for file to appear in queue
  await page.waitForSelector('.file-item', { timeout: 5000 });

  await takeScreenshot(page, 'file-selected');

  // Click upload all button
  await page.click('#upload-all-button');

  // Wait for upload to complete
  log('Waiting for upload to complete...');
  await page.waitForFunction(
    () => {
      const items = document.querySelectorAll('.file-item');
      return Array.from(items).every(item =>
        item.classList.contains('upload-complete') || item.classList.contains('upload-error')
      );
    },
    { timeout: 30000 }
  );

  await takeScreenshot(page, 'upload-complete');

  // Close modal
  await page.click('#close-upload-modal');

  // Refresh file list
  await page.click('#refresh-button');
  await page.waitForTimeout(1000);

  await takeScreenshot(page, 'file-list-refreshed');

  log(`File uploaded successfully: ${fileName}`, 'SUCCESS');
  return true;
}

/**
 * Download a file from CloudDrive
 */
async function downloadFile(page, fileName) {
  log(`Searching for file: ${fileName}`);

  // Wait for file list to load
  await page.waitForSelector('#file-list', { state: 'visible' });

  // Find the file in the list
  const fileRow = await page.locator(`.file-item:has-text("${fileName}")`).first();

  if (!await fileRow.count()) {
    log(`File not found: ${fileName}`, 'ERROR');
    return false;
  }

  log('File found in list');
  await takeScreenshot(page, 'file-found');

  // Setup download listener
  const downloadPromise = page.waitForEvent('download');

  // Click download button for the file
  await fileRow.locator('.download-button').click();

  // Wait for download to start
  const download = await downloadPromise;

  // Save to download directory
  const downloadPath = path.join(DOWNLOAD_DIR, fileName);
  await download.saveAs(downloadPath);

  log(`File downloaded to: ${downloadPath}`, 'SUCCESS');
  return true;
}

/**
 * Navigate to a folder
 */
async function navigateToFolder(page, folderName) {
  log(`Navigating to folder: ${folderName}`);

  // Find and click folder
  const folderRow = await page.locator(`.file-item.folder:has-text("${folderName}")`).first();

  if (!await folderRow.count()) {
    log(`Folder not found: ${folderName}`, 'ERROR');
    return false;
  }

  await folderRow.dblclick();

  // Wait for navigation
  await page.waitForTimeout(1000);

  await takeScreenshot(page, `folder-${folderName}`);

  log(`Navigated to folder: ${folderName}`, 'SUCCESS');
  return true;
}

/**
 * List all files in current view
 */
async function listFiles(page) {
  log('Listing files...');

  await page.waitForSelector('#file-list', { state: 'visible' });

  const files = await page.$$eval('.file-item', items => {
    return items.map(item => ({
      name: item.querySelector('.file-name')?.textContent || 'Unknown',
      size: item.querySelector('.file-size')?.textContent || '',
      date: item.querySelector('.file-date')?.textContent || '',
      isFolder: item.classList.contains('folder')
    }));
  });

  log(`Found ${files.length} items:`);
  files.forEach(file => {
    const icon = file.isFolder ? '📁' : '📄';
    console.log(`  ${icon} ${file.name} ${file.size} ${file.date}`);
  });

  return files;
}

/**
 * Run a full workflow test
 */
async function testWorkflow(page, email, password) {
  log('Starting full workflow test...', 'INFO');

  // Create a test file
  const testFileName = `test-${Date.now()}.txt`;
  const testFilePath = path.join('/tmp', testFileName);
  fs.writeFileSync(testFilePath, `CloudDrive test file created at ${new Date().toISOString()}`);
  log(`Created test file: ${testFilePath}`);

  try {
    // Login
    await login(page, email, password);

    // List initial files
    log('\n--- Initial File List ---');
    await listFiles(page);

    // Upload test file
    log('\n--- Uploading Test File ---');
    await uploadFile(page, testFilePath);

    // Verify file appears
    log('\n--- Updated File List ---');
    const files = await listFiles(page);
    const uploaded = files.find(f => f.name === testFileName);

    if (uploaded) {
      log(`✓ Test file found in list: ${testFileName}`, 'SUCCESS');
    } else {
      log(`✗ Test file NOT found in list!`, 'ERROR');
    }

    // Take final screenshot
    await takeScreenshot(page, 'workflow-complete');

    log('\nWorkflow test completed!', 'SUCCESS');

  } catch (error) {
    log(`Workflow test failed: ${error.message}`, 'ERROR');
    await takeScreenshot(page, 'workflow-error');
    throw error;
  } finally {
    // Cleanup
    fs.unlinkSync(testFilePath);
  }
}

/**
 * Main entry point
 */
async function main() {
  const command = process.argv[2] || 'test-workflow';
  const args = process.argv.slice(3);

  log('CloudDrive Browser Automation');
  log('==============================');
  log(`Command: ${command}`);
  log(`Headless: ${HEADLESS}`);
  log('');

  // Validate required environment variables from .env
  if (!CLOUDDRIVE_URL) {
    log('ERROR: COGNITO_CLOUDFRONT_URL not set in .env', 'ERROR');
    log('', 'ERROR');
    log('Required .env variables:', 'ERROR');
    log('  COGNITO_CLOUDFRONT_URL=https://your-cloudfront-url.cloudfront.net', 'ERROR');
    log('', 'ERROR');
    log('Copy .env.example to .env and fill in your deployment values', 'WARN');
    process.exit(1);
  }

  log(`CloudDrive URL: ${CLOUDDRIVE_URL}`);
  log('');

  // Check if credentials are set, if not prompt for them
  let email = EMAIL;
  let password = PASSWORD;

  if (!email || !password) {
    const credentials = await promptForCredentials();
    email = credentials.email;
    password = credentials.password;

    // Reload environment to pick up new credentials
    delete require.cache[require.resolve('dotenv')];
    require('dotenv').config({ path: path.join(__dirname, '../../..', '.env') });
  }

  const browser = await chromium.launch({
    headless: HEADLESS,
    slowMo: HEADLESS ? 0 : 100 // Slow down actions in headed mode for visibility
  });

  const context = await browser.newContext({
    acceptDownloads: true,
    viewport: { width: 1280, height: 720 }
  });

  const page = await context.newPage();

  try {
    switch (command) {
      case 'login':
        await login(page, email, password);
        await listFiles(page);
        break;

      case 'upload':
        if (args.length < 1) {
          log('Usage: browser-test.js upload <file-path>', 'ERROR');
          process.exit(1);
        }
        await login(page, email, password);
        await uploadFile(page, args[0]);
        break;

      case 'download':
        if (args.length < 1) {
          log('Usage: browser-test.js download <file-name>', 'ERROR');
          process.exit(1);
        }
        await login(page, email, password);
        await downloadFile(page, args[0]);
        break;

      case 'list':
        await login(page, email, password);
        await listFiles(page);
        break;

      case 'test-workflow':
        await testWorkflow(page, email, password);
        break;

      default:
        log(`Unknown command: ${command}`, 'ERROR');
        log('Available commands: login, upload, download, list, test-workflow');
        process.exit(1);
    }

    log('\n✓ Command completed successfully', 'SUCCESS');

    // Keep browser open in headed mode
    if (!HEADLESS) {
      log('Browser will stay open. Press Ctrl+C to close.', 'INFO');
      await new Promise(() => {}); // Keep alive
    }

  } catch (error) {
    log(`\n✗ Error: ${error.message}`, 'ERROR');
    console.error(error);
    await takeScreenshot(page, 'error');
    process.exit(1);
  } finally {
    if (HEADLESS) {
      await browser.close();
    }
  }
}

// Run if called directly
if (require.main === module) {
  main().catch(console.error);
}

module.exports = { login, uploadFile, downloadFile, listFiles, navigateToFolder, promptForCredentials };
