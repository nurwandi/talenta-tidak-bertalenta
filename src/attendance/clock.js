import { humanClick, randomDelay } from '../browser/stealth-utils.js';

// Maps action -> button label. Success is HTTP 201 on attendance_clocks POST.
const BUTTON = { 'clock-in': 'Clock In', 'clock-out': 'Clock Out' };

async function clockOnce(page, action, log) {
  const label = BUTTON[action];
  log.start(`Navigating to Live Attendance for ${label}...`);
  await page.goto('https://hr.talenta.co/live-attendance', { waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(randomDelay(2000, 4000));

  log.info(`Waiting for ${label} button...`);
  const button = page.getByRole('button', { name: label, exact: true });
  await button.waitFor({ state: 'visible', timeout: 20000 });

  const responsePromise = page.waitForResponse(
    (resp) => resp.url().includes('attendance_clocks') && resp.request().method() === 'POST',
    { timeout: 30000 }
  );

  log.info(`Clicking ${label} button...`);
  await humanClick(page, button);

  const response = await responsePromise;
  const data = await response.json();
  if (response.status() === 201) {
    log.success(`${label} berhasil! ID: ${data.data?.id}`);
    return true;
  }
  log.error(`${label} gagal: ${JSON.stringify(data)}`);
  return false;
}

export async function runClock(page, action, log) {
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      log.info(`${action} attempt ${attempt}/3`);
      if (await clockOnce(page, action, log)) return true;
    } catch (error) {
      log.error(`Attempt ${attempt} error: ${error.message}`);
      await page.waitForTimeout(2000);
    }
  }
  return false;
}
