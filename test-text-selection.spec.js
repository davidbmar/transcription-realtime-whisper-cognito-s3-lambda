const { chromium } = require('playwright');

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();

  // Enable console logging from the page
  page.on('console', msg => console.log('BROWSER:', msg.text()));

  console.log('Navigating to transcript editor page...');

  // First navigate to set up authentication context
  await page.goto('https://d2l28rla2hk7np.cloudfront.net/index.html');

  // Set up mock authentication token to bypass login check
  await page.evaluate(() => {
    // Create a fake JWT token that won't expire for a while
    const header = btoa(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
    const payload = btoa(JSON.stringify({
      sub: 'test-user',
      email: 'test@example.com',
      exp: Math.floor(Date.now() / 1000) + 3600 // Expires in 1 hour
    }));
    const signature = 'fake-signature';
    const fakeToken = `${header}.${payload}.${signature}`;

    localStorage.setItem('auth_token', fakeToken);
    localStorage.setItem('user_data', JSON.stringify({ email: 'test@example.com' }));
  });

  console.log('Mock authentication set up, now navigating to transcript editor...');

  // Now navigate to the transcript editor with a sample transcript URL parameter
  // We need a real transcript file or we'll need to mock the data
  await page.goto('https://d2l28rla2hk7np.cloudfront.net/transcript-editor-v2.html');

  console.log('Waiting for page to fully load...');
  await page.waitForLoadState('networkidle');

  // Check what page we're actually on
  const pageTitle = await page.title();
  console.log('Page title:', pageTitle);

  const url = page.url();
  console.log('Current URL:', url);

  // Wait for transcripts to render OR check if we need authentication
  console.log('Waiting for transcript content to render...');
  try {
    await page.waitForSelector('.paragraph-container', { timeout: 10000 });
  } catch (e) {
    console.log('No .paragraph-container found. Checking page structure...');

    const structure = await page.evaluate(() => {
      return {
        loadingVisible: document.getElementById('loading')?.style.display,
        mainContainerVisible: document.getElementById('main-container')?.style.display,
        editorContent: document.getElementById('editor-content')?.innerHTML.substring(0, 200),
        hasURLParams: window.location.search.length > 0,
        urlParams: window.location.search,
        localStorage: {
          hasToken: !!localStorage.getItem('auth_token'),
          hasUser: !!localStorage.getItem('user_data')
        }
      };
    });

    console.log('Page structure:', JSON.stringify(structure, null, 2));

    throw new Error('Transcript content not loaded. Page may require authentication or transcript URL parameter.');
  }

  // Give it a bit more time to ensure all content is rendered
  await page.waitForTimeout(2000);

  console.log('Taking initial screenshot...');
  await page.screenshot({ path: '/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/before-selection.png', fullPage: true });

  // Count how many paragraphs exist
  const paragraphCount = await page.evaluate(() => {
    return document.querySelectorAll('.paragraph-text').length;
  });

  console.log(`Found ${paragraphCount} paragraphs on the page`);

  // Programmatically select text across paragraphs 1-5
  console.log('Selecting text across paragraphs 1-5...');
  const selectionResult = await page.evaluate(() => {
    const paragraphs = document.querySelectorAll('.paragraph-text');

    if (paragraphs.length < 5) {
      return { error: `Only found ${paragraphs.length} paragraphs, need at least 5` };
    }

    // Get the first and fifth paragraph text elements
    const firstParagraph = paragraphs[0];
    const fifthParagraph = paragraphs[4];

    // Find the actual text content within these paragraphs
    const firstTextNode = findFirstTextNode(firstParagraph);
    const lastTextNode = findLastTextNode(fifthParagraph);

    if (!firstTextNode || !lastTextNode) {
      return { error: 'Could not find text nodes to select' };
    }

    // Create selection
    const selection = window.getSelection();
    const range = document.createRange();
    range.setStart(firstTextNode, 0);
    range.setEnd(lastTextNode, lastTextNode.length);
    selection.removeAllRanges();
    selection.addRange(range);

    // Helper function to find first text node
    function findFirstTextNode(element) {
      const walker = document.createTreeWalker(
        element,
        NodeFilter.SHOW_TEXT,
        null,
        false
      );

      let node;
      while (node = walker.nextNode()) {
        if (node.textContent.trim().length > 0) {
          return node;
        }
      }
      return null;
    }

    // Helper function to find last text node
    function findLastTextNode(element) {
      const walker = document.createTreeWalker(
        element,
        NodeFilter.SHOW_TEXT,
        null,
        false
      );

      let lastNode = null;
      let node;
      while (node = walker.nextNode()) {
        if (node.textContent.trim().length > 0) {
          lastNode = node;
        }
      }
      return lastNode;
    }

    return { success: true };
  });

  if (selectionResult.error) {
    console.error('Selection error:', selectionResult.error);
    await browser.close();
    return;
  }

  console.log('Text selected successfully');

  // Wait a moment for the selection to be visible
  await page.waitForTimeout(500);

  console.log('Taking screenshot with selection...');
  await page.screenshot({ path: '/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/with-selection.png', fullPage: true });

  // Extract the selected text
  console.log('Extracting selected text...');
  const selectedText = await page.evaluate(() => {
    return window.getSelection().toString();
  });

  console.log('\n=== SELECTED TEXT ===');
  console.log(selectedText);
  console.log('=== END SELECTED TEXT ===\n');

  // Verify that metadata is NOT included
  console.log('Verifying selected text does not contain metadata...\n');

  const checks = [
    { pattern: /⏱️\s*\d+:\d+\s*-\s*\d+:\d+/, name: 'Timestamps (e.g., "⏱️ 0:00 - 0:03")' },
    { pattern: /▶\s*Play/i, name: 'Play buttons ("▶ Play")' },
    { pattern: /chunk-\d+/i, name: 'Chunk badges (e.g., "chunk-001")' },
    { pattern: /Show Original/i, name: '"Show Original" text' },
  ];

  let allChecksPassed = true;

  for (const check of checks) {
    const found = check.pattern.test(selectedText);
    const status = found ? 'FAIL' : 'PASS';
    const symbol = found ? '✗' : '✓';

    console.log(`${symbol} ${status}: ${check.name}`);

    if (found) {
      allChecksPassed = false;
      const match = selectedText.match(check.pattern);
      console.log(`  Found: "${match[0]}"`);
    }
  }

  console.log('\n=== VERIFICATION RESULT ===');
  if (allChecksPassed) {
    console.log('SUCCESS: All metadata exclusion checks passed!');
    console.log('The selected text contains ONLY transcript content.');
  } else {
    console.log('FAILURE: Some metadata was found in the selected text.');
  }
  console.log('===========================\n');

  // Additional analysis
  const textLength = selectedText.length;
  const lines = selectedText.split('\n').filter(line => line.trim().length > 0);

  console.log(`Selected text length: ${textLength} characters`);
  console.log(`Number of non-empty lines: ${lines.length}`);

  console.log('\nFirst 500 characters of selected text:');
  console.log(selectedText.substring(0, 500));

  await browser.close();

  console.log('\nTest completed. Screenshots saved:');
  console.log('- before-selection.png');
  console.log('- with-selection.png');
})();
