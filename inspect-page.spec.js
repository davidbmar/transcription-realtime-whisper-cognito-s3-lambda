const { chromium } = require('playwright');

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();

  console.log('Navigating to transcript editor page...');
  await page.goto('https://d2l28rla2hk7np.cloudfront.net/transcript-editor-v2.html');

  console.log('Waiting for page to fully load...');
  await page.waitForLoadState('networkidle');

  // Wait a bit for content to render
  await page.waitForTimeout(5000);

  console.log('Taking screenshot...');
  await page.screenshot({ path: '/home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/page-inspection.png', fullPage: true });

  console.log('Inspecting page structure...');
  const pageInfo = await page.evaluate(() => {
    // Look for various possible selectors
    const body = document.body.innerHTML;
    const title = document.title;
    const buildComment = Array.from(document.head.childNodes)
      .filter(node => node.nodeType === Node.COMMENT_NODE)
      .map(node => node.textContent.trim())
      .join(', ');

    return {
      title,
      buildComment,
      bodyLength: body.length,
      bodyPreview: body.substring(0, 2000),
      paragraphContainers: document.querySelectorAll('.paragraph-container').length,
      paragraphTexts: document.querySelectorAll('.paragraph-text').length,
      transcriptDivs: document.querySelectorAll('[class*="transcript"]').length,
      allDivs: document.querySelectorAll('div').length,
      allIds: Array.from(document.querySelectorAll('[id]')).map(el => el.id).slice(0, 30),
      allClasses: Array.from(new Set(
        Array.from(document.querySelectorAll('[class]'))
          .flatMap(el => Array.from(el.classList))
      )).slice(0, 50)
    };
  });

  console.log('\n=== PAGE STRUCTURE INFO ===');
  console.log('Title:', pageInfo.title);
  console.log('Build comment:', pageInfo.buildComment);
  console.log('Body length:', pageInfo.bodyLength);
  console.log('Paragraph containers (.paragraph-container):', pageInfo.paragraphContainers);
  console.log('Paragraph texts (.paragraph-text):', pageInfo.paragraphTexts);
  console.log('Elements with "transcript" in class:', pageInfo.transcriptDivs);
  console.log('Total divs:', pageInfo.allDivs);
  console.log('\nAll IDs found (first 30):', pageInfo.allIds);
  console.log('\nAll classes found (first 50):', pageInfo.allClasses);
  console.log('\n=== BODY PREVIEW (first 2000 chars) ===');
  console.log(pageInfo.bodyPreview);

  await browser.close();
})();
