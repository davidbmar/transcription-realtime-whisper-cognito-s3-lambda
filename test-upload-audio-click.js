const { chromium } = require('playwright');

(async () => {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext();
  const page = await context.newPage();

  console.log('Navigating to CloudDrive...');
  await page.goto('https://d2l28rla2hk7np.cloudfront.net/index.html');
  await page.screenshot({ path: 'screenshot-1-initial.png' });

  // Click login button
  console.log('Clicking login...');
  await page.click('text=Sign In with Cognito');
  await page.waitForTimeout(2000);
  await page.screenshot({ path: 'screenshot-2-cognito.png' });

  // Fill credentials
  console.log('Filling credentials...');
  await page.fill('input[name="username"]', 'david.bryan.mar@gmail.com');
  await page.fill('input[name="password"]', process.env.CLOUDDRIVE_TEST_PASSWORD);
  await page.click('input[type="submit"]');

  // Wait for dashboard
  console.log('Waiting for dashboard...');
  await page.waitForTimeout(3000);
  await page.screenshot({ path: 'screenshot-3-dashboard.png' });

  // Check if dashboard is visible
  const dashboardVisible = await page.isVisible('#dashboard-section');
  console.log('Dashboard visible:', dashboardVisible);

  // Check if upload audio card exists
  const uploadCardExists = await page.locator('text=Upload Audio').count();
  console.log('Upload Audio cards found:', uploadCardExists);

  // Try to click Upload Audio card
  console.log('Clicking Upload Audio card...');
  await page.click('.dashboard-card:has-text("Upload Audio")');
  await page.waitForTimeout(2000);
  await page.screenshot({ path: 'screenshot-4-after-click.png' });

  // Check what's visible now
  const uploadSectionVisible = await page.isVisible('#upload-audio-section');
  const dashboardStillVisible = await page.isVisible('#dashboard-section');

  console.log('After click:');
  console.log('  - Upload section visible:', uploadSectionVisible);
  console.log('  - Dashboard still visible:', dashboardStillVisible);

  // Check for JavaScript errors
  page.on('console', msg => console.log('Browser console:', msg.text()));
  page.on('pageerror', error => console.log('Page error:', error.message));

  await page.waitForTimeout(5000);
  await browser.close();
})();
