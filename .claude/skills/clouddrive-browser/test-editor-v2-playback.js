const { chromium } = require('playwright');

(async () => {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    storageState: '/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/.claude/skills/clouddrive-browser/auth-state.json'
  });
  const page = await context.newPage();

  // Capture console logs
  page.on('console', msg => {
    console.log('[BROWSER ' + msg.type() + ']', msg.text());
  });

  // Capture errors
  page.on('pageerror', error => {
    console.error('[PAGE ERROR]', error);
  });

  console.log('Navigating to transcript editor v2...');
  await page.goto('https://d2l28rla2hk7np.cloudfront.net/transcript-editor-v2.html');

  console.log('Waiting for page to load...');
  await page.waitForTimeout(3000);

  // Check if session selector exists
  const sessionSelector = await page.locator('#session-selector').count();
  console.log('Session selector found:', sessionSelector > 0);

  if (sessionSelector > 0) {
    // Get available sessions
    const sessions = await page.locator('#session-selector option').count();
    console.log('Available sessions:', sessions);

    if (sessions > 1) { // More than just the default option
      // Select the first real session
      await page.selectOption('#session-selector', { index: 1 });
      console.log('Selected first session');

      // Wait for transcript to load
      await page.waitForTimeout(5000);

      // Check for play buttons
      const playButtons = await page.locator('button.audio-btn').count();
      console.log('Play buttons found:', playButtons);

      if (playButtons > 0) {
        // Take screenshot before clicking
        await page.screenshot({ path: '/tmp/editor-v2-before-play.png', fullPage: true });
        console.log('Screenshot saved: /tmp/editor-v2-before-play.png');

        // Click the first play button
        console.log('Clicking first play button...');
        await page.locator('button.audio-btn').first().click();

        // Wait for playback to start
        await page.waitForTimeout(2000);

        // Check if button text changed to Pause
        const buttonText = await page.locator('button.audio-btn').first().textContent();
        console.log('Button text after click:', buttonText);

        // Check for word highlighting
        const highlightedWords = await page.locator('.word-highlight.playing').count();
        console.log('Highlighted words found:', highlightedWords);

        // Take screenshot during playback
        await page.screenshot({ path: '/tmp/editor-v2-playing.png', fullPage: true });
        console.log('Screenshot saved: /tmp/editor-v2-playing.png');

        // Test pause
        console.log('Clicking pause...');
        await page.locator('button.audio-btn').first().click();
        await page.waitForTimeout(500);

        const pausedButtonText = await page.locator('button.audio-btn').first().textContent();
        console.log('Button text after pause:', pausedButtonText);

        // Test resume
        console.log('Clicking play again...');
        await page.locator('button.audio-btn').first().click();
        await page.waitForTimeout(1000);

        // Test double-click to stop
        console.log('Double-clicking to stop...');
        await page.locator('button.audio-btn').first().dblclick();
        await page.waitForTimeout(500);

        const stoppedButtonText = await page.locator('button.audio-btn').first().textContent();
        console.log('Button text after double-click stop:', stoppedButtonText);

        // Final screenshot
        await page.screenshot({ path: '/tmp/editor-v2-stopped.png', fullPage: true });
        console.log('Screenshot saved: /tmp/editor-v2-stopped.png');
      }
    }
  }

  console.log('Test complete!');
  await browser.close();
})();
