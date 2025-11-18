const { chromium } = require('playwright');

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();

  // Enable console logging from the page
  page.on('console', msg => console.log('BROWSER:', msg.text()));

  console.log('Loading local HTML file to test text selection...');

  // Load the local HTML file directly
  const htmlPath = 'file:///home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/cognito-stack/web/transcript-editor-v2.html';
  await page.goto(htmlPath);

  console.log('Injecting mock data to bypass authentication and API calls...');

  // Inject mock data and skip authentication
  await page.evaluate(() => {
    // Mock the authentication
    window.getAuthToken = () => 'mock-token';
    window.getUserEmail = () => 'test@example.com';
    window.getUserId = () => 'test-user-id';

    // Mock the API calls
    window.apiCall = async (endpoint) => {
      if (endpoint === '/api/audio/sessions') {
        return {
          sessions: [{
            folder: 'session-123',
            createdAt: '2025-11-17T00:00:00Z'
          }]
        };
      }
      if (endpoint.includes('/api/s3/list')) {
        return { files: [] }; // Return no files so it doesn't try to load
      }
      return {};
    };

    // Create mock processed data
    window.processedData = {
      paragraphs: [
        {
          text: "This is for gentlemen's education in the Renaissance and for college writing classes now.",
          start: 0.00,
          end: 3.50,
          chunkIds: ['chunk-001'],
          segments: [{ text: "This is for gentlemen's education in the Renaissance and for college writing classes now." }]
        },
        {
          text: "Cicero's handbooks refer to the lawyer's strategy as narratio, which is where we get the word narrative.",
          start: 3.50,
          end: 7.20,
          chunkIds: ['chunk-001'],
          segments: [{ text: "Cicero's handbooks refer to the lawyer's strategy as narratio, which is where we get the word narrative." }]
        },
        {
          text: "And also where we get the myth that story's purpose is communication.",
          start: 7.20,
          end: 10.50,
          chunkIds: ['chunk-002'],
          segments: [{ text: "And also where we get the myth that story's purpose is communication." }]
        },
        {
          text: "The real purpose of narrative is persuasion and emotional impact.",
          start: 10.50,
          end: 14.00,
          chunkIds: ['chunk-002'],
          segments: [{ text: "The real purpose of narrative is persuasion and emotional impact." }]
        },
        {
          text: "Stories are designed to change minds and hearts, not just convey information.",
          start: 14.00,
          end: 17.80,
          chunkIds: ['chunk-003'],
          segments: [{ text: "Stories are designed to change minds and hearts, not just convey information." }]
        }
      ],
      stats: {
        paragraphCount: 5,
        totalWords: 70,
        totalDuration: 17.80,
        wordsPerMinute: 236
      }
    };

    // Prevent the automatic loading
    window.addEventListener('DOMContentLoaded', (e) => {
      e.stopImmediatePropagation();
    }, true);
  });

  // Wait a moment for scripts to load
  await page.waitForTimeout(2000);

  // Manually trigger rendering with our mock data
  await page.evaluate(() => {
    // Hide loading
    document.getElementById('loading').style.display = 'none';
    document.getElementById('main-container').style.display = 'grid';

    // Set user email
    document.getElementById('user-email').textContent = 'test@example.com';

    // Render the editor manually
    const container = document.getElementById('editor-content');
    container.innerHTML = '';

    // Update stats
    document.getElementById('stat-paragraphs').textContent = window.processedData.stats.paragraphCount;
    document.getElementById('stat-words').textContent = window.processedData.stats.totalWords;
    document.getElementById('stat-duration').textContent = '0:18';
    document.getElementById('stat-wpm').textContent = window.processedData.stats.wordsPerMinute;

    // Render paragraphs manually (simplified version)
    window.processedData.paragraphs.forEach((para, index) => {
      const paraDiv = document.createElement('div');
      paraDiv.className = 'paragraph-container';
      paraDiv.id = `para-${index}`;

      const number = document.createElement('div');
      number.className = 'paragraph-number';
      number.textContent = index + 1;

      const text = document.createElement('div');
      text.className = 'paragraph-text';
      text.contentEditable = false;
      text.textContent = para.text;
      text.dataset.paraIndex = index;

      const meta = document.createElement('div');
      meta.className = 'paragraph-meta';

      // Time
      const timeMeta = document.createElement('div');
      timeMeta.className = 'meta-item';
      timeMeta.innerHTML = `⏱️ ${para.start.toFixed(2)} - ${para.end.toFixed(2)}`;

      // Audio button
      const audioBtn = document.createElement('button');
      audioBtn.className = 'audio-btn';
      audioBtn.textContent = '▶ Play';

      // Chunk badges
      const chunkMeta = document.createElement('div');
      chunkMeta.className = 'meta-item';
      para.chunkIds.forEach(chunkId => {
        const badge = document.createElement('span');
        badge.className = 'chunk-badge';
        badge.textContent = chunkId;
        chunkMeta.appendChild(badge);
      });

      // Original text toggle
      const originalToggle = document.createElement('button');
      originalToggle.className = 'original-text-toggle';
      originalToggle.textContent = 'Show Original';

      meta.appendChild(timeMeta);
      meta.appendChild(audioBtn);
      meta.appendChild(chunkMeta);
      meta.appendChild(originalToggle);

      // Original text content (hidden by default)
      const originalContent = document.createElement('div');
      originalContent.className = 'original-text-content';
      originalContent.id = `original-${index}`;
      originalContent.textContent = para.segments.map(s => s.text).join(' ');

      paraDiv.appendChild(number);
      paraDiv.appendChild(text);
      paraDiv.appendChild(meta);
      paraDiv.appendChild(originalContent);

      container.appendChild(paraDiv);
    });
  });

  console.log('Mock transcript rendered');

  // Wait for rendering to complete
  await page.waitForTimeout(1000);

  console.log('Taking initial screenshot...');
  await page.screenshot({ path: '/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/before-selection.png', fullPage: true });

  // Count how many paragraphs exist
  const paragraphCount = await page.evaluate(() => {
    return document.querySelectorAll('.paragraph-text').length;
  });

  console.log(`Found ${paragraphCount} paragraphs on the page`);

  // Programmatically select text across paragraphs 1-5
  console.log('Selecting text across all paragraphs...');
  const selectionResult = await page.evaluate(() => {
    const paragraphs = document.querySelectorAll('.paragraph-text');

    if (paragraphs.length < 2) {
      return { error: `Only found ${paragraphs.length} paragraphs, need at least 2` };
    }

    // Get the first and last paragraph text elements
    const firstParagraph = paragraphs[0];
    const lastParagraph = paragraphs[paragraphs.length - 1];

    // Find the actual text content within these paragraphs
    const firstTextNode = findFirstTextNode(firstParagraph);
    const lastTextNode = findLastTextNode(lastParagraph);

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
    { pattern: /⏱️\s*\d+[:.]\d+\s*-\s*\d+[:.]\d+/, name: 'Timestamps (e.g., "⏱️ 0:00 - 0:03")' },
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
