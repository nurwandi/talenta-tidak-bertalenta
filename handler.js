import { launchStealthBrowser } from './src/browser/stealth-utils.js';
import { ensureLoggedIn, logout } from './src/attendance/auth.js';
import { runClock } from './src/attendance/clock.js';
import { createLogger } from './src/core/logger.js';

const log = createLogger('HANDLER');

// Day-of-week geolocation, evaluated in Asia/Jakarta. Schedules only fire Mon-Fri.
function geoForToday() {
  const dow = new Date().toLocaleDateString('en-US', { weekday: 'short', timeZone: 'Asia/Jakarta' });
  if (dow === 'Mon' || dow === 'Fri') {
    return { lat: '-6.2118931', lng: '106.8264782', label: 'Home (Mon/Fri)' };
  }
  return { lat: '-6.1993335', lng: '106.7623687', label: 'Default Office (Tue-Thu)' };
}

function nowWIB() {
  return new Date().toLocaleString('id-ID', {
    timeZone: 'Asia/Jakarta', day: '2-digit', month: '2-digit', year: 'numeric',
    hour: '2-digit', minute: '2-digit',
  });
}

async function notifyDiscord({ action, success, geo, elapsedSec, shot }) {
  const url = process.env.DISCORD_WEBHOOK_URL;
  if (!url) return;
  const userId = process.env.DISCORD_USER_ID || '';
  const mention = userId ? ` <@${userId}>` : '';
  const title = action === 'clock-in' ? 'Clock In' : 'Clock Out';
  const when = nowWIB();
  const duration = `${Math.floor(elapsedSec / 60)}m ${elapsedSec % 60}s`;
  const embed = {
    title: `${success ? '✅' : '❌'} ${title} ${success ? 'Successful' : 'Failed!'}`,
    color: success ? 5763719 : 15548997,
    fields: [
      { name: 'Status', value: success ? 'success' : 'failure', inline: true },
      { name: 'Date', value: `${when} WIB`, inline: true },
      { name: 'Location', value: geo.label, inline: true },
      { name: 'Duration', value: duration, inline: true },
    ],
  };
  const payload = {
    content: `${title} ${success ? 'successful' : 'failed'} at ${when} WIB${mention}`,
    embeds: [embed],
  };

  if (!success && shot) {
    const form = new FormData();
    form.append('payload_json', JSON.stringify(payload));
    form.append('files[0]', new Blob([shot], { type: 'image/png' }), 'error.png');
    await fetch(url, { method: 'POST', body: form });
  } else {
    await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
  }
}

export async function handler(event) {
  const action = event?.action;
  if (action !== 'clock-in' && action !== 'clock-out') {
    throw new Error(`invalid action: ${JSON.stringify(action)}`);
  }
  const start = Date.now();
  const geo = geoForToday();
  process.env.GEO_LAT = geo.lat;
  process.env.GEO_LNG = geo.lng;

  const { browser, page } = await launchStealthBrowser();
  let success = false;
  let shot = null;
  try {
    await ensureLoggedIn(page, log);
    success = await runClock(page, action, log);
  } catch (error) {
    log.error(`Fatal error: ${error.message}`);
  }
  if (!success) {
    try { shot = await page.screenshot(); } catch { /* page may be gone */ }
  }
  try { await logout(page, log); } catch { /* best effort */ }
  await browser.close();

  await notifyDiscord({ action, success, geo, elapsedSec: Math.round((Date.now() - start) / 1000), shot });

  if (!success) throw new Error(`${action} failed`);
  return { ok: true };
}
