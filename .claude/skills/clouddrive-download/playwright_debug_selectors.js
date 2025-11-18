const { chromium } = require('playwright');

(async () => {
  const browser = await chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox']
  });

  const page = await browser.newPage();

  try {
    await page.goto('https://d2l28rla2hk7np.cloudfront.net/transcript-editor-v2.html', {
      waitUntil: 'networkidle',
      timeout: 30000
    });

    // Wait a bit for page to render
    await page.waitForTimeout(2000);

    // Get the HTML content of the login section
    const loginHTML = await page.evaluate(() => {
      const loginSection = document.querySelector('#login-section');
      return loginSection ? loginSection.innerHTML : 'Login section not found';
    });

    console.log('=== LOGIN SECTION HTML ===');
    console.log(loginHTML);

    // Get all input fields
    const inputs = await page.evaluate(() => {
      const allInputs = Array.from(document.querySelectorAll('input'));
      return allInputs.map(input => ({
        id: input.id,
        name: input.name,
        type: input.type,
        placeholder: input.placeholder,
        visible: input.offsetParent !== null
      }));
    });

    console.log('\n=== ALL INPUT FIELDS ===');
    console.log(JSON.stringify(inputs, null, 2));

    // Get all buttons
    const buttons = await page.evaluate(() => {
      const allButtons = Array.from(document.querySelectorAll('button'));
      return allButtons.map(button => ({
        id: button.id,
        textContent: button.textContent.trim(),
        visible: button.offsetParent !== null
      }));
    });

    console.log('\n=== ALL BUTTONS ===');
    console.log(JSON.stringify(buttons, null, 2));

  } catch (error) {
    console.error('Error:', error);
  } finally {
    await browser.close();
  }
})();
