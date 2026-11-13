// The remote sign-in page in a real browser, against a live session:
//
//   omarchohard native signin --remote --port 6081 > out
//   OH_URL="$(sed -n 's/^Sign in here: //p' out)" CHROME=/path/to/chrome \
//     OH_EMAIL=someone@example.com node tests/live/signin-page.cjs
//
// Needs playwright-core (npm i playwright-core) and a Chromium. At a phone
// size (390x844) it checks that the page connects, shows the title and the
// email field, takes the session id out of the address bar, and shows the
// busy state once an email is entered. It enters only the email, so the
// session moves on to Microsoft's own page; it never types a password, and
// the session is used up afterward (omarchohard native signin --stop). The
// link comes from OH_URL, not the command line, so ps never shows it. Not
// part of the bats suite: it needs Office, Wine and a running session.
const { chromium } = require('playwright-core');
(async () => {
  const url = process.env.OH_URL || '';
  if (!/#s=[0-9a-f]{48}$/.test(url)) {
    console.log('OH_URL must be the sign-in link, ending in #s= and 48 hex characters');
    process.exit(2);
  }
  const email = process.env.OH_EMAIL || 'someone@example.com';
  const b = await chromium.launch({ executablePath: process.env.CHROME, args: ['--disable-gpu'] });
  let bad = 0;
  const p = await b.newPage({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true });
  p.on('pageerror', e => { console.log('pageerror', e.message); bad++; });
  await p.goto(url);
  const field = p.locator('#email');
  try {
    await field.waitFor({ state: 'visible', timeout: 15000 });
  } catch (e) {
    console.log('no email field:', e.message);
    bad++;
  }
  const title = await p.locator('#s-email h1').textContent().catch(() => '');
  const href = p.url();
  const leaked = href.includes('#') || href.includes('s=');
  console.log('title:', JSON.stringify(title), '| tab:', JSON.stringify(await p.title()), '| fragment gone:', !leaked);
  if (title !== 'Sign in to Microsoft 365' || (await p.title()) !== 'Sign in to Microsoft 365' || leaked) bad++;
  if (!bad) {
    await field.fill(email);
    await p.locator('#go').click();
    let busy = false;
    try {
      await p.waitForFunction(() => document.querySelector('#go').disabled &&
        document.querySelector('#go').textContent.includes('Getting Office ready'), null, { timeout: 5000 });
      busy = true;
    } catch (e) {
      bad++;
    }
    console.log('busy state after the email:', busy);
  }
  await p.screenshot({ path: (process.env.OH_SHOT || 'signin-page') + '-phone.png' });
  await b.close();
  process.exit(bad ? 1 : 0);
})();
