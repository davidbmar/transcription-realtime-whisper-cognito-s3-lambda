#!/usr/bin/env node
const { chromium } = require('playwright');

const CLOUDFRONT_URL = 'https://d2l28rla2hk7np.cloudfront.net';
const EMAIL = process.env.CLOUDDRIVE_TEST_EMAIL || 'david.bryan.mar@gmail.com';
const PASSWORD = process.env.CLOUDDRIVE_TEST_PASSWORD;

(async () => {
    const browser = await chromium.launch({ headless: true });
    const context = await browser.newContext({ viewport: { width: 1400, height: 900 } });
    const page = await context.newPage();

    // Capture all console logs
    const logs = [];
    page.on('console', msg => {
        logs.push('[' + msg.type() + '] ' + msg.text());
    });
    page.on('pageerror', err => {
        logs.push('[PAGE_ERROR] ' + err.message);
    });

    // Step 1: Login properly
    console.log('Step 1: Logging in...');
    await page.goto(CLOUDFRONT_URL, { waitUntil: 'networkidle' });

    // Check if we need to login
    const loginButton = await page.$('#login-button');
    if (loginButton && await loginButton.isVisible()) {
        console.log('Clicking login button...');
        await page.click('#login-button');

        // Wait for Cognito hosted UI
        await page.waitForURL(/.*amazoncognito\.com.*/, { timeout: 10000 });
        console.log('On Cognito login page');

        // Fill credentials using placeholders (Cognito has duplicate forms)
        await page.getByPlaceholder('name@host.com').last().fill(EMAIL);
        await page.getByPlaceholder('Password').last().fill(PASSWORD);
        await page.getByPlaceholder('Password').last().press('Enter');

        // Wait for redirect back to CloudDrive
        console.log('Waiting for auth callback...');
        await page.waitForURL(CLOUDFRONT_URL + '/**', { timeout: 15000 });
        await page.waitForTimeout(3000);
        console.log('Login complete');
    } else {
        console.log('Already logged in');
    }

    // Step 2: Navigate to v2 editor
    const editorUrl = CLOUDFRONT_URL + '/transcript-editor-v2.html?sessionId=20251122-190205-upload-5b4c464c39d2';
    console.log('Step 2: Loading editor:', editorUrl);
    await page.goto(editorUrl);

    // Wait for page to process
    console.log('Waiting for page to process (30s)...');
    await page.waitForTimeout(30000);

    // Report results
    console.log('\n=== PROGRESS LOGS ===');
    logs.filter(l => l.includes('PROGRESS')).forEach(l => console.log(l));

    console.log('\n=== ERROR/WARNING LOGS ===');
    logs.filter(l => l.includes('error') || l.includes('Error') || l.includes('PAGE_ERROR') || l.includes('warn')).forEach(l => console.log(l));

    console.log('\n=== LAST 60 LOGS ===');
    logs.slice(-60).forEach(l => console.log(l));

    // Check page state
    const pageState = await page.evaluate(() => {
        return {
            loadingVisible: document.getElementById('loading')?.style.display !== 'none',
            loadingText: document.getElementById('loading')?.innerText?.substring(0, 100),
            mainContainerVisible: document.getElementById('main-container')?.style.display !== 'none',
            paragraphCount: document.querySelectorAll('.paragraph').length,
            errorMessage: document.querySelector('.error-message')?.innerText,
            bodySnippet: document.body.innerText.substring(0, 300)
        };
    });
    console.log('\n=== PAGE STATE ===');
    console.log(JSON.stringify(pageState, null, 2));

    await page.screenshot({ path: 'v2-debug.png', fullPage: false });
    console.log('\nScreenshot: v2-debug.png');

    await browser.close();
})();
