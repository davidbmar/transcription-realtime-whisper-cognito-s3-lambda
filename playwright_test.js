const { chromium } = require('playwright');

(async () => {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext();
  const page = await context.newPage();

  // Array to store all console messages
  const consoleMessages = [];

  // Listen to console events
  page.on('console', msg => {
    const text = msg.text();
    const type = msg.type();
    consoleMessages.push({ type, text, timestamp: new Date().toISOString() });
    console.log(`[${type.toUpperCase()}] ${text}`);
  });

  console.log('Navigating to the URL...');
  await page.goto('https://d2l28rla2hk7np.cloudfront.net/transcript-editor-v2.html');

  console.log('Waiting 2 minutes for CloudFront cache...');
  await page.waitForTimeout(120000); // 2 minutes

  // Check if we need to log in
  const signInButton = await page.$('button:has-text("Sign In to Continue")');
  if (signInButton) {
    console.log('\n=== AUTHENTICATION REQUIRED ===');
    console.log('Clicking Sign In button...');
    await signInButton.click();

    // Wait for Cognito hosted UI
    await page.waitForTimeout(2000);

    // Fill in credentials
    console.log('Entering credentials...');
    await page.fill('input[name="username"]', 'david.bryan.mar@gmail.com');
    await page.fill('input[name="password"]', 'Testtesttest1');

    // Click sign in
    await page.click('input[type="submit"]');

    // Wait for redirect back to app
    console.log('Waiting for authentication...');
    await page.waitForTimeout(5000);
  }

  console.log('\n=== CAPTURED CONSOLE MESSAGES ===');
  consoleMessages.forEach(msg => {
    console.log(`[${msg.timestamp}] [${msg.type}] ${msg.text}`);
  });

  // Find preprocessor initialization message
  console.log('\n=== PREPROCESSOR ANALYSIS ===');
  const preprocessorMsg = consoleMessages.find(msg => msg.text.includes('Preprocessor initialized:'));
  if (preprocessorMsg) {
    console.log('Found preprocessor message:', preprocessorMsg.text);
  } else {
    console.log('No preprocessor initialization message found');
  }

  // Find boundary processing messages
  console.log('\n=== BOUNDARY PROCESSING MESSAGES ===');
  const boundaryMsgs = consoleMessages.filter(msg =>
    msg.text.includes('[Boundary Preprocessor]') || msg.text.includes('[Boundary Dedup]')
  );
  if (boundaryMsgs.length > 0) {
    boundaryMsgs.forEach(msg => console.log(msg.text));
  } else {
    console.log('No boundary processing messages found');
  }

  // Get paragraphs 4, 5, and 6
  console.log('\n=== PARAGRAPH CONTENT ===');
  try {
    const paragraphs = await page.$$('.paragraph');
    console.log(`Total paragraphs found: ${paragraphs.length}`);

    if (paragraphs.length > 0) {
      for (let i = 3; i < 6 && i < paragraphs.length; i++) {
        const text = await paragraphs[i].textContent();
        const isEditable = await paragraphs[i].getAttribute('contenteditable');
        console.log(`\nParagraph ${i + 1}:`);
        console.log(`  contentEditable: ${isEditable}`);
        console.log(`  Text: ${text.trim().substring(0, 300)}...`);
      }
    } else {
      console.log('No paragraphs found. Page may still be loading or structure is different.');
    }
  } catch (error) {
    console.log('Error getting paragraphs:', error.message);
  }

  // Take screenshot showing paragraphs 4, 5, 6
  console.log('\n=== TAKING SCREENSHOT ===');
  try {
    // Try to scroll to paragraph 4
    const paragraph4 = await page.$('.paragraph:nth-child(4)');
    if (paragraph4) {
      await paragraph4.scrollIntoViewIfNeeded();
      await page.waitForTimeout(1000);
    }
    await page.screenshot({
      path: '/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/screenshot.png',
      fullPage: false
    });
    console.log('Screenshot saved to screenshot.png');
  } catch (error) {
    console.log('Error taking screenshot:', error.message);
  }

  // Check for Edit Mode button and try to click it
  console.log('\n=== EDIT MODE TOGGLE ===');
  try {
    const editButton = await page.$('button:has-text("Edit Mode")');
    if (editButton) {
      console.log('Edit Mode button found');

      // Get initial contentEditable state
      const paragraphs = await page.$$('.paragraph');
      if (paragraphs.length > 0) {
        const initialEditable = await paragraphs[0].getAttribute('contenteditable');
        console.log(`Initial contentEditable state: ${initialEditable}`);

        // Click the button
        await editButton.click();
        await page.waitForTimeout(1000);

        // Check contentEditable state after click
        const afterEditable = await paragraphs[0].getAttribute('contenteditable');
        console.log(`After click contentEditable state: ${afterEditable}`);
        console.log(`Toggle working: ${initialEditable !== afterEditable}`);
      }
    } else {
      console.log('Edit Mode button not found');

      // List all buttons on page for debugging
      const buttons = await page.$$('button');
      console.log(`Total buttons found: ${buttons.length}`);
      for (let i = 0; i < Math.min(buttons.length, 10); i++) {
        const text = await buttons[i].textContent();
        console.log(`  Button ${i + 1}: "${text.trim()}"`);
      }
    }
  } catch (error) {
    console.log('Error with Edit Mode button:', error.message);
  }

  // Get page HTML to inspect structure
  console.log('\n=== PAGE STRUCTURE ===');
  const bodyHTML = await page.evaluate(() => {
    const body = document.body.innerHTML;
    return body.substring(0, 1000); // First 1000 chars
  });
  console.log('Page HTML (first 1000 chars):');
  console.log(bodyHTML);

  console.log('\n=== SUMMARY ===');
  console.log(`Total console messages captured: ${consoleMessages.length}`);
  console.log(`Boundary-related messages: ${boundaryMsgs.length}`);

  await browser.close();
})();
