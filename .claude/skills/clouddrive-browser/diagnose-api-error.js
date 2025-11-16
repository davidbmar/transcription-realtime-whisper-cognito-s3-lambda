#!/usr/bin/env node

/**
 * Diagnose Transcript Editor API Error
 * Captures network traffic to identify why API returns HTML instead of JSON
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
  log(`Screenshot: ${filepath}`, 'INFO');
  return filepath;
}

/**
 * Login to CloudDrive via Cognito
 */
async function login(page, email, password) {
  log('Starting login...');

  // Check if already logged in
  const dashboardVisible = await page.locator('text=CloudDrive Dashboard').isVisible().catch(() => false);
  if (dashboardVisible) {
    log('Already logged in!', 'SUCCESS');
    return true;
  }

  // Click login button
  const loginButton = await page.$('#login-button');
  if (loginButton) {
    await loginButton.click();

    // Wait for Cognito hosted UI
    await page.waitForURL(/.*amazoncognito\.com.*/, { timeout: 10000 });

    // Fill in credentials
    log(`Logging in as: ${email}`);
    await page.getByPlaceholder('name@host.com').last().fill(email);
    await page.getByPlaceholder('Password').last().fill(password);

    // Submit login
    await page.getByPlaceholder('Password').last().press('Enter');

    // Wait for redirect back to CloudDrive
    await page.waitForURL(`${CLOUDDRIVE_URL}/**`, { timeout: 15000 });
  }

  // Wait for dashboard to appear
  await page.waitForSelector('text=CloudDrive Dashboard', { state: 'visible', timeout: 10000 });
  log('Login successful!', 'SUCCESS');
  return true;
}

/**
 * Main diagnostic function
 */
