export async function ensureLoggedIn(page, log) {
  log.start('Navigating to Talenta...');
  await page.goto('https://hr.talenta.co/live-attendance', { waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(3000);

  // Check if login form exists (means not logged in yet)
  const emailInput = page.locator('input[type="email"], input[name="email"]');
  const isLoginPage = await emailInput.isVisible({ timeout: 5000 }).catch(() => false);

  if (!isLoginPage) {
    log.info('Already logged in, skipping login...');
    return;
  }

  // Read credentials once, then wipe from env immediately after use
  const email = process.env.TALENTA_EMAIL;
  const password = process.env.TALENTA_PASSWORD;

  log.info('Filling credentials...');
  await page.fill('input[type="email"], input[name="email"]', email);
  await page.locator('input[type="password"]').first().fill(password);

  // Wipe credentials from environment immediately after filling form
  delete process.env.TALENTA_EMAIL;
  delete process.env.TALENTA_PASSWORD;
  log.info('Credentials wiped from environment');

  log.start('Signing in...');
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();

  // Wait for login form to disappear (means login succeeded)
  log.info('Waiting for login to complete...');
  await emailInput.waitFor({ state: 'hidden', timeout: 30000 });
  await page.waitForTimeout(2000);
  log.success('Login successful');
}

export async function logout(page, log) {
  try {
    log.start('Logging out...');

    // Try navigating to logout URL directly (most reliable)
    await page.goto('https://hr.talenta.co/site/sign-out', { waitUntil: 'domcontentloaded', timeout: 15000 });
    await page.waitForTimeout(2000);

    // Verify we're back at login page
    const emailInput = page.locator('input[type="email"], input[name="email"]');
    const isLoginPage = await emailInput.isVisible({ timeout: 5000 }).catch(() => false);

    if (isLoginPage) {
      log.success('Logout berhasil');
    } else {
      log.warn('Logout mungkin belum berhasil, tapi browser akan ditutup');
    }
  } catch (error) {
    log.warn(`Logout error: ${error.message}, browser akan tetap ditutup`);
  }

  // Clear all browser storage to remove session tokens and cookies
  await clearBrowserData(page, log);
}

export async function clearBrowserData(page, log) {
  try {
    log.start('Clearing browser data...');
    const context = page.context();

    // Clear all cookies
    await context.clearCookies();

    // Clear localStorage and sessionStorage
    await page.evaluate(() => {
      try { localStorage.clear(); } catch { }
      try { sessionStorage.clear(); } catch { }
    });

    log.success('Browser data cleared');
  } catch (error) {
    log.warn(`Clear browser data error: ${error.message}`);
  }
}