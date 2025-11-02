const { chromium } = require('playwright');

(async () => {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    permissions: ['microphone']
  });
  const page = await context.newPage();

  // Capture all console messages
  const consoleMessages = [];
  page.on('console', msg => {
    const text = msg.text();
    const msgType = msg.type();
    console.log(`[CONSOLE ${msgType}] ${text}`);
    consoleMessages.push({ type: msgType, text });
  });

  // Capture errors
  page.on('pageerror', error => {
    console.log(`[PAGE ERROR] ${error.message}`);
  });

  console.log('Loading audio.html...');
  await page.goto(process.env.COGNITO_CLOUDFRONT_URL + '/audio.html');

  // Wait a bit for page to load
  await page.waitForTimeout(2000);

  // Check if we're logged in or need to login
  const currentUrl = page.url();
  console.log(`Current URL: ${currentUrl}`);

  if (currentUrl.includes('auth') || currentUrl.includes('login')) {
    console.log('Not logged in, redirecting to Cognito...');
    await browser.close();
    console.log('\nNeed to login first. Run ./test-login.sh');
    process.exit(0);
  }

  // Look for the start button
  console.log('\nLooking for start button...');
  const startBtn = await page.$('#start-btn');
  if (!startBtn) {
    console.log('ERROR: Start button not found!');
  } else {
    console.log('✅ Start button found');
  }

  // Click the start button
  console.log('\nClicking start button...');
  await page.click('#start-btn');

  // Wait and collect console output
  console.log('\nWaiting for 5 seconds to collect console output...');
  await page.waitForTimeout(5000);

  console.log('\n=== SUMMARY ===');
  console.log(`Total console messages: ${consoleMessages.length}`);

  const errors = consoleMessages.filter(m => m.type === 'error');
  if (errors.length > 0) {
    console.log(`\n❌ ERRORS (${errors.length}):`);
    errors.forEach(e => console.log(`  - ${e.text}`));
  }

  const warnings = consoleMessages.filter(m => m.type === 'warning');
  if (warnings.length > 0) {
    console.log(`\n⚠️  WARNINGS (${warnings.length}):`);
    warnings.forEach(w => console.log(`  - ${w.text}`));
  }

  await browser.close();
})();
