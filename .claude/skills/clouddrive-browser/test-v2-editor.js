const { chromium } = require('playwright');

const CLOUDFRONT_URL = process.env.COGNITO_CLOUDFRONT_URL;
const EMAIL = process.env.CLOUDDRIVE_TEST_EMAIL;
const PASSWORD = process.env.CLOUDDRIVE_TEST_PASSWORD;

(async () => {
    const browser = await chromium.launch({ headless: true });
    const context = await browser.newContext();
    const page = await context.newPage();

    // Capture all console logs
    const logs = [];
    page.on('console', msg => {
        logs.push({ type: msg.type(), text: msg.text() });
    });

    page.on('pageerror', err => {
        logs.push({ type: 'PAGE_ERROR', text: err.message });
    });

    // Login first
    console.log('Logging in...');
    await page.goto(CLOUDFRONT_URL + '/index.html');
    await page.waitForTimeout(2000);
    await page.fill('#username', EMAIL);
    await page.fill('#password', PASSWORD);
    await page.click('button[type="submit"]');
    await page.waitForTimeout(3000);

    // Navigate to v2 editor
    const editorUrl = CLOUDFRONT_URL + '/transcript-editor-v2.html?sessionId=20251122-203801-upload-f85732b56619';
    console.log('Loading v2 editor:', editorUrl);
    await page.goto(editorUrl);

    // Wait for loading
    await page.waitForTimeout(12000);

    // Check results
    console.log('\n=== Console Logs ===');
    logs.filter(l =>
        l.text.includes('segment') ||
        l.text.includes('paragraph') ||
        l.text.includes('Processed') ||
        l.text.includes('Converting') ||
        l.text.includes('stats') ||
        l.type === 'error' ||
        l.type === 'PAGE_ERROR'
    ).forEach(l => console.log('[' + l.type + '] ' + l.text.substring(0, 200)));

    // Check for error message
    const errorText = await page.evaluate(() => {
        const el = document.querySelector('.error-message');
        return el && el.offsetParent !== null ? el.innerText : null;
    });

    if (errorText) {
        console.log('\n=== ERROR ===');
        console.log(errorText);
    }

    // Check for transcript content
    const hasTranscript = await page.evaluate(() => {
        const editor = document.querySelector('.transcript-editor');
        const paragraphs = document.querySelectorAll('.paragraph');
        return {
            editorVisible: editor && editor.offsetParent !== null,
            paragraphCount: paragraphs.length,
            firstParagraphText: paragraphs[0]?.innerText?.substring(0, 100)
        };
    });

    console.log('\n=== Results ===');
    console.log('Editor visible:', hasTranscript.editorVisible);
    console.log('Paragraph count:', hasTranscript.paragraphCount);
    console.log('First paragraph:', hasTranscript.firstParagraphText);

    // Take screenshot
    await page.screenshot({ path: '/tmp/v2-editor-test.png', fullPage: false });
    console.log('\nScreenshot saved to /tmp/v2-editor-test.png');

    await browser.close();
})();
