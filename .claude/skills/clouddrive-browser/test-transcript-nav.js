#!/usr/bin/env node

/**
 * Test CloudDrive Transcript Editor Navigation Flow
 * Logs in, clicks "Transcript Editor" button from dashboard, and reports what happens
 */

const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '../../..', '.env') });

// Configuration
const CLOUDDRIVE_URL = process.env.COGNITO_CLOUDFRONT_URL;
const EMAIL = process.env.CLOUDDRIVE_TEST_EMAIL;
const PASSWORD = process.env.CLOUDDRIVE_TEST_PASSWORD;
const HEADLESS = process.env.HEADLESS !== 'false';
const SCREENSHOT_DIR = path.join(__dirname, '../../..', 'browser-screenshots');

// Ensure screenshot directory exists
if (!fs.existsSync(SCREENSHOT_DIR)) {
  fs.mkdirSync(SCREENSHOT_DIR, { recursive: true });
}

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

async function takeScreenshot(page, name) {
  const filename = `${name}-${Date.now()}.png`;
  const filepath = path.join(SCREENSHOT_DIR, filename);
  await page.screenshot({ path: filepath, fullPage: true });
  log(`Screenshot saved: ${filepath}`, 'SUCCESS');
  return filepath;
}

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

  await page.getByPlaceholder('name@host.com').last().fill(email);
  await page.getByPlaceholder('Password').last().fill(password);

  await takeScreenshot(page, 'credentials-filled');

  // Submit login
  await page.getByPlaceholder('Password').last().press('Enter');

  // Wait for redirect back to CloudDrive
  log('Waiting for authentication callback...');
  await page.waitForURL(`${CLOUDDRIVE_URL}/**`, { timeout: 15000 });

  // Wait for dashboard to appear (check for either old or new dashboard)
  try {
    await page.waitForSelector('text=CloudDrive Dashboard', { state: 'visible', timeout: 10000 });
  } catch (e) {
    // Try old dashboard selector
    await page.waitForSelector('#authenticated-section', { state: 'visible', timeout: 10000 });
  }

  await takeScreenshot(page, 'logged-in-dashboard');

  log('Login successful!', 'SUCCESS');
  return true;
}