async function diagnoseApiError() {
  log('=== Transcript Editor API Diagnostics ===', 'INFO');
  log('');

  // Validate environment
  if (!CLOUDDRIVE_URL || !EMAIL || !PASSWORD) {
    log('ERROR: Missing required environment variables', 'ERROR');
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

  // Storage for captured data
  const networkRequests = [];
  const networkResponses = [];
  const consoleLogs = [];

  // Capture console messages
  page.on('console', msg => {
    const text = msg.text();
    consoleLogs.push({ type: msg.type(), text });
    if (msg.type() === 'error' || text.includes('Failed') || text.includes('Error')) {
      log(`CONSOLE [${msg.type()}]: ${text}`, 'ERROR');
    } else {
      log(`CONSOLE [${msg.type()}]: ${text}`, 'INFO');
    }
  });

  // Capture network requests
  page.on('request', request => {
    if (request.url().includes('/api/')) {
      const req = {
        url: request.url(),
        method: request.method(),
        headers: request.headers()
      };
      networkRequests.push(req);
      log(`→ REQUEST: ${request.method()} ${request.url()}`, 'INFO');

      // Log auth header
      const authHeader = request.headers()['authorization'];
      if (authHeader) {
        log(`  Auth: Bearer ${authHeader.substring(7, 30)}...`, 'INFO');
      } else {
        log(`  ⚠️  NO Authorization header!`, 'WARN');
      }
    }
  });

  // Capture network responses
  page.on('response', async response => {
    if (response.url().includes('/api/')) {
      let body = null;
      let bodyText = null;

      try {
        bodyText = await response.text();
        try {
          body = JSON.parse(bodyText);
        } catch (e) {
          body = bodyText; // Not JSON, store as text
        }
      } catch (e) {
        log(`  Failed to read response body: ${e.message}`, 'WARN');
      }

      const resp = {
        url: response.url(),
        status: response.status(),
        statusText: response.statusText(),
        headers: response.headers(),
        body: body
      };

      networkResponses.push(resp);

      const statusColor = response.status() >= 400 ? 'ERROR' : 'SUCCESS';
      log(`← RESPONSE: ${response.status()} ${response.statusText()}`, statusColor);
      log(`  URL: ${response.url()}`, 'INFO');
      log(`  Content-Type: ${response.headers()['content-type']}`, 'INFO');

      if (bodyText) {
        const preview = bodyText.substring(0, 150).replace(/\n/g, ' ');
        log(`  Body: ${preview}${bodyText.length > 150 ? '...' : ''}`, 'INFO');
      }
    }
  });

  try {
    // Step 1: Login
    log('\n=== Step 1: Login ===', 'INFO');
    await page.goto(CLOUDDRIVE_URL, { waitUntil: 'networkidle' });
    await login(page, EMAIL, PASSWORD);
    await takeScreenshot(page, 'logged-in');

    // Step 2: Navigate to transcript editor
    log('\n=== Step 2: Navigate to Transcript Editor ===', 'INFO');
    const editorUrl = `${CLOUDDRIVE_URL}/transcript-editor.html`;
    log(`URL: ${editorUrl}`, 'INFO');

    await page.goto(editorUrl, { waitUntil: 'networkidle' });

    // Wait for page to settle and API calls to complete
    await page.waitForTimeout(5000);

    await takeScreenshot(page, 'transcript-editor-loaded');

    // Step 3: Check page for errors
    log('\n=== Step 3: Check for UI Errors ===', 'INFO');

    const errorText = await page.textContent('.error-message, .alert-danger, [class*="error"]').catch(() => null);
    if (errorText) {
      log(`Error message on page: ${errorText}`, 'ERROR');
    }

    const pageTitle = await page.textContent('h1, h2').catch(() => 'Unknown');
    log(`Page title: ${pageTitle}`, 'INFO');

    // Step 4: Analyze network traffic
    log('\n=== Step 4: Network Traffic Analysis ===', 'SUCCESS');
    log(`Total API requests: ${networkRequests.length}`, 'INFO');
    log(`Total API responses: ${networkResponses.length}`, 'INFO');
    log('');

    // Detailed analysis
    networkResponses.forEach((resp, idx) => {
      log(`\n--- API Call ${idx + 1} ---`, 'SUCCESS');
      log(`URL: ${resp.url}`, 'INFO');
      log(`Status: ${resp.status} ${resp.statusText}`, resp.status >= 400 ? 'ERROR' : 'SUCCESS');
      log(`Content-Type: ${resp.headers['content-type']}`, 'INFO');

      if (typeof resp.body === 'string' && resp.body.startsWith('<!DOCTYPE')) {
        log(`\n⚠️  PROBLEM: API returned HTML instead of JSON!`, 'ERROR');
        log(`This usually means:`, 'ERROR');
        log(`  1. The API endpoint doesn't exist (404)`, 'ERROR');
        log(`  2. CloudFront is serving the default index.html`, 'ERROR');
        log(`  3. The route is not configured in API Gateway`, 'ERROR');
        log(`\nHTML Response Preview:`, 'ERROR');
        console.log(resp.body.substring(0, 500));
      } else if (resp.body) {
        log(`Response Body:`, 'INFO');
        console.log(JSON.stringify(resp.body, null, 2));
      }
    });

    // Step 5: Summary
    log('\n=== DIAGNOSIS SUMMARY ===', 'SUCCESS');
    log('', 'INFO');

    const failedRequests = networkResponses.filter(r => r.status >= 400);
    const htmlResponses = networkResponses.filter(r =>
      typeof r.body === 'string' && r.body.startsWith('<!DOCTYPE')
    );
    const missingAuth = networkRequests.filter(r => !r.headers['authorization']);

    if (failedRequests.length > 0) {
      log(`❌ ${failedRequests.length} failed API request(s):`, 'ERROR');
      failedRequests.forEach(r => {
        log(`   ${r.status} ${r.url}`, 'ERROR');
      });
    }

    if (htmlResponses.length > 0) {
      log(`❌ ${htmlResponses.length} API(s) returning HTML instead of JSON:`, 'ERROR');
      htmlResponses.forEach(r => {
        log(`   ${r.url}`, 'ERROR');
      });
    }

    if (missingAuth.length > 0) {
      log(`⚠️  ${missingAuth.length} request(s) missing Authorization header:`, 'WARN');
      missingAuth.forEach(r => {
        log(`   ${r.method} ${r.url}`, 'WARN');
      });
    }

    if (failedRequests.length === 0 && htmlResponses.length === 0 && missingAuth.length === 0) {
      log(`✅ All API requests succeeded with valid responses`, 'SUCCESS');
    }

    // Save detailed report
    const reportPath = path.join(SCREENSHOT_DIR, `api-diagnostic-report-${Date.now()}.json`);
    const report = {
      timestamp: new Date().toISOString(),
      requests: networkRequests,
      responses: networkResponses,
      consoleLogs: consoleLogs,
      summary: {
        totalRequests: networkRequests.length,
        totalResponses: networkResponses.length,
        failedRequests: failedRequests.length,
        htmlResponses: htmlResponses.length,
        missingAuth: missingAuth.length
      }
    };

    fs.writeFileSync(reportPath, JSON.stringify(report, null, 2));
    log(`\nDetailed report saved: ${reportPath}`, 'SUCCESS');

  } catch (error) {
    log(`\n✗ Error: ${error.message}`, 'ERROR');
    console.error(error);
    await takeScreenshot(page, 'error');
    throw error;
  } finally {
    await browser.close();
  }
}

// Run
diagnoseApiError().catch(console.error);
