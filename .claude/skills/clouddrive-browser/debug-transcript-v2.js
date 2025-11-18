#!/usr/bin/env node

/**
 * Debug script for Transcript Editor V2
 * Captures console logs and errors
 */

const { chromium } = require('playwright');

const CLOUDFRONT_URL = process.env.COGNITO_CLOUDFRONT_URL || 'https://d2l28rla2hk7np.cloudfront.net';
const SCREENSHOT_DIR = process.env.PWD + '/browser-screenshots';

async function debugTranscriptV2() {
    console.log('🔍 Debugging Transcript Editor V2...\n');
    console.log(`📍 CloudFront URL: ${CLOUDFRONT_URL}\n`);

    const browser = await chromium.launch({
        headless: true
    });

    try {
        const context = await browser.newContext({
            viewport: { width: 1400, height: 900 },
            ignoreHTTPSErrors: true
        });

        const page = await context.newPage();

        // Capture all console messages
        page.on('console', msg => {
            const type = msg.type();
            const text = msg.text();
            const location = msg.location();

            console.log(`[CONSOLE ${type.toUpperCase()}] ${text}`);
            if (location.url) {
                console.log(`  at ${location.url}:${location.lineNumber}:${location.columnNumber}`);
            }
        });

        // Capture page errors
        page.on('pageerror', error => {
            console.log(`[PAGE ERROR] ${error.message}`);
            console.log(error.stack);
        });

        // Capture failed requests
        page.on('requestfailed', request => {
            console.log(`[REQUEST FAILED] ${request.url()}`);
            console.log(`  Failure: ${request.failure().errorText}`);
        });

        // Navigate to the page
        console.log('📝 Loading transcript-editor-v2.html...\n');
        await page.goto(`${CLOUDFRONT_URL}/transcript-editor-v2.html`);

        // Wait a bit to see what happens
        await page.waitForTimeout(10000);

        // Check what's visible
        const pageState = await page.evaluate(() => {
            return {
                loadingVisible: document.getElementById('loading')?.style.display !== 'none',
                mainContainerVisible: document.getElementById('main-container')?.style.display !== 'none',
                errorVisible: document.getElementById('error')?.style.display !== 'none',
                hasAuthToken: !!localStorage.getItem('id_token'),
                preprocessorLoaded: typeof window.TranscriptPreprocessor !== 'undefined',
                pluginManagerLoaded: typeof window.TranscriptPluginManager !== 'undefined',
                currentURL: window.location.href,
                documentReady: document.readyState
            };
        });

        console.log('\n📊 Page State:');
        console.log(JSON.stringify(pageState, null, 2));

        // Take screenshot
        await page.screenshot({ path: `${SCREENSHOT_DIR}/transcript-v2-debug.png`, fullPage: true });
        console.log(`\n📸 Screenshot saved to: ${SCREENSHOT_DIR}/transcript-v2-debug.png`);

        // Get any error messages
        const errorText = await page.evaluate(() => {
            const errorDiv = document.getElementById('error');
            return errorDiv?.textContent || null;
        });

        if (errorText) {
            console.log(`\n❌ Error Message: ${errorText}`);
        }

        // Wait for user to check
        console.log('\n⏳ Waiting 30 seconds for further observation...');
        await page.waitForTimeout(30000);

    } catch (error) {
        console.error('\n❌ Debug failed:', error.message);
        console.error(error.stack);
    } finally {
        await browser.close();
    }
}

debugTranscriptV2().catch(console.error);