async function testTranscriptEditorNavigation(page) {
  log('\n=== Testing Transcript Editor Navigation ===\n');

  // Look for Transcript Editor button/link
  log('Looking for "Transcript Editor" button/link...');

  // Try multiple possible selectors
  const possibleSelectors = [
    'text=Edit Transcripts',  // The button text on the dashboard card
    'button:has-text("Edit Transcripts")',
    'a:has-text("Edit Transcripts")',
    'button:has-text("Transcript Editor")',
    'a:has-text("Transcript Editor")',
    '#transcript-editor-button',
    '.transcript-editor-button',
    '[href*="transcript-editor"]',
    'text=Transcript Editor'
  ];

  let editorButton = null;
  let foundSelector = null;

  for (const selector of possibleSelectors) {
    try {
      const element = await page.$(selector);
      if (element && await element.isVisible()) {
        editorButton = element;
        foundSelector = selector;
        log(`Found element with selector: ${selector}`, 'SUCCESS');
        break;
      }
    } catch (e) {
      // Try next selector
    }
  }

  if (!editorButton) {
    log('Transcript Editor button/link not found!', 'ERROR');
    log('Taking screenshot of current page...');
    const screenshot = await takeScreenshot(page, 'no-transcript-editor-button');

    // Get page content for debugging
    const bodyText = await page.textContent('body');
    log('\nPage content preview:');
    console.log(bodyText.substring(0, 500) + '...\n');

    return {
      success: false,
      error: 'Transcript Editor button/link not found',
      screenshot,
      url: page.url()
    };
  }

  // Take screenshot before clicking
  log('Taking screenshot before clicking...');
  const beforeScreenshot = await takeScreenshot(page, 'before-click-transcript-editor');

  // Get current URL
  const beforeUrl = page.url();
  log(`Current URL: ${beforeUrl}`);

  // Click the button
  log('Clicking "Transcript Editor" button...');
  await editorButton.click();

  // Wait for navigation or page changes
  await page.waitForTimeout(2000); // Give page time to respond

  // Check if URL changed
  const afterUrl = page.url();
  log(`URL after click: ${afterUrl}`);

  // Take screenshot after clicking
  log('Taking screenshot after clicking...');
  const afterScreenshot = await takeScreenshot(page, 'after-click-transcript-editor');

  // Check for errors on the page
  const errorMessages = await page.$$eval('[class*="error"], .alert-danger, .error-message', elements => {
    return elements.map(el => el.textContent.trim()).filter(text => text.length > 0);
  }).catch(() => []);

  // Get page title
  const pageTitle = await page.title();

  // Get main heading if present
  let mainHeading = null;
  try {
    mainHeading = await page.textContent('h1');
  } catch (e) {
    // No h1 found
  }

  // Analyze the URL to understand what happened
  let navigation = 'No navigation';
  if (afterUrl !== beforeUrl) {
    if (afterUrl.includes('transcript-editor.html')) {
      navigation = 'Navigated to transcript-editor.html';

      // Check if sessionId parameter is present
      const url = new URL(afterUrl);
      const sessionId = url.searchParams.get('sessionId') || url.searchParams.get('session');
      if (sessionId) {
        navigation += ` with sessionId/session=${sessionId}`;
      } else {
        navigation += ' without sessionId/session parameter';
      }
    } else {
      navigation = `Navigated to different page: ${afterUrl}`;
    }
  } else {
    navigation = 'Stayed on same page (no navigation)';
  }

  // Report results
  log('\n=== TEST RESULTS ===\n', 'SUCCESS');
  log(`Navigation: ${navigation}`);
  log(`Page Title: ${pageTitle}`);
  if (mainHeading) {
    log(`Main Heading: ${mainHeading}`);
  }
  log(`URL Before: ${beforeUrl}`);
  log(`URL After: ${afterUrl}`);
  log(`Screenshot Before: ${beforeScreenshot}`);
  log(`Screenshot After: ${afterScreenshot}`);

  if (errorMessages.length > 0) {
    log('\nErrors found on page:', 'WARN');
    errorMessages.forEach(msg => log(`  - ${msg}`, 'WARN'));
  } else {
    log('No errors found on page', 'SUCCESS');
  }

  return {
    success: true,
    navigation,
    beforeUrl,
    afterUrl,
    pageTitle,
    mainHeading,
    errorMessages,
    beforeScreenshot,
    afterScreenshot,
    foundSelector
  };
}

async function main() {
  log('CloudDrive Transcript Editor Navigation Test');
  log('===========================================');
  log(`CloudDrive URL: ${CLOUDDRIVE_URL}`);
  log(`Headless: ${HEADLESS}`);
  log('');

  if (!CLOUDDRIVE_URL || !EMAIL || !PASSWORD) {
    log('Missing required environment variables!', 'ERROR');
    log('Required: COGNITO_CLOUDFRONT_URL, CLOUDDRIVE_TEST_EMAIL, CLOUDDRIVE_TEST_PASSWORD', 'ERROR');
    process.exit(1);
  }

  const browser = await chromium.launch({
    headless: HEADLESS,
    slowMo: HEADLESS ? 0 : 100
  });

  const context = await browser.newContext({
    viewport: { width: 1280, height: 720 }
  });

  const page = await context.newPage();

  try {
    // Login
    await login(page, EMAIL, PASSWORD);

    // Test transcript editor navigation
    const result = await testTranscriptEditorNavigation(page);

    // Print summary
    log('\n=== SUMMARY ===\n', 'SUCCESS');
    console.log(JSON.stringify(result, null, 2));

    // Keep browser open in headed mode
    if (!HEADLESS) {
      log('\nBrowser will stay open. Press Ctrl+C to close.', 'INFO');
      await new Promise(() => {});
    }

  } catch (error) {
    log(`\nError: ${error.message}`, 'ERROR');
    console.error(error);
    await takeScreenshot(page, 'error');
    process.exit(1);
  } finally {
    if (HEADLESS) {
      await browser.close();
    }
  }
}

if (require.main === module) {
  main().catch(console.error);
}
