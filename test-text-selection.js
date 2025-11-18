const { chromium } = require('playwright');

(async () => {
  console.log('Waiting 3-4 minutes for CloudFront cache to propagate...');
  console.log('Start time:', new Date().toISOString());

  // Wait 4 minutes for CloudFront cache propagation
  await new Promise(resolve => setTimeout(resolve, 4 * 60 * 1000));

  console.log('Cache propagation wait complete. Starting test...');
  console.log('Test start time:', new Date().toISOString());

  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    viewport: { width: 1280, height: 720 }
  });
  const page = await context.newPage();

  try {
    // Step 1: Navigate to CloudDrive and sign in
    console.log('\n=== STEP 1: AUTHENTICATION ===');
    console.log('Navigating to CloudDrive...');
    await page.goto('https://d2l28rla2hk7np.cloudfront.net/index.html', {
      waitUntil: 'networkidle',
      timeout: 60000
    });

    // Wait for sign-in button
    console.log('Waiting for sign-in button...');
    await page.waitForSelector('#login-button', { timeout: 30000 });

    console.log('Clicking sign-in button...');
    await page.click('#login-button');

    // Wait for Cognito hosted UI
    console.log('Waiting for Cognito login page...');
    await page.waitForURL(/.*amazoncognito\.com.*/, { timeout: 10000 });

    // Fill in credentials (Cognito has duplicate forms - use .last() to get the visible one)
    console.log('Filling in credentials...');
    await page.getByPlaceholder('name@host.com').last().fill('david.bryan.mar@gmail.com');
    await page.getByPlaceholder('Password').last().fill('Testtesttest1');

    console.log('Submitting login form...');
    await page.getByPlaceholder('Password').last().press('Enter');

    // Wait for redirect back to CloudDrive
    console.log('Waiting for authentication callback...');
    const CLOUDDRIVE_URL = 'https://d2l28rla2hk7np.cloudfront.net';
    await page.waitForURL(`${CLOUDDRIVE_URL}/**`, { timeout: 15000 });

    // Wait for authenticated section to appear
    await page.waitForSelector('#authenticated-section', { state: 'visible', timeout: 10000 });

    console.log('✓ Successfully authenticated');

    // Step 2: Navigate to transcript editor
    console.log('\n=== STEP 2: NAVIGATE TO TRANSCRIPT EDITOR ===');
    console.log('Navigating to transcript editor...');
    await page.goto('https://d2l28rla2hk7np.cloudfront.net/transcript-editor-v2.html', {
      waitUntil: 'networkidle',
      timeout: 60000
    });

    console.log('Waiting for page to fully load and transcripts to render...');
    // Wait for transcript content to be visible - look for any transcript element
    await page.waitForFunction(() => {
      const body = document.body.innerText;
      return body.length > 100; // Wait for significant content
    }, { timeout: 30000 });

    // Wait a bit more to ensure all content is rendered
    await page.waitForTimeout(3000);

    console.log('✓ Transcript editor loaded');

    // Step 3: Analyze page structure
    console.log('\n=== STEP 3: ANALYZING PAGE STRUCTURE ===');
    const pageInfo = await page.evaluate(() => {
      // Try to find transcript elements
      const possibleSelectors = [
        '.transcript-chunk',
        '.transcript-section',
        '[data-chunk]',
        'p',
        '.chunk',
        '.transcript'
      ];

      const results = {};
      possibleSelectors.forEach(selector => {
        const elements = document.querySelectorAll(selector);
        results[selector] = elements.length;
      });

      // Get page structure sample
      const bodyHTML = document.body.innerHTML.substring(0, 2000);

      return {
        selectors: results,
        bodyHTMLSample: bodyHTML,
        bodyTextSample: document.body.innerText.substring(0, 500)
      };
    });

    console.log('Selectors found:');
    Object.entries(pageInfo.selectors).forEach(([selector, count]) => {
      console.log(`  ${selector}: ${count} elements`);
    });

    console.log('\nPage text sample:');
    console.log(pageInfo.bodyTextSample);

    // Step 4: Select text programmatically
    console.log('\n=== STEP 4: SELECTING TEXT ===');

    // Use JavaScript to create a selection of the first significant text
    const selectedText = await page.evaluate(() => {
      // Clear any existing selection
      const selection = window.getSelection();
      selection.removeAllRanges();

      // Try to find all paragraphs
      let paragraphs = document.querySelectorAll('.transcript-chunk p');

      if (paragraphs.length === 0) {
        // Fallback: find any paragraphs
        paragraphs = document.querySelectorAll('p');
      }

      if (paragraphs.length === 0) {
        return { error: 'No paragraphs found' };
      }

      console.log(`Found ${paragraphs.length} paragraphs`);

      // Select the first 3 paragraphs (or all if less than 3)
      const count = Math.min(3, paragraphs.length);
      const firstPara = paragraphs[0];
      const lastPara = paragraphs[count - 1];

      // Create range
      const range = document.createRange();

      try {
        // Try to select from first to last paragraph
        range.setStartBefore(firstPara);
        range.setEndAfter(lastPara);

        selection.addRange(range);

        // Get the selected text
        const text = selection.toString();

        // Also get the HTML to analyze structure
        const firstParaHTML = paragraphs[0].parentElement ?
          paragraphs[0].parentElement.innerHTML.substring(0, 1000) :
          paragraphs[0].innerHTML.substring(0, 1000);

        return {
          selectedText: text,
          firstParagraphHTML: firstParaHTML,
          paragraphCount: paragraphs.length,
          selectedParagraphs: count,
          selectionInfo: {
            rangeCount: selection.rangeCount,
            isCollapsed: selection.isCollapsed,
            textLength: text.length
          }
        };
      } catch (err) {
        return { error: `Selection error: ${err.message}` };
      }
    });

    if (selectedText.error) {
      throw new Error(selectedText.error);
    }

    console.log(`✓ Selected text from ${selectedText.selectedParagraphs} paragraphs`);
    console.log(`Total paragraphs found: ${selectedText.paragraphCount}`);

    // Step 5: Show selected text
    console.log('\n=== STEP 5: SELECTED TEXT ===');
    console.log('==================');
    console.log(selectedText.selectedText);
    console.log('==================');
    console.log(`\nText length: ${selectedText.selectionInfo.textLength} characters`);

    // Step 6: Check for metadata
    console.log('\n=== STEP 6: METADATA VALIDATION ===');
    const text = selectedText.selectedText;
    const issues = [];

    // Check for timestamps (format like 00:00 or 0:00)
    const timestampMatch = text.match(/\d{1,2}:\d{2}/g);
    if (timestampMatch) {
      issues.push(`FOUND: Timestamps (${timestampMatch.join(', ')})`);
    }

    // Check for play button text/symbols
    if (/▶|play|▷/i.test(text)) {
      issues.push('FOUND: Play button text');
    }

    // Check for chunk badges
    if (/chunk|badge/i.test(text)) {
      issues.push('FOUND: Chunk badge text');
    }

    // Check for "Show Original"
    if (/show original/i.test(text)) {
      issues.push('FOUND: "Show Original" text');
    }

    console.log('\nMetadata Check Results:');
    if (issues.length === 0) {
      console.log('✓ PASS: No metadata found in selected text!');
      console.log('✓ Text selection is clean');
    } else {
      console.log('✗ FAIL: Found metadata in selected text:');
      issues.forEach(issue => console.log(`  - ${issue}`));
    }

    console.log('\nFirst paragraph HTML sample:');
    console.log(selectedText.firstParagraphHTML);

    // Step 7: Take screenshot
    console.log('\n=== STEP 7: SCREENSHOT ===');
    await page.screenshot({
      path: '/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/text-selection-screenshot.png',
      fullPage: false
    });
    console.log('✓ Screenshot saved: text-selection-screenshot.png');

    // Summary
    console.log('\n========================================');
    console.log('             SUMMARY');
    console.log('========================================');
    console.log('Selected Text Length:', selectedText.selectionInfo.textLength, 'characters');
    console.log('Paragraphs Selected:', selectedText.selectedParagraphs);
    console.log('Total Paragraphs:', selectedText.paragraphCount);
    console.log('Metadata Issues Found:', issues.length);
    console.log('Test Result:', issues.length === 0 ? 'PASS ✓' : 'FAIL ✗');
    console.log('========================================\n');

  } catch (error) {
    console.error('\n✗ ERROR:', error.message);
    console.error(error.stack);

    // Take error screenshot
    try {
      await page.screenshot({
        path: '/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/error-screenshot.png',
        fullPage: true
      });
      console.log('Error screenshot saved: error-screenshot.png');
    } catch (screenshotError) {
      console.error('Could not save error screenshot:', screenshotError.message);
    }
  } finally {
    await browser.close();
    console.log('Browser closed');
    console.log('End time:', new Date().toISOString());
  }
})();
