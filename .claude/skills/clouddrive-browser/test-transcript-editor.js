#!/usr/bin/env node

/**
 * CloudDrive Transcript Editor Viewer
 * Opens a specific transcript session in the editor and takes screenshots
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

// Create directories
if (!fs.existsSync(SCREENSHOT_DIR)) {
  fs.mkdirSync(SCREENSHOT_DIR, { recursive: true });
}

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
  log('Starting login process...');

  // Check if already on dashboard
  const dashboardVisible = await page.locator('text=CloudDrive Dashboard').isVisible().catch(() => false);
  if (dashboardVisible) {
    log('Already logged in!', 'SUCCESS');
    return true;
  }

  // Click login button if on landing page
  const loginButton = await page.$('#login-button');
  if (loginButton) {
    log('Clicking login button...');
    await loginButton.click();

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
  }

  // Wait for dashboard to appear
  await page.waitForSelector('text=CloudDrive Dashboard', { state: 'visible', timeout: 10000 });
  log('Login successful!', 'SUCCESS');
  return true;
}

/**
 * Open transcript editor for a specific session
 */
async function openTranscriptEditor(page, sessionId) {
  log(`Opening transcript editor for session: ${sessionId}`);

  // Navigate directly to transcript editor with session parameter
  const editorUrl = `${CLOUDDRIVE_URL}/transcript-editor.html?session=${sessionId}`;
  log(`Navigating to: ${editorUrl}`);
  await page.goto(editorUrl, { waitUntil: 'networkidle' });

  await takeScreenshot(page, 'transcript-editor-initial');

  // Wait for page to stabilize
  log('Waiting for transcript editor to load...');
  await page.waitForTimeout(3000);

  // Try to find session selector (may not exist if auto-loading)
  const sessionSelect = await page.$('#session-select');
  if (!sessionSelect) {
    log('Session selector not found - may be auto-loading', 'WARN');
    // Take a screenshot anyway to see current state
    await takeScreenshot(page, 'editor-state-no-selector');

    // Check if there's an error message
    const errorMessage = await page.textContent('.error-message').catch(() => null);
    if (errorMessage) {
      log(`Error on page: ${errorMessage}`, 'ERROR');
    }

    // Return true to continue with screenshot capture
    return true;
  }

  // Get all available sessions
  const sessions = await page.$$eval('#session-select option', options =>
    options.map(opt => ({ value: opt.value, text: opt.textContent }))
  );

  log(`Found ${sessions.length} sessions:`);
  sessions.forEach(session => {
    console.log(`  - ${session.text} (${session.value})`);
  });

  // Find the target session
  const targetSession = sessions.find(s => s.value.includes(sessionId));
  if (!targetSession) {
    log(`Session not found: ${sessionId}`, 'ERROR');
    log(`Available sessions: ${sessions.map(s => s.value).join(', ')}`, 'INFO');
    return false;
  }

  log(`Found target session: ${targetSession.text}`, 'SUCCESS');

  // Select the session
  await page.selectOption('#session-select', targetSession.value);

  // Click load button
  await page.click('#load-button');

  // Wait for transcript to load
  log('Waiting for transcript to load...');
  await page.waitForTimeout(2000); // Give it time to load

  await takeScreenshot(page, 'transcript-loaded');

  // Check if chunks are visible
  const chunks = await page.$$('.chunk-item');
  log(`Found ${chunks.length} chunks in transcript`, 'SUCCESS');

  // Get transcript container styles
  const containerStyles = await page.evaluate(() => {
    const container = document.getElementById('transcript-container');
    if (!container) return null;

    const styles = window.getComputedStyle(container);
    return {
      display: styles.display,
      gridTemplateColumns: styles.gridTemplateColumns,
      gap: styles.gap,
      padding: styles.padding
    };
  });

  log('Transcript container styles:');
  console.log(JSON.stringify(containerStyles, null, 2));

  // Get first chunk details
  const firstChunkDetails = await page.evaluate(() => {
    const firstChunk = document.querySelector('.chunk-item');
    if (!firstChunk) return null;

    const styles = window.getComputedStyle(firstChunk);
    return {
      display: styles.display,
      gridTemplateColumns: styles.gridTemplateColumns,
      gap: styles.gap,
      innerHTML: firstChunk.innerHTML.substring(0, 500) // First 500 chars
    };
  });

  log('First chunk details:');
  console.log(JSON.stringify(firstChunkDetails, null, 2));

  // Highlight some words to see the label behavior
  log('Testing word highlighting...');

  // Click on first word span if it exists
  const firstWord = await page.$('.word-span');
  if (firstWord) {
    await firstWord.click();
    await page.waitForTimeout(500);
    await takeScreenshot(page, 'word-highlighted');

    // Check if chunk label is visible
    const chunkLabel = await page.evaluate(() => {
      const label = document.querySelector('.chunk-label.visible');
      if (!label) return null;

      const styles = window.getComputedStyle(label);
      return {
        text: label.textContent,
        position: styles.position,
        display: styles.display,
        left: styles.left,
        top: styles.top,
        backgroundColor: styles.backgroundColor
      };
    });

    log('Chunk label details:');
    console.log(JSON.stringify(chunkLabel, null, 2));
  }

  return true;
}

/**
 * Main entry point
 */
async function main() {
  const sessionId = process.argv[2] || 'session_2025-11-16T00_41_57_868Z';

  log('CloudDrive Transcript Editor Viewer');
  log('===================================');
  log(`Session ID: ${sessionId}`);
  log(`Headless: ${HEADLESS}`);
  log('');

  // Validate environment
  if (!CLOUDDRIVE_URL || !EMAIL || !PASSWORD) {
    log('ERROR: Missing required environment variables', 'ERROR');
    log('Required: COGNITO_CLOUDFRONT_URL, CLOUDDRIVE_TEST_EMAIL, CLOUDDRIVE_TEST_PASSWORD', 'ERROR');
    process.exit(1);
  }

  const browser = await chromium.launch({
    headless: HEADLESS,
    slowMo: HEADLESS ? 0 : 100
  });

  const context = await browser.newContext({
    viewport: { width: 1920, height: 1080 } // Larger viewport for better view
  });

  const page = await context.newPage();

  try {
    // Navigate to CloudDrive and login
    log('Navigating to CloudDrive...');
    await page.goto(CLOUDDRIVE_URL, { waitUntil: 'networkidle' });
    await takeScreenshot(page, 'dashboard-initial');

    // Check if already logged in
    const dashboardVisible = await page.locator('text=CloudDrive Dashboard').isVisible().catch(() => false);

    if (!dashboardVisible) {
      // Need to login
      log('Logging in to CloudDrive...');
      await login(page, EMAIL, PASSWORD);
      await takeScreenshot(page, 'dashboard-after-login');
    } else {
      log('Already logged in!', 'SUCCESS');
    }

    // Open transcript editor
    await openTranscriptEditor(page, sessionId);

    log('\n✓ Transcript editor opened successfully', 'SUCCESS');
    log(`Screenshots saved to: ${SCREENSHOT_DIR}`, 'INFO');

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

module.exports = { openTranscriptEditor };
