const { chromium } = require('playwright');

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();

  // Enable console logging from the page
  page.on('console', msg => console.log('BROWSER:', msg.text()));

  console.log('Loading standalone test page...');
  const htmlPath = 'file:///home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/test-selection-standalone.html';
  await page.goto(htmlPath);

  console.log('Waiting for page to load and auto-run test...');
  await page.waitForTimeout(1000);

  // Wait for the test result to appear
  await page.waitForSelector('#test-result', { state: 'visible', timeout: 5000 });

  console.log('Taking screenshot...');
  await page.screenshot({
    path: '/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/test-selection-result.png',
    fullPage: true
  });

  // Extract the test results
  const testResult = await page.evaluate(() => {
    const resultDiv = document.getElementById('test-result');
    return {
      text: resultDiv.textContent,
      isPassing: resultDiv.classList.contains('success')
    };
  });

  console.log('\n' + '='.repeat(70));
  console.log('TEST RESULTS:');
  console.log('='.repeat(70));
  console.log(testResult.text);
  console.log('='.repeat(70));

  if (testResult.isPassing) {
    console.log('\n✓ SUCCESS: Text selection correctly excludes metadata!');
  } else {
    console.log('\n✗ FAILURE: Text selection includes metadata that should be excluded!');
  }

  console.log('\nScreenshot saved to: test-selection-result.png');

  await browser.close();

  // Exit with appropriate code
  process.exit(testResult.isPassing ? 0 : 1);
})();
