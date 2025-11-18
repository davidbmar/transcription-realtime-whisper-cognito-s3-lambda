const { chromium } = require('playwright');
const fs = require('fs');

(async () => {
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();

  // Array to store all console messages in chronological order
  const consoleMessages = [];

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

    console.log(`[${timestamp}] [${type.toUpperCase()}] ${text}`);
  });

  // Listen to page errors
  page.on('pageerror', error => {
    const timestamp = new Date().toISOString();
    consoleMessages.push({
      timestamp,
      type: 'pageerror',
      text: error.message
    });
    console.log(`[${timestamp}] [PAGEERROR] ${error.message}`);
  });

  console.log('\n=== STEP 1: Navigating to login page ===');
  await page.goto('https://d2l28rla2hk7np.cloudfront.net/transcript-editor-v2.html');
  await page.waitForTimeout(2000);

  console.log('\n=== STEP 2: Checking if login form is present ===');
  const loginSectionVisible = await page.isVisible('#login-section');

  if (loginSectionVisible) {
    console.log('Login section detected. Attempting to log in...');

    // Fill in credentials
    await page.fill('input[type="email"]', 'david.bryan.mar@gmail.com');
    await page.fill('input[type="password"]', 'Testtesttest1');

    console.log('Credentials entered, clicking login button...');
    await page.click('button:has-text("Login")');

    console.log('Waiting for authentication to complete...');
    await page.waitForTimeout(5000);

    // Check if we're now authenticated
    const appSectionVisible = await page.isVisible('#app-section');
    if (appSectionVisible) {
      console.log('✓ Successfully authenticated!');
    } else {
      console.log('✗ Authentication may have failed');
    }
  } else {
    console.log('Already authenticated or login section not visible');
  }

  console.log('\n=== STEP 3: Checking for available transcripts ===');
  await page.waitForTimeout(2000);

  // Try to find and click on a transcript
  const transcriptLinks = await page.$$('a[href*="transcript-editor"]');
  console.log(`Found ${transcriptLinks.length} transcript links`);

  if (transcriptLinks.length > 0) {
    console.log('Clicking on first transcript to load it...');
    await transcriptLinks[0].click();

    console.log('Waiting for transcript to load and preprocessor to run (15 seconds)...');
    await page.waitForTimeout(15000);
  } else {
    console.log('No transcripts found. Checking page state...');
    await page.waitForTimeout(5000);
  }

  console.log('\n=== STEP 4: Taking screenshot ===');
  await page.screenshot({
    path: '/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/transcript-editor-authenticated-screenshot.png',
    fullPage: true
  });

  console.log('\n=== CONSOLE OUTPUT SUMMARY ===\n');
  console.log(`Total console messages captured: ${consoleMessages.length}\n`);

  // Analyze the console output
  const boundaryInitMessages = consoleMessages.filter(m => m.text.includes('Initializing TranscriptPreprocessor (boundary mode)'));
  const preprocessorTypeMessages = consoleMessages.filter(m => m.text.includes('Preprocessor initialized:'));
  const processingChunksMessages = consoleMessages.filter(m => m.text.includes('[Boundary Preprocessor] Processing'));
  const chunkOrderMessages = consoleMessages.filter(m => m.text.includes('[Boundary Preprocessor] Chunk order:'));
  const dedupMessages = consoleMessages.filter(m => m.text.includes('[Boundary Dedup]'));
  const previousChunkMessages = consoleMessages.filter(m => m.text.includes('Previous chunk ends with:'));
  const currentChunkMessages = consoleMessages.filter(m => m.text.includes('Current chunk starts with:'));
  const errorMessages = consoleMessages.filter(m => m.type === 'error' || m.type === 'pageerror');
  const warningMessages = consoleMessages.filter(m => m.type === 'warning');

  console.log('=== KEY FINDINGS ===\n');
  console.log(`Boundary mode initialization messages: ${boundaryInitMessages.length}`);
  console.log(`Preprocessor type messages: ${preprocessorTypeMessages.length}`);
  console.log(`Processing chunks messages: ${processingChunksMessages.length}`);
  console.log(`Chunk order messages: ${chunkOrderMessages.length}`);
  console.log(`Boundary deduplication messages: ${dedupMessages.length}`);
  console.log(`Previous chunk end messages: ${previousChunkMessages.length}`);
  console.log(`Current chunk start messages: ${currentChunkMessages.length}`);
  console.log(`Error messages: ${errorMessages.length}`);
  console.log(`Warning messages: ${warningMessages.length}\n`);

  if (preprocessorTypeMessages.length > 0) {
    console.log('=== PREPROCESSOR TYPE ===');
    preprocessorTypeMessages.forEach(m => {
      console.log(`  ${m.text}`);
    });
    console.log();
  }

  if (dedupMessages.length > 0) {
    console.log('=== BOUNDARY DEDUPLICATION DETAILS ===');
    dedupMessages.forEach(m => {
      console.log(`  ${m.text}`);
    });
    console.log();
  }

  if (previousChunkMessages.length > 0) {
    console.log('=== PREVIOUS CHUNK ENDINGS ===');
    previousChunkMessages.forEach(m => {
      console.log(`  ${m.text}`);
    });
    console.log();
  }

  if (currentChunkMessages.length > 0) {
    console.log('=== CURRENT CHUNK BEGINNINGS ===');
    currentChunkMessages.forEach(m => {
      console.log(`  ${m.text}`);
    });
    console.log();
  }

  if (errorMessages.length > 0) {
    console.log('=== ERRORS ===');
    errorMessages.forEach(m => {
      console.log(`  ${m.text}`);
    });
    console.log();
  }

  if (warningMessages.length > 0) {
    console.log('=== WARNINGS ===');
    warningMessages.forEach(m => {
      console.log(`  ${m.text}`);
    });
    console.log();
  }

  // Save full console output to a file
  const outputReport = {
    totalMessages: consoleMessages.length,
    timestamp: new Date().toISOString(),
    url: 'https://d2l28rla2hk7np.cloudfront.net/transcript-editor-v2.html',
    analysis: {
      boundaryModeInit: boundaryInitMessages.length,
      preprocessorType: preprocessorTypeMessages.map(m => m.text),
      processingChunks: processingChunksMessages.length,
      chunkOrder: chunkOrderMessages.length,
      boundaryDedups: dedupMessages.length,
      dedupDetails: dedupMessages.map(m => m.text),
      previousChunkEnds: previousChunkMessages.length,
      previousChunkEndDetails: previousChunkMessages.map(m => m.text),
      currentChunkStarts: currentChunkMessages.length,
      currentChunkStartDetails: currentChunkMessages.map(m => m.text),
      errors: errorMessages.length,
      errorDetails: errorMessages.map(m => m.text),
      warnings: warningMessages.length,
      warningDetails: warningMessages.map(m => m.text)
    },
    allMessages: consoleMessages
  };

  fs.writeFileSync(
    '/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/console-output-authenticated.json',
    JSON.stringify(outputReport, null, 2)
  );

  console.log('Full console output saved to console-output-authenticated.json');
  console.log('Screenshot saved to transcript-editor-authenticated-screenshot.png');

  await browser.close();

  console.log('\n=== VERIFICATION COMPLETE ===');

  // Exit with appropriate code
  if (dedupMessages.length > 0 && preprocessorTypeMessages.some(m => m.text.includes('TranscriptPreprocessorBoundary'))) {
    console.log('\n✓✓✓ SUCCESS: Boundary deduplication is working! ✓✓✓');
    process.exit(0);
  } else if (boundaryInitMessages.length > 0) {
    console.log('\n⚠ WARNING: Preprocessor initialized but no deduplication detected');
    process.exit(1);
  } else {
    console.log('\n✗ ERROR: No preprocessor activity detected');
    process.exit(2);
  }
})();
