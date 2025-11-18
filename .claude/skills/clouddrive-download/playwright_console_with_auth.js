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
    // Step 1: Navigate to login page
    console.log('Step 1: Navigating to login page...');
    await page.goto('https://d2l28rla2hk7np.cloudfront.net/transcript-editor-v2.html', {
      waitUntil: 'networkidle',
      timeout: 30000
    });

    // Step 2: Wait for login form and fill it in
    console.log('Step 2: Waiting for login form...');
    await page.waitForSelector('#loginEmail', { timeout: 10000 });

    console.log('Step 3: Entering credentials...');
    await page.fill('#loginEmail', 'david.bryan.mar@gmail.com');
    await page.fill('#loginPassword', 'Testtesttest1');

    console.log('Step 4: Clicking login button...');
    await page.click('button:has-text("Login")');

    // Step 5: Wait for authentication to complete
    console.log('Step 5: Waiting for authentication to complete...');
    await page.waitForTimeout(3000);

    // Check if we're authenticated by looking for the transcript editor UI
    const isAuthenticated = await page.evaluate(() => {
      return document.querySelector('#login-section')?.style.display === 'none';
    });

    if (!isAuthenticated) {
      console.log('WARNING: Authentication may have failed, but continuing...');
    } else {
      console.log('Authentication successful!');
    }

    // Step 6: Wait for preprocessor to complete (extended wait)
    console.log('Step 6: Waiting for preprocessor to complete (15 seconds)...');
    await page.waitForTimeout(15000);

    // Step 7: Take screenshots
    console.log('Step 7: Capturing screenshots...');
    await page.screenshot({
      path: '/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/.claude/skills/clouddrive-download/transcript-editor-authenticated.png',
      fullPage: true
    });

    // Also take a viewport screenshot
    await page.screenshot({
      path: '/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/.claude/skills/clouddrive-download/transcript-editor-viewport.png',
      fullPage: false
    });

    console.log('Screenshots saved.');

    // Step 8: Get page state information
    const pageInfo = await page.evaluate(() => {
      return {
        url: window.location.href,
        title: document.title,
        hasTranscriptData: typeof window.transcriptData !== 'undefined',
        hasPreprocessor: typeof window.TranscriptPreprocessor !== 'undefined',
        hasPreprocessorBoundary: typeof window.TranscriptPreprocessorBoundary !== 'undefined',
        loginSectionDisplay: document.querySelector('#login-section')?.style.display,
        editorSectionDisplay: document.querySelector('#editor-section')?.style.display,
        bodyClasses: document.body.className,
        localStorageKeys: Object.keys(localStorage)
      };
    });

    console.log('Page State:', JSON.stringify(pageInfo, null, 2));

    // Save console output to JSON file
    const outputPath = '/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/.claude/skills/clouddrive-download/console-output-authenticated.json';
    fs.writeFileSync(outputPath, JSON.stringify({
      pageInfo,
      consoleMessages
    }, null, 2));

    console.log(`Console output saved to ${outputPath}`);
    console.log(`Total console messages captured: ${consoleMessages.length}`);

    // Save a human-readable text version
    const textOutputPath = '/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/.claude/skills/clouddrive-download/console-output-authenticated.txt';
    const textOutput = [
      '=== PAGE INFORMATION ===',
      JSON.stringify(pageInfo, null, 2),
      '',
      '=== CONSOLE OUTPUT (CHRONOLOGICAL) ===',
      '',
      ...consoleMessages.map(msg =>
        `[${msg.timestamp}] [${msg.type.toUpperCase()}] ${msg.text}\n  Location: ${msg.location}${msg.stack ? `\n  Stack: ${msg.stack}` : ''}`
      )
    ].join('\n');

    fs.writeFileSync(textOutputPath, textOutput);
    console.log(`Human-readable console output saved to ${textOutputPath}`);

  } catch (error) {
    console.error('Error during page navigation or processing:', error);

    // Still try to take a screenshot on error
    try {
      await page.screenshot({
        path: '/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/.claude/skills/clouddrive-download/transcript-editor-error.png',
        fullPage: true
      });
    } catch (screenshotError) {
      console.error('Failed to take error screenshot:', screenshotError);
    }
  } finally {
    await browser.close();
    console.log('Browser closed.');
  }
})();
