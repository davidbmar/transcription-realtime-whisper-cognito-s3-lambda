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

  // Listen to console events before navigation
  console.log('Navigating to transcript editor page...');

  try {
    // Navigate to the page
    await page.goto('https://d2l28rla2hk7np.cloudfront.net/transcript-editor-v2.html', {
      waitUntil: 'networkidle',
      timeout: 30000
    });

    console.log('Page loaded, waiting for preprocessor to complete...');

    // Wait for at least 10 seconds to allow all preprocessing to complete
    await page.waitForTimeout(10000);

    console.log('Wait complete, capturing screenshot...');

    // Take a screenshot
    await page.screenshot({
      path: '/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/.claude/skills/clouddrive-download/transcript-editor-screenshot.png',
      fullPage: true
    });

    console.log('Screenshot saved.');

    // Save console output to JSON file
    const outputPath = '/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/.claude/skills/clouddrive-download/console-output.json';
    fs.writeFileSync(outputPath, JSON.stringify(consoleMessages, null, 2));

    console.log(`Console output saved to ${outputPath}`);
    console.log(`Total console messages captured: ${consoleMessages.length}`);

    // Also save a human-readable text version
    const textOutputPath = '/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/.claude/skills/clouddrive-download/console-output.txt';
    const textOutput = consoleMessages.map(msg =>
      `[${msg.timestamp}] [${msg.type.toUpperCase()}] ${msg.text}\n${msg.location ? `  Location: ${msg.location}` : ''}${msg.stack ? `\n  Stack: ${msg.stack}` : ''}`
    ).join('\n\n');

    fs.writeFileSync(textOutputPath, textOutput);
    console.log(`Human-readable console output saved to ${textOutputPath}`);

  } catch (error) {
    console.error('Error during page navigation or processing:', error);

    // Still try to take a screenshot on error
    try {
      await page.screenshot({
        path: '/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/.claude/skills/clouddrive-download/transcript-editor-screenshot-error.png',
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
