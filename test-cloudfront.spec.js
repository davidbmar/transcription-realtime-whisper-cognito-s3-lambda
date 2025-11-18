const { chromium } = require('playwright');

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();

  // Enable console logging from the page
  page.on('console', msg => console.log('BROWSER:', msg.text()));

  console.log('Loading test page from CloudFront...');
  await page.goto('https://d2l28rla2hk7np.cloudfront.net/test-selection-standalone.html');

  console.log('Waiting for page to load and auto-run test...');
  await page.waitForTimeout(1000);

  // Wait for the test result to appear
  await page.waitForSelector('#test-result', { state: 'visible', timeout: 5000 });

  console.log('Taking screenshot...');
  await page.screenshot({
    path: '/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/cloudfront-test-result.png',
    fullPage: true
  });

  // Extract the test results
  const testResult = await page.evaluate(() => {
    const resultDiv = document.getElementById('test-result');
    const selectedText = window.getSelection().toString();

    return {
      text: resultDiv.textContent,
      isPassing: resultDiv.classList.contains('success'),
      selectedText: selectedText
    };
  });

  console.log('\n' + '='.repeat(70));
  console.log('CLOUDFRONT DEPLOYMENT TEST RESULTS:');
  console.log('='.repeat(70));
  console.log(testResult.text);
  console.log('='.repeat(70));

  if (testResult.isPassing) {
    console.log('\n✓ SUCCESS: Text selection correctly excludes metadata!');
    console.log('\nThis means the CSS user-select properties are working correctly.');
    console.log('The selected text should contain ONLY the transcript content:');
    console.log('\n' + '-'.repeat(70));
    console.log(testResult.selectedText.substring(0, 500));
    console.log('-'.repeat(70));
  } else {
    console.log('\n✗ FAILURE: Text selection includes metadata that should be excluded!');
    console.log('\nThe CSS user-select properties are NOT working correctly.');
  }

  console.log('\nScreenshot saved to: cloudfront-test-result.png');
  console.log('URL tested: https://d2l28rla2hk7np.cloudfront.net/test-selection-standalone.html');

  await browser.close();

  // Exit with appropriate code
  process.exit(testResult.isPassing ? 0 : 1);
})();
