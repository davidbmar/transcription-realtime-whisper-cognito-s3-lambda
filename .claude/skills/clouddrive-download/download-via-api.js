#!/usr/bin/env node
/**
 * CloudDrive API File Downloader
 * Authenticates with Cognito and downloads files via the CloudDrive API
 */

const https = require('https');
const fs = require('fs');
const path = require('path');

// Load environment
require('dotenv').config({ path: path.join(__dirname, '../../../.env') });

const CONFIG = {
  cloudFrontUrl: process.env.COGNITO_CLOUDFRONT_URL,
  apiUrl: process.env.COGNITO_API_ENDPOINT,
  userPoolId: process.env.COGNITO_USER_POOL_ID,
  clientId: process.env.COGNITO_USER_POOL_CLIENT_ID,
  email: process.env.CLOUDDRIVE_TEST_EMAIL,
  password: process.env.CLOUDDRIVE_TEST_PASSWORD,
  downloadDir: path.join(__dirname, '../../../clouddrive-downloads')
};

// Ensure download directory exists
if (!fs.existsSync(CONFIG.downloadDir)) {
  fs.mkdirSync(CONFIG.downloadDir, { recursive: true });
}

/**
 * Authenticate with Cognito and get ID token
 */
async function authenticate() {
  console.log('🔐 Authenticating with Cognito...');

  // This is a simplified version - in reality you'd need to:
  // 1. Initiate auth with USER_SRP_AUTH
  // 2. Calculate SRP_A
  // 3. Respond to PASSWORD_VERIFIER challenge
  // 4. Get tokens

  // For now, we'll use the browser approach via Playwright
  const { chromium } = require('playwright');

  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext();
  const page = await context.newPage();

  try {
    // Navigate to CloudDrive
    await page.goto(CONFIG.cloudFrontUrl);

    // Click login button
    await page.click('text=Login');

    // Wait for Cognito hosted UI
    await page.waitForURL(/.*amazoncognito.com.*/);

    // Fill in credentials
    await page.fill('input[name="username"]', CONFIG.email);
    await page.fill('input[name="password"]', CONFIG.password);
    await page.click('input[name="signInSubmitButton"]');

    // Wait for redirect back
    await page.waitForURL(CONFIG.cloudFrontUrl);

    // Extract tokens from localStorage
    const tokens = await page.evaluate(() => {
      const keys = Object.keys(localStorage);
      const idTokenKey = keys.find(k => k.includes('.idToken'));
      const accessTokenKey = keys.find(k => k.includes('.accessToken'));

      return {
        idToken: localStorage.getItem(idTokenKey),
        accessToken: localStorage.getItem(accessTokenKey)
      };
    });

    await browser.close();

    if (!tokens.idToken) {
      throw new Error('Failed to get authentication tokens');
    }

    console.log('✅ Authentication successful');
    return tokens;

  } catch (error) {
    await browser.close();
    throw error;
  }
}

/**
 * List files in user's CloudDrive
 */
async function listFiles(idToken) {
  return new Promise((resolve, reject) => {
    const url = new URL('/api/s3/list', CONFIG.apiUrl);

    const options = {
      method: 'GET',
      headers: {
        'Authorization': `Bearer ${idToken}`,
        'Content-Type': 'application/json'
      }
    };

    https.get(url.toString(), options, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        try {
          const result = JSON.parse(data);
          resolve(result.files || []);
        } catch (e) {
          reject(e);
        }
      });
    }).on('error', reject);
  });
}

/**
 * Get download URL for a file
 */
async function getDownloadUrl(idToken, fileKey) {
  return new Promise((resolve, reject) => {
    const url = new URL(`/api/s3/download/${encodeURIComponent(fileKey)}`, CONFIG.apiUrl);

    const options = {
      method: 'GET',
      headers: {
        'Authorization': `Bearer ${idToken}`,
        'Content-Type': 'application/json'
      }
    };

    https.get(url.toString(), options, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        try {
          const result = JSON.parse(data);
          resolve(result.downloadUrl);
        } catch (e) {
          reject(e);
        }
      });
    }).on('error', reject);
  });
}

/**
 * Download file from presigned URL
 */
async function downloadFile(presignedUrl, filename) {
  return new Promise((resolve, reject) => {
    const outputPath = path.join(CONFIG.downloadDir, filename);
    const file = fs.createWriteStream(outputPath);

    https.get(presignedUrl, (response) => {
      response.pipe(file);
      file.on('finish', () => {
        file.close();
        resolve(outputPath);
      });
    }).on('error', (err) => {
      fs.unlink(outputPath, () => {});
      reject(err);
    });
  });
}

/**
 * Main function
 */
async function main() {
  const searchPattern = process.argv[2];

  if (!searchPattern) {
    console.error('Usage: node download-via-api.js <filename-pattern>');
    process.exit(1);
  }

  try {
    // Authenticate
    const tokens = await authenticate();

    // List files
    console.log(`🔍 Searching for files matching: ${searchPattern}`);
    const files = await listFiles(tokens.idToken);

    // Find matching files
    const matches = files.filter(f =>
      f.key.toLowerCase().includes(searchPattern.toLowerCase()) ||
      f.displayKey.toLowerCase().includes(searchPattern.toLowerCase())
    );

    if (matches.length === 0) {
      console.log('❌ No files found matching pattern');
      return;
    }

    console.log(`📦 Found ${matches.length} file(s)`);

    // Download each file
    for (const file of matches) {
      console.log(`\n⬇️  Downloading: ${file.displayKey}`);

      // Get presigned download URL
      const downloadUrl = await getDownloadUrl(tokens.idToken, file.key);

      // Download file
      const outputPath = await downloadFile(downloadUrl, file.displayKey);

      console.log(`✅ Saved to: ${outputPath}`);

      // Show file size
      const stats = fs.statSync(outputPath);
      const sizeMB = (stats.size / 1024 / 1024).toFixed(2);
      console.log(`   Size: ${sizeMB} MB`);
    }

    console.log(`\n✨ Download complete! Files saved to: ${CONFIG.downloadDir}`);

  } catch (error) {
    console.error('❌ Error:', error.message);
    process.exit(1);
  }
}

main();
