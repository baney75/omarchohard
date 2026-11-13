// The remote sign-in page in a real browser, against a live session:
//
//   omarchohard native signin --remote --port 6081 > out
//   OH_URL="$(sed -n 's/^Sign in here: //p' out)" CHROME=/path/to/chrome \
//     node tests/live/signin-page.cjs
//
// Needs playwright-core (npm i playwright-core) and a Chromium. At a desktop
// (1280x860) and a phone (390x844) size it checks that the page connects,
// that the shared picture is a window (the sign-in dialog), not the whole
// hidden screen, and that the password is gone from the address bar. The
// link comes from OH_URL, not the command line, so ps never shows it. Not
// part of the bats suite: it needs Office, Wine and a running session.
const { chromium } = require('playwright-core');
(async () => {
  const b = await chromium.launch({ executablePath: process.env.CHROME, args: ['--disable-gpu'] });
  let bad = 0;
  for (const [w, h, name] of [[1280, 860, 'desk'], [390, 844, 'phone']]) {
    const p = await b.newPage({ viewport: { width: w, height: h }, deviceScaleFactor: name === 'phone' ? 2 : 1 });
    p.on('pageerror', e => { console.log(name, 'pageerror', e.message); bad++; });
    await p.goto(process.env.OH_URL);
    await p.waitForTimeout(8000);
    const r = await p.evaluate(() => {
      const c = document.querySelector('#screen canvas');
      const s = document.querySelector('#screen');
      return { status: document.querySelector('#status').textContent, href: location.href,
               fb: c ? [c.width, c.height] : null, card: [s.clientWidth, s.clientHeight] };
    });
    const leaked = r.href.includes('#') || r.href.includes('pw=');
    console.log(name, 'status:', r.status, '| framebuffer', JSON.stringify(r.fb), '| card', JSON.stringify(r.card), '| fragment gone:', !leaked);
    // The hidden screen is 1000x720; a smaller picture is the dialog alone.
    const whole = r.fb && r.fb[0] >= 1000 && r.fb[1] >= 720;
    if (!r.status.startsWith('Connected') || leaked || !r.fb || whole) bad++;
    await p.screenshot({ path: (process.env.OH_SHOT || 'signin-page') + '-' + name + '.png' });
  }
  await b.close();
  process.exit(bad ? 1 : 0);
})();
