const { chromium } = require('playwright');

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

  console.log('Navigating to transcript editor page...');
  await page.goto('https://d2l28rla2hk7np.cloudfront.net/transcript-editor-v2.html');

  console.log('Waiting for page to fully load and preprocessor logging (15 seconds)...');
  await page.waitForTimeout(15000);

  console.log('Taking screenshot...');
  await page.screenshot({ path: '/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/transcript-editor-screenshot.png', fullPage: true });

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
  const fs = require('fs');
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
      currentChunkStarts: currentChunkMessages.length,
      errors: errorMessages.length,
      warnings: warningMessages.length
    },
    allMessages: consoleMessages
  };

  fs.writeFileSync(
    '/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/console-output.json',
    JSON.stringify(outputReport, null, 2)
  );

  console.log('Full console output saved to console-output.json');
  console.log('Screenshot saved to transcript-editor-screenshot.png');

  await browser.close();

  console.log('\n=== VERIFICATION COMPLETE ===');
})();
