const { chromium } = require('playwright');

(async () => {
  const browser = await chromium.launch({
    headless: false, // Use headed mode to see what's happening
    args: ['--no-sandbox', '--disable-setuid-sandbox']
  });

  const context = await browser.newContext({
    viewport: { width: 1920, height: 1080 }
  });

  const page = await context.newPage();

  try {
    console.log('Step 1: Navigating to CloudDrive...');
    await page.goto('https://d2l28rla2hk7np.cloudfront.net/', {
      waitUntil: 'networkidle'
    });

    console.log('Step 2: Clicking login button...');
    await page.click('#login-button');

    console.log('Step 3: Waiting for Cognito login page...');
    await page.waitForURL(/.*amazoncognito\.com.*/, { timeout: 10000 });

    console.log('Step 4: Filling in credentials...');
    await page.fill('input[name="username"]', 'david.bryan.mar@gmail.com');
    await page.fill('input[name="password"]', 'Testtesttest1');

    console.log('Step 5: Submitting login form...');
    await page.click('input[name="signInSubmitButton"]');

    console.log('Step 6: Waiting for redirect back to CloudDrive...');
    await page.waitForURL(/.*cloudfront\.net.*/, { timeout: 15000 });

    // Wait for authentication to complete
    await page.waitForTimeout(3000);

    console.log('Step 7: Extracting tokens from localStorage...');
    const tokens = await page.evaluate(() => {
      return {
        id_token: localStorage.getItem('id_token'),
        access_token: localStorage.getItem('access_token'),
        refresh_token: localStorage.getItem('refresh_token'),
        expires_at: localStorage.getItem('expires_at')
      };
    });

    console.log('Tokens extracted:');
    console.log(JSON.stringify(tokens, null, 2));

    // Save tokens to file
    const fs = require('fs');
    fs.writeFileSync(
      '/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/.claude/skills/clouddrive-download/auth-tokens.json',
      JSON.stringify(tokens, null, 2)
    );

    console.log('Tokens saved to auth-tokens.json');

  } catch (error) {
    console.error('Error during authentication:', error);
    await page.screenshot({
      path: '/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/.claude/skills/clouddrive-download/auth-error.png'
    });
  } finally {
    await browser.close();
  }
})();
