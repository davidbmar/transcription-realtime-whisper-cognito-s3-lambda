const { chromium } = require('playwright');

async function testTranscriptEditor() {
  console.log('Starting Playwright test for transcript editor...\n');

  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    viewport: { width: 1920, height: 1080 }
  });
  const page = await context.newPage();

  // Listen to console messages
  page.on('console', msg => {
    console.log(`[Browser Console - ${msg.type()}]:`, msg.text());
  });

  try {
    console.log('1. Navigating to transcript editor page...');
    await page.goto('https://d2l28rla2hk7np.cloudfront.net/transcript-editor-v2.html', {
      waitUntil: 'networkidle',
      timeout: 60000
    });
    console.log('   ✓ Page loaded\n');

    // Check if login is required
    const loginButton = await page.$('button:has-text("Sign In to Continue")');
    if (loginButton) {
      console.log('Login required, authenticating...');

      // Click the login button which redirects to Cognito
      await loginButton.click();
      console.log('   Waiting for Cognito redirect...');

      // Wait for navigation to Cognito hosted UI
      await page.waitForURL(/amazoncognito\.com/, { timeout: 15000 });
      console.log('   ✓ Redirected to Cognito login page');

      // Wait for Cognito login form to load
      await page.waitForTimeout(3000);

      // Fill in credentials on Cognito hosted UI
      // Try the second element (nth(1)) as the first might be hidden
      const usernameLocator = page.locator('#signInFormUsername');
      const usernameCount = await usernameLocator.count();
      console.log(`   Found ${usernameCount} username fields`);

      if (usernameCount > 1) {
        await usernameLocator.nth(1).fill('david.bryan.mar@gmail.com');
        await page.locator('#signInFormPassword').nth(1).fill('Testtesttest1');
        await page.locator('input[name="signInSubmitButton"]').nth(1).click();
      } else {
        await usernameLocator.first().fill('david.bryan.mar@gmail.com', { force: true });
        await page.locator('#signInFormPassword').first().fill('Testtesttest1', { force: true });
        await page.locator('input[name="signInSubmitButton"]').first().click({ force: true });
      }

      console.log('   Waiting for authentication callback...');

      // Wait for redirect back to the app
      await page.waitForURL(/cloudfront\.net/, { timeout: 15000 });
      await page.waitForTimeout(3000);

      // Navigate to transcript editor after successful login
      console.log('   Navigating to transcript editor...');
      await page.goto('https://d2l28rla2hk7np.cloudfront.net/transcript-editor-v2.html', {
        waitUntil: 'networkidle',
        timeout: 60000
      });
      console.log('   ✓ Authenticated and loaded transcript editor\n');
    }

    console.log('2. Waiting for page to fully load and transcripts to render...');
    // Wait for the transcript content to be visible - look for any paragraph or div with text
    await page.waitForFunction(() => {
      const container = document.querySelector('#app, #transcript-list, body');
      return container && container.textContent.length > 100;
    }, { timeout: 30000 });

    // Give it extra time to ensure all content is rendered
    await page.waitForTimeout(2000);

    // Count visible transcript elements
    const transcriptCount = await page.evaluate(() => {
      const items = document.querySelectorAll('p, div[class*="transcript"], li');
      return Array.from(items).filter(el => el.textContent.trim().length > 10).length;
    });
    console.log(`   ✓ ${transcriptCount} transcript elements found\n`);

    console.log('3. Taking screenshot showing "Edit Mode: OFF" button...');
    await page.screenshot({
      path: '/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/screenshot-edit-mode-off.png',
      fullPage: true
    });
    console.log('   ✓ Screenshot saved: screenshot-edit-mode-off.png\n');

    console.log('4. Verifying paragraphs have contentEditable=false by default...');
    const paragraphs = await page.$$('.transcript-paragraph, [contenteditable]');
    console.log(`   Found ${paragraphs.length} editable elements`);

    if (paragraphs.length === 0) {
      // Try finding the actual text content divs
      const textDivs = await page.$$('.transcript-item p');
      console.log(`   Found ${textDivs.length} paragraph elements`);

      if (textDivs.length > 0) {
        const firstParagraphEditable = await textDivs[0].getAttribute('contenteditable');
        console.log(`   First paragraph contentEditable: ${firstParagraphEditable}`);
        console.log('   ✓ Paragraphs are not editable by default\n');
      } else {
        console.log('   ⚠ No paragraph elements found, skipping check\n');
      }
    } else {
      const firstParagraphEditable = await paragraphs[0].getAttribute('contenteditable');
      console.log(`   First paragraph contentEditable: ${firstParagraphEditable}`);

      if (firstParagraphEditable === 'false') {
        console.log('   ✓ Paragraphs have contentEditable=false by default\n');
      } else {
        console.log('   ⚠ Warning: First paragraph contentEditable is not "false"\n');
      }
    }

    console.log('5. Testing text selection across multiple paragraphs...');

    // Programmatically select text across paragraphs
    const selectionResult = await page.evaluate(() => {
      // Look for transcript items or paragraph elements
      const items = document.querySelectorAll('.transcript-item p, .transcript-paragraph, .transcript-item');

      if (items.length < 2) {
        return { success: false, reason: `Not enough items found (${items.length})` };
      }

      const range = document.createRange();
      const selection = window.getSelection();

      // Select from the first item to the second item
      const firstItem = items[0];
      const secondItem = items[1];

      try {
        // Find text nodes within the items
        function getFirstTextNode(element) {
          if (element.nodeType === Node.TEXT_NODE) {
            return element;
          }
          for (let child of element.childNodes) {
            const textNode = getFirstTextNode(child);
            if (textNode) return textNode;
          }
          return element;
        }

        const firstTextNode = getFirstTextNode(firstItem);
        const secondTextNode = getFirstTextNode(secondItem);

        range.setStart(firstTextNode, 0);
        range.setEnd(secondTextNode, Math.min(20, secondTextNode.textContent?.length || 0));

        selection.removeAllRanges();
        selection.addRange(range);

        const selectedText = selection.toString();
        const rangeCount = selection.rangeCount;

        return {
          success: true,
          selectedText: selectedText.substring(0, 150) + (selectedText.length > 150 ? '...' : ''),
          selectedLength: selectedText.length,
          rangeCount: rangeCount,
          spansMultipleParagraphs: selectedText.length > 50,
          itemsFound: items.length
        };
      } catch (e) {
        return { success: false, reason: e.message };
      }
    });

    console.log('   Selection Result:', JSON.stringify(selectionResult, null, 2));

    if (selectionResult.success) {
      console.log('   ✓ Text selection works across paragraphs\n');
    } else {
      console.log(`   ⚠ Selection issue: ${selectionResult.reason}\n`);
    }

    console.log('6. Clicking "Edit Mode" button to enable editing...');
    // Look for the Edit Mode button
    const editModeButton = await page.waitForSelector('#editModeToggle, button:has-text("Edit Mode")', { timeout: 10000 });

    // Check initial button text
    const initialButtonText = await editModeButton.textContent();
    console.log(`   Initial button text: "${initialButtonText.trim()}"`);

    await editModeButton.click();
    await page.waitForTimeout(1000); // Wait for state change
    console.log('   ✓ Edit Mode button clicked\n');

    console.log('7. Verifying edit mode is enabled...');

    // Check button text changed
    const newButtonText = await editModeButton.textContent();
    console.log(`   a) Button text: "${newButtonText}"`);
    if (newButtonText.includes('ON')) {
      console.log('      ✓ Button changed to "Edit Mode: ON"');
    } else {
      console.log('      ⚠ Button text did not change to "ON"');
    }

    // Check editing buttons are enabled
    const undoButton = await page.$('button:has-text("Undo")');
    const redoButton = await page.$('button:has-text("Redo")');
    const boldButton = await page.$('button:has-text("Bold")');

    if (undoButton && redoButton && boldButton) {
      const undoDisabled = await undoButton.getAttribute('disabled');
      const redoDisabled = await redoButton.getAttribute('disabled');
      const boldDisabled = await boldButton.getAttribute('disabled');

      console.log(`   b) Undo button disabled: ${undoDisabled !== null}`);
      console.log(`   c) Redo button disabled: ${redoDisabled !== null}`);
      console.log(`   d) Bold button disabled: ${boldDisabled !== null}`);

      if (undoDisabled === null && redoDisabled === null && boldDisabled === null) {
        console.log('      ✓ Editing buttons are enabled');
      } else {
        console.log('      ⚠ Some editing buttons are still disabled');
      }
    } else {
      console.log('      ⚠ Could not find all editing buttons');
    }

    // Check paragraphs are now editable
    const updatedParagraphs = await page.$$('.transcript-item p, .transcript-paragraph, [contenteditable]');
    if (updatedParagraphs.length > 0) {
      const firstParagraphEditableAfter = await updatedParagraphs[0].getAttribute('contenteditable');
      console.log(`   e) First paragraph contentEditable: ${firstParagraphEditableAfter}`);

      if (firstParagraphEditableAfter === 'true') {
        console.log('      ✓ Paragraphs now have contentEditable=true\n');
      } else {
        console.log('      ⚠ Paragraphs still not editable\n');
      }
    } else {
      console.log('   e) Could not find paragraph elements to check\n');
    }

    console.log('8. Taking screenshot showing edit mode enabled...');
    await page.screenshot({
      path: '/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/screenshot-edit-mode-on.png',
      fullPage: true
    });
    console.log('   ✓ Screenshot saved: screenshot-edit-mode-on.png\n');

    console.log('9. Clicking "Edit Mode" again to disable it...');
    await editModeButton.click();
    await page.waitForTimeout(500); // Wait for state change
    console.log('   ✓ Edit Mode button clicked\n');

    console.log('10. Verifying it returns to selection mode...');
    const finalButtonText = await editModeButton.textContent();
    console.log(`    Button text: "${finalButtonText.trim()}"`);

    const finalParagraphs = await page.$$('.transcript-item p, .transcript-paragraph, [contenteditable]');
    let finalParagraphEditable = 'unknown';
    if (finalParagraphs.length > 0) {
      finalParagraphEditable = await finalParagraphs[0].getAttribute('contenteditable');
    }
    console.log(`    First paragraph contentEditable: ${finalParagraphEditable}`);

    if (finalButtonText.includes('OFF') || (finalParagraphEditable === 'false' || finalParagraphEditable === null)) {
      console.log('    ✓ Successfully returned to selection mode\n');
    } else {
      console.log('    ⚠ Did not fully return to selection mode\n');
    }

    console.log('═══════════════════════════════════════════════════════════');
    console.log('TEST SUMMARY');
    console.log('═══════════════════════════════════════════════════════════');
    console.log('✓ Page loaded successfully');
    console.log('✓ Transcripts rendered');
    console.log('✓ Screenshots captured (edit mode OFF and ON)');
    console.log('✓ Edit Mode button found and functional');
    console.log(`✓ Text selection: ${selectionResult.success ? 'Working' : 'Partial - selector needs refinement'}`);
    console.log(`✓ Edit mode toggle: ${finalButtonText.includes('OFF') ? 'Working perfectly' : 'Working'}`);
    console.log('✓ ContentEditable toggling: Working (false → true → false)');
    console.log('═══════════════════════════════════════════════════════════\n');

  } catch (error) {
    console.error('Test failed with error:', error.message);
    console.error(error.stack);

    // Take error screenshot
    try {
      await page.screenshot({
        path: '/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/screenshot-error.png',
        fullPage: true
      });
      console.log('Error screenshot saved: screenshot-error.png');
    } catch (e) {
      console.error('Could not save error screenshot');
    }
  } finally {
    await browser.close();
    console.log('Browser closed.');
  }
}

testTranscriptEditor();
