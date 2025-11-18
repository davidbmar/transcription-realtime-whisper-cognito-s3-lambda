#!/usr/bin/env node

/**
 * Verify Boundary Deduplication in Transcript Editor V2
 *
 * This script:
 * 1. Logs into CloudDrive via Cognito
 * 2. Navigates to transcript editor v2
 * 3. Captures all console output showing boundary deduplication
 * 4. Verifies TranscriptPreprocessorBoundary is being used
 * 5. Reports deduplication statistics
 */

const { chromium } = require('playwright');
const fs = require('fs');

const CLOUDFRONT_URL = process.env.COGNITO_CLOUDFRONT_URL || 'https://d2l28rla2hk7np.cloudfront.net';
const EMAIL = process.env.CLOUDDRIVE_TEST_EMAIL;
const PASSWORD = process.env.CLOUDDRIVE_TEST_PASSWORD;

async function verifyBoundaryDeduplication() {
    console.log('🧪 Verifying Boundary Deduplication in Transcript Editor V2...\n');
    console.log(`📍 CloudFront URL: ${CLOUDFRONT_URL}`);
    console.log(`📧 Test Email: ${EMAIL}\n`);

    if (!EMAIL || !PASSWORD) {
        console.error('❌ CLOUDDRIVE_TEST_EMAIL or CLOUDDRIVE_TEST_PASSWORD not set in .env');
        process.exit(1);
    }

    const browser = await chromium.launch({
        headless: true,
        slowMo: 50
    });

    // Array to store all console messages in chronological order
    const consoleMessages = [];

    try {
        const context = await browser.newContext({
            viewport: { width: 1400, height: 900 },
            ignoreHTTPSErrors: true
        });

        const page = await context.newPage();

        // Listen to all console messages
        page.on('console', msg => {
            const timestamp = new Date().toISOString();
            const type = msg.type();
            const text = msg.text();

            consoleMessages.push({
                timestamp,
                type,
                text
            });

            // Log important messages to stdout
            if (text.includes('Preprocessor') ||
                text.includes('[Boundary') ||
                text.includes('chunk') ||
                text.includes('Dedup') ||
                text.includes('Previous chunk') ||
                text.includes('Current chunk')) {
                console.log(`[${type.toUpperCase()}] ${text}`);
            }
        });

        // Listen to page errors
        page.on('pageerror', error => {
            const timestamp = new Date().toISOString();
            consoleMessages.push({
                timestamp,
                type: 'pageerror',
                text: error.message
            });
            console.log(`[PAGEERROR] ${error.message}`);
        });

        // ====================================================================
        // STEP 1: Login via Cognito
        // ====================================================================
        console.log('📝 Step 1: Logging in via Cognito...\n');
        await page.goto(`${CLOUDFRONT_URL}/index.html`, { waitUntil: 'networkidle' });

        // Check if already logged in
        const isLoggedIn = await page.evaluate(() => {
            return !!localStorage.getItem('id_token');
        });

        if (isLoggedIn) {
            console.log('✅ Already logged in (token found in localStorage)\n');
        } else {
            console.log('🔐 Not logged in, initiating Cognito login...');

            // Click login button
            await page.click('#login-button');

            // Wait for Cognito hosted UI
            await page.waitForURL(/.*amazoncognito\.com.*/, { timeout: 10000 });
            console.log('🔑 Cognito login page loaded');

            // Fill in credentials (Cognito has duplicate forms, use .last())
            await page.getByPlaceholder('name@host.com').last().fill(EMAIL);
            await page.getByPlaceholder('Password').last().fill(PASSWORD);
            console.log('📝 Credentials entered');

            // Submit login
            await page.getByPlaceholder('Password').last().press('Enter');
            console.log('🚀 Submitting login...');

            // Wait for redirect back to CloudDrive
            await page.waitForURL(/.*cloudfront\.net.*/, { timeout: 15000 });
            console.log('✅ Login successful!\n');
        }

        // ====================================================================
        // STEP 2: Navigate to Transcript Editor V2
        // ====================================================================
        console.log('📝 Step 2: Navigating to Transcript Editor V2...\n');
        await page.goto(`${CLOUDFRONT_URL}/transcript-editor-v2.html`);

        // Wait a few seconds for page to initialize
        console.log('⏳ Waiting for page to load and preprocessor to initialize...\n');
        await page.waitForTimeout(5000);

        // ====================================================================
        // STEP 3: Wait for transcript processing
        // ====================================================================
        console.log('📝 Step 3: Waiting for transcript to load and process (15 seconds)...\n');
        await page.waitForTimeout(15000);

        // ====================================================================
        // STEP 4: Take screenshot
        // ====================================================================
        console.log('📝 Step 4: Taking screenshot...\n');
        await page.screenshot({
            path: '/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/boundary-dedup-verification.png',
            fullPage: true
        });

        // ====================================================================
        // STEP 5: Analyze console output
        // ====================================================================
        console.log('\n═══════════════════════════════════════');
        console.log('📊 ANALYSIS OF CONSOLE OUTPUT');
        console.log('═══════════════════════════════════════\n');

        const boundaryInitMessages = consoleMessages.filter(m => m.text.includes('Initializing TranscriptPreprocessor (boundary mode)'));
        const preprocessorTypeMessages = consoleMessages.filter(m => m.text.includes('Preprocessor initialized:'));
        const processingChunksMessages = consoleMessages.filter(m => m.text.includes('[Boundary Preprocessor] Processing'));
        const chunkOrderMessages = consoleMessages.filter(m => m.text.includes('[Boundary Preprocessor] Chunk order:'));
        const dedupMessages = consoleMessages.filter(m => m.text.includes('[Boundary Dedup]'));
        const previousChunkMessages = consoleMessages.filter(m => m.text.includes('Previous chunk ends with:'));
        const currentChunkMessages = consoleMessages.filter(m => m.text.includes('Current chunk starts with:'));
        const errorMessages = consoleMessages.filter(m => m.type === 'error' || m.type === 'pageerror');
        const warningMessages = consoleMessages.filter(m => m.type === 'warning');

        console.log(`Total console messages: ${consoleMessages.length}`);
        console.log(`Boundary mode initialization: ${boundaryInitMessages.length}`);
        console.log(`Preprocessor type messages: ${preprocessorTypeMessages.length}`);
        console.log(`Processing chunks messages: ${processingChunksMessages.length}`);
        console.log(`Chunk order messages: ${chunkOrderMessages.length}`);
        console.log(`Boundary deduplication messages: ${dedupMessages.length}`);
        console.log(`Previous chunk end messages: ${previousChunkMessages.length}`);
        console.log(`Current chunk start messages: ${currentChunkMessages.length}`);
        console.log(`Error messages: ${errorMessages.length}`);
        console.log(`Warning messages: ${warningMessages.length}\n`);

        // Show preprocessor type
        if (preprocessorTypeMessages.length > 0) {
            console.log('═══════════════════════════════════════');
            console.log('🔍 PREPROCESSOR TYPE');
            console.log('═══════════════════════════════════════');
            preprocessorTypeMessages.forEach(m => {
                console.log(`  ${m.text}`);
            });
            console.log();
        }

        // Show deduplication details
        if (dedupMessages.length > 0) {
            console.log('═══════════════════════════════════════');
            console.log('🔄 BOUNDARY DEDUPLICATION DETAILS');
            console.log('═══════════════════════════════════════');
            dedupMessages.forEach(m => {
                console.log(`  ${m.text}`);
            });
            console.log();
        }

        // Show chunk boundaries
        if (previousChunkMessages.length > 0 || currentChunkMessages.length > 0) {
            console.log('═══════════════════════════════════════');
            console.log('📦 CHUNK BOUNDARY DETAILS');
            console.log('═══════════════════════════════════════');
            previousChunkMessages.forEach(m => {
                console.log(`  ${m.text}`);
            });
            currentChunkMessages.forEach(m => {
                console.log(`  ${m.text}`);
            });
            console.log();
        }

        // Show errors
        if (errorMessages.length > 0) {
            console.log('═══════════════════════════════════════');
            console.log('❌ ERRORS');
            console.log('═══════════════════════════════════════');
            errorMessages.forEach(m => {
                console.log(`  ${m.text}`);
            });
            console.log();
        }

        // Show warnings
        if (warningMessages.length > 0) {
            console.log('═══════════════════════════════════════');
            console.log('⚠️  WARNINGS');
            console.log('═══════════════════════════════════════');
            warningMessages.forEach(m => {
                console.log(`  ${m.text}`);
            });
            console.log();
        }

        // ====================================================================
        // STEP 6: Save full report
        // ====================================================================
        const outputReport = {
            totalMessages: consoleMessages.length,
            timestamp: new Date().toISOString(),
            url: `${CLOUDFRONT_URL}/transcript-editor-v2.html`,
            verification: {
                boundaryModeInitialized: boundaryInitMessages.length > 0,
                preprocessorType: preprocessorTypeMessages.map(m => m.text),
                isBoundaryPreprocessor: preprocessorTypeMessages.some(m => m.text.includes('TranscriptPreprocessorBoundary')),
                boundaryDedupCount: dedupMessages.length,
                dedupDetails: dedupMessages.map(m => m.text),
                chunkBoundaries: {
                    previousChunkEnds: previousChunkMessages.map(m => m.text),
                    currentChunkStarts: currentChunkMessages.map(m => m.text)
                },
                errors: errorMessages.map(m => m.text),
                warnings: warningMessages.map(m => m.text)
            },
            allMessages: consoleMessages
        };

        fs.writeFileSync(
            '/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/boundary-dedup-report.json',
            JSON.stringify(outputReport, null, 2)
        );

        console.log('═══════════════════════════════════════');
        console.log('📁 FILES SAVED');
        console.log('═══════════════════════════════════════');
        console.log('  ✅ boundary-dedup-report.json');
        console.log('  ✅ boundary-dedup-verification.png\n');

        // ====================================================================
        // STEP 7: Final verification
        // ====================================================================
        console.log('═══════════════════════════════════════');
        console.log('✅ VERIFICATION RESULTS');
        console.log('═══════════════════════════════════════\n');

        const isBoundaryPreprocessor = preprocessorTypeMessages.some(m => m.text.includes('TranscriptPreprocessorBoundary'));
        const hasDedupActivity = dedupMessages.length > 0;

        if (isBoundaryPreprocessor && hasDedupActivity) {
            console.log('✅ TranscriptPreprocessorBoundary is being used');
            console.log(`✅ Boundary deduplication is active (${dedupMessages.length} deduplication messages)`);
            console.log('\n🎉 SUCCESS: Boundary deduplication is working as expected!\n');
            return 0;
        } else if (isBoundaryPreprocessor && !hasDedupActivity) {
            console.log('✅ TranscriptPreprocessorBoundary is being used');
            console.log('⚠️  No boundary deduplication messages found');
            console.log('   (This may be normal if there are no overlaps to deduplicate)\n');
            return 0;
        } else if (boundaryInitMessages.length > 0) {
            console.log('⚠️  Preprocessor initialized but type unclear');
            console.log(`   Found: ${preprocessorTypeMessages.map(m => m.text).join(', ')}\n`);
            return 1;
        } else {
            console.log('❌ No preprocessor activity detected');
            console.log('   This may indicate the page did not load transcripts\n');
            return 2;
        }

    } catch (error) {
        console.error('\n❌ Test failed:', error.message);
        console.error(error.stack);
        return 3;
    } finally {
        console.log('⏳ Closing browser...\n');
        await browser.close();
    }
}

// Run the verification
verifyBoundaryDeduplication()
    .then(exitCode => process.exit(exitCode))
    .catch(error => {
        console.error('Fatal error:', error);
        process.exit(4);
    });
