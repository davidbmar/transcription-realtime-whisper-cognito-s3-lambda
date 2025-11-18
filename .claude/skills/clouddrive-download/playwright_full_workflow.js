const { chromium } = require('playwright');
const fs = require('fs');

(async () => {
  const browser = await chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox']
  });

  const context = await browser.newContext({
    viewport: { width: 1920, height: 1080 }
  });

  const page = await context.newPage();

  // Array to store all console messages
  const consoleMessages = [];

  // Listen to all console events
  page.on('console', msg => {
    const timestamp = new Date().toISOString();
    const type = msg.type();
    const text = msg.text();
    const location = msg.location();

    const logEntry = {
      timestamp,
      type,
      text,
      location: `${location.url}:${location.lineNumber}:${location.columnNumber}`
    };

    consoleMessages.push(logEntry);

    // Also print to stdout in real-time
    console.log(`[${timestamp}] [${type.toUpperCase()}] ${text}`);
  });

  // Listen to page errors
  page.on('pageerror', error => {
    const timestamp = new Date().toISOString();
    const logEntry = {
      timestamp,
      type: 'pageerror',
      text: error.message,
      stack: error.stack
    };

    consoleMessages.push(logEntry);
    console.log(`[${timestamp}] [PAGE ERROR] ${error.message}`);
  });

  try {
    // ============ STEP 1: AUTHENTICATE ============
    console.log('\n========== STEP 1: AUTHENTICATE ==========');
    await page.goto('https://d2l28rla2hk7np.cloudfront.net/', {
      waitUntil: 'networkidle',
      timeout: 30000
    });

    console.log('Clicking login button...');
    await page.click('#login-button');

    console.log('Waiting for Cognito login page...');
    await page.waitForURL(/.*amazoncognito\.com.*/, { timeout: 15000 });

    console.log('Waiting for login form...');
    await page.waitForTimeout(2000); // Wait for page to settle

    console.log('Filling in credentials...');
    // Use locator with force option to bypass visibility checks
    await page.locator('#signInFormUsername').last().fill('david.bryan.mar@gmail.com');
    await page.locator('#signInFormPassword').last().fill('Testtesttest1');

    console.log('Submitting login form...');
    await page.locator('input[name="signInSubmitButton"]').last().click();

    console.log('Waiting for redirect back to CloudDrive...');
    await page.waitForURL(/.*cloudfront\.net.*/, { timeout: 15000 });

    // Wait for authentication to complete
    await page.waitForTimeout(3000);

    console.log('Authentication complete!');

    // Extract and save tokens
    const tokens = await page.evaluate(() => {
      return {
        id_token: localStorage.getItem('id_token'),
        access_token: localStorage.getItem('access_token'),
        has_token: !!localStorage.getItem('id_token')
      };
    });

    if (!tokens.has_token) {
      throw new Error('Authentication failed - no token found');
    }

    console.log('Tokens obtained successfully');

    // ============ STEP 2: NAVIGATE TO TRANSCRIPT EDITOR ============
    console.log('\n========== STEP 2: NAVIGATE TO TRANSCRIPT EDITOR ==========');

    // Clear console messages from authentication phase
    consoleMessages.length = 0;

    await page.goto('https://d2l28rla2hk7np.cloudfront.net/transcript-editor-v2.html', {
      waitUntil: 'networkidle',
      timeout: 30000
    });

    console.log('Transcript editor page loaded');

    // ============ STEP 3: WAIT FOR PREPROCESSOR ============
    console.log('\n========== STEP 3: WAIT FOR PREPROCESSOR ==========');
    console.log('Waiting 30 seconds for preprocessor to complete all async operations...');
    await page.waitForTimeout(30000);

    // ============ STEP 4: GATHER PAGE STATE ============
    console.log('\n========== STEP 4: GATHER PAGE STATE ==========');
    const pageInfo = await page.evaluate(() => {
      return {
        url: window.location.href,
        title: document.title,
        hasTranscriptData: typeof window.transcriptData !== 'undefined',
        transcriptDataLength: window.transcriptData ? window.transcriptData.length : 0,
        hasPreprocessor: typeof window.TranscriptPreprocessor !== 'undefined',
        hasPreprocessorBoundary: typeof window.TranscriptPreprocessorBoundary !== 'undefined',
        hasPreprocessorSimple: typeof window.TranscriptPreprocessorSimple !== 'undefined',
        hasPluginManager: typeof window.TranscriptPluginManager !== 'undefined',
        loginSectionDisplay: document.querySelector('#login-section')?.style.display,
        editorSectionDisplay: document.querySelector('#editor-section')?.style.display,
        bodyClasses: document.body.className,
        localStorageKeys: Object.keys(localStorage),
        // Check if preprocessor was instantiated
        preprocessorInstance: typeof window.preprocessor !== 'undefined',
        // Try to get session info
        sessionInfo: localStorage.getItem('currentSessionId')
      };
    });

    console.log('Page State:', JSON.stringify(pageInfo, null, 2));

    // ============ STEP 5: TAKE SCREENSHOTS ============
    console.log('\n========== STEP 5: TAKE SCREENSHOTS ==========');
    await page.screenshot({
      path: '/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/.claude/skills/clouddrive-download/transcript-editor-final.png',
      fullPage: true
    });

    await page.screenshot({
      path: '/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/.claude/skills/clouddrive-download/transcript-editor-viewport.png',
      fullPage: false
    });

    console.log('Screenshots saved');

    // ============ STEP 6: SAVE CONSOLE OUTPUT ============
    console.log('\n========== STEP 6: SAVE CONSOLE OUTPUT ==========');

    // Save JSON output
    const outputData = {
      metadata: {
        timestamp: new Date().toISOString(),
        totalMessages: consoleMessages.length,
        authenticated: tokens.has_token
      },
      pageInfo,
      consoleMessages
    };

    const jsonPath = '/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/.claude/skills/clouddrive-download/console-output-final.json';
    fs.writeFileSync(jsonPath, JSON.stringify(outputData, null, 2));

    // Save text output
    const textOutput = [
      '=== METADATA ===',
      `Timestamp: ${outputData.metadata.timestamp}`,
      `Total Messages: ${outputData.metadata.totalMessages}`,
      `Authenticated: ${outputData.metadata.authenticated}`,
      '',
      '=== PAGE INFORMATION ===',
      JSON.stringify(pageInfo, null, 2),
      '',
      '=== CONSOLE OUTPUT (CHRONOLOGICAL) ===',
      '',
      ...consoleMessages.map(msg =>
        `[${msg.timestamp}] [${msg.type.toUpperCase()}] ${msg.text}\n  Location: ${msg.location}${msg.stack ? `\n  Stack: ${msg.stack}` : ''}`
      )
    ].join('\n');

    const textPath = '/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/.claude/skills/clouddrive-download/console-output-final.txt';
    fs.writeFileSync(textPath, textOutput);

    console.log(`Console output saved to:\n  - ${jsonPath}\n  - ${textPath}`);
    console.log(`Total console messages captured: ${consoleMessages.length}`);

    // Print summary of interesting console messages
    console.log('\n========== CONSOLE MESSAGE SUMMARY ==========');
    const preprocessorMessages = consoleMessages.filter(m =>
      m.text.includes('Preprocessor') ||
      m.text.includes('Boundary') ||
      m.text.includes('Loading latest session') ||
      m.text.includes('Processing') ||
      m.text.includes('Dedup')
    );

    if (preprocessorMessages.length > 0) {
      console.log('Preprocessor-related messages found:');
      preprocessorMessages.forEach(msg => {
        console.log(`  - [${msg.type}] ${msg.text}`);
      });
    } else {
      console.log('No preprocessor-related messages found');
    }

  } catch (error) {
    console.error('\n========== ERROR ==========');
    console.error('Error during execution:', error.message);
    console.error(error.stack);

    // Take error screenshot
    try {
      await page.screenshot({
        path: '/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/.claude/skills/clouddrive-download/error-screenshot.png',
        fullPage: true
      });
      console.log('Error screenshot saved');
    } catch (screenshotError) {
      console.error('Failed to take error screenshot:', screenshotError.message);
    }
  } finally {
    await browser.close();
    console.log('\n========== BROWSER CLOSED ==========');
  }
})();
