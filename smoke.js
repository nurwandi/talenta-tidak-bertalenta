// Local smoke test: runs a real clock against Talenta with a headed browser.
// Usage: HEADLESS=false TALENTA_EMAIL=.. TALENTA_PASSWORD=.. node smoke.js clock-in
import { launchStealthBrowser } from './src/browser/stealth-utils.js';
import { ensureLoggedIn, logout } from './src/attendance/auth.js';
import { runClock } from './src/attendance/clock.js';
import { createLogger } from './src/core/logger.js';

const log = createLogger('SMOKE');
const action = process.argv[2] || 'clock-in';

const { browser, page } = await launchStealthBrowser();
try {
  await ensureLoggedIn(page, log);
  const ok = await runClock(page, action, log);
  log.info(`result: ${ok}`);
} finally {
  await logout(page, log);
  await browser.close();
}
