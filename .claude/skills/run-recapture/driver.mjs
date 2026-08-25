// .claude/skills/run-recapture/driver.mjs
//
// Agent driver for the ReCapture Flutter app running as Flutter WEB
// (`flutter run -d web-server`). Uses the SYSTEM Chrome via playwright-core
// (channel: 'chrome') — no browser download.
//
// Flutter web renders to a <canvas>; the DOM is empty until Flutter's
// SEMANTICS tree is enabled. This driver enables it on `goto` (clicks the
// hidden flt-semantics-placeholder), after which every widget with a
// semantics label exists as a DOM node with an aria-label — that's what
// `click`/`find` match against.
//
// Usage:
//   node driver.mjs --serve [port]   serve <repo>/build/web itself (release
//                                    build — run `flutter build web` first),
//                                    then drive it. RECOMMENDED agent path.
//   node driver.mjs [url]            drive an app already served elsewhere
//                                    (default http://127.0.0.1:8642)
// Commands on stdin, one per line:
//   goto [url]         (re)open the app and enable semantics
//   ss <name>          screenshot -> shots/<name>.png
//   find <text>        list semantic nodes whose label contains <text>
//   click <text>       click the first semantic node whose label contains <text>
//   clickxy <x> <y>    raw coordinate click (for canvas-only targets)
//   type <text>        type into the focused field
//   press <key>        press a key (Enter, Tab, Backspace...)
//   tree               dump the visible semantics labels
//   eval <js>          evaluate JS in the page, print the result
//   quit               close and exit
import { chromium } from 'playwright-core';
import { createInterface } from 'node:readline';
import { mkdirSync, readFileSync, existsSync } from 'node:fs';
import { createServer } from 'node:http';
import { dirname, join, resolve, extname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const SHOTS = join(HERE, 'shots');
mkdirSync(SHOTS, { recursive: true });

// ── Optional built-in static server for the release build ────────────────────
// `flutter run -d web-server` (debug) accepts only ONE debug client per run —
// a second fresh browser hangs forever on the bundle. The release build has no
// debug service, so serving build/web statically supports unlimited launches.
let BASE = process.argv[2] ?? 'http://127.0.0.1:8642';
if (process.argv[2] === '--serve') {
  const port = Number(process.argv[3] ?? 8642);
  const root = resolve(HERE, '../../../build/web'); // <repo>/build/web
  if (!existsSync(join(root, 'index.html'))) {
    console.error(`No release build at ${root} — run \`flutter build web\` first.`);
    process.exit(1);
  }
  const MIME = {
    '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript',
    '.css': 'text/css', '.json': 'application/json', '.wasm': 'application/wasm',
    '.png': 'image/png', '.jpg': 'image/jpeg', '.svg': 'image/svg+xml',
    '.otf': 'font/otf', '.ttf': 'font/ttf', '.frag': 'text/plain',
  };
  createServer((req, res) => {
    const path = req.url.split('?')[0];
    const file = join(root, path === '/' ? 'index.html' : path);
    try {
      const body = readFileSync(file);
      res.writeHead(200, { 'Content-Type': MIME[extname(file)] ?? 'application/octet-stream' });
      res.end(body);
    } catch {
      res.writeHead(404).end('not found');
    }
  })
    .on('error', (err) => {
      if (err.code === 'EADDRINUSE') {
        // A killed `flutter run` leaves its dartvm child listening on Windows.
        console.error(
          `Port ${port} is taken (stray dartvm from an old flutter run?). ` +
            `Free it: powershell "Get-NetTCPConnection -LocalPort ${port} -State Listen | ` +
            `%{ Stop-Process -Id $_.OwningProcess -Force }"`
        );
        process.exit(1);
      }
      throw err;
    })
    .listen(port, '127.0.0.1');
  BASE = `http://127.0.0.1:${port}`;
  console.log(`serving ${root} at ${BASE}`);
}

const browser = await chromium.launch({ channel: 'chrome', headless: true });
const page = await browser.newPage({ viewport: { width: 412, height: 915 } }); // phone-ish
page.setDefaultTimeout(15000);

// Every widget with a semantics label, as [label, x, y] of its center.
async function semanticNodes() {
  return page.evaluate(() => {
    const out = [];
    for (const el of document.querySelectorAll('flt-semantics [aria-label], flt-semantics[aria-label], [id^="flt-semantic-node"]')) {
      const label = el.getAttribute('aria-label') ?? el.textContent?.trim() ?? '';
      if (!label) continue;
      const r = el.getBoundingClientRect();
      if (r.width === 0 && r.height === 0) continue;
      out.push({ label, x: r.x + r.width / 2, y: r.y + r.height / 2 });
    }
    return out;
  });
}

async function enableSemantics() {
  // The placeholder is a hidden button Flutter injects for screen readers;
  // activating it switches the app into full-semantics mode. It sits offscreen,
  // so a pointer click can miss — dispatch the DOM click event directly, then
  // poll until semantic nodes actually appear.
  for (let attempt = 0; attempt < 5; attempt++) {
    await page.evaluate(() => {
      const ph = document.querySelector('flt-semantics-placeholder');
      if (ph) ph.dispatchEvent(new MouseEvent('click', { bubbles: true }));
    });
    await page.waitForTimeout(1500);
    const count = await page.evaluate(
      () => document.querySelectorAll('flt-semantics, [id^="flt-semantic-node"]').length
    );
    if (count > 0) return;
  }
  console.log('WARN: semantics tree never appeared — click/find will not work');
}

async function goto(url) {
  await page.goto(url ?? BASE, { waitUntil: 'load' });
  // Flutter bootstraps after 'load'. The DEBUG web build is big — a cold
  // browser profile can take well over a minute to fetch + start the engine.
  await page.waitForSelector('flt-glass-pane, flutter-view, flt-scene-host', {
    timeout: 180000,
  });
  await page.waitForTimeout(2500); // first frame + splash settle
  await enableSemantics();
  console.log('OK loaded', url ?? BASE);
}

async function clickLabel(text) {
  const nodes = await semanticNodes();
  // Ancestor containers concatenate all child labels, so several nodes match
  // any text — the SHORTEST matching label is the most specific widget.
  const hit = nodes
    .filter((n) => n.label.toLowerCase().includes(text.toLowerCase()))
    .sort((a, b) => a.label.length - b.label.length)[0];
  if (!hit) {
    console.log(`NOT FOUND: "${text}" — try 'tree' to see labels`);
    return;
  }
  await page.mouse.click(hit.x, hit.y);
  await page.waitForTimeout(800); // let navigation/animation settle
  console.log(`OK clicked "${hit.label}" @ ${Math.round(hit.x)},${Math.round(hit.y)}`);
}

const rl = createInterface({ input: process.stdin });
console.log(`driver ready — app expected at ${BASE}. Type commands:`);
for await (const line of rl) {
  const [cmd, ...rest] = line.trim().split(' ');
  const arg = rest.join(' ');
  try {
    switch (cmd) {
      case 'goto': await goto(arg || undefined); break;
      case 'ss': {
        const file = join(SHOTS, `${arg || 'shot'}.png`);
        await page.screenshot({ path: file });
        console.log('OK screenshot', file);
        break;
      }
      case 'find': {
        const nodes = await semanticNodes();
        const hits = nodes.filter((n) => n.label.toLowerCase().includes(arg.toLowerCase()));
        console.log(hits.length ? hits.map((n) => `- ${n.label}`).join('\n') : '(none)');
        break;
      }
      case 'click': await clickLabel(arg); break;
      case 'clickxy': {
        const [x, y] = rest.map(Number);
        await page.mouse.click(x, y);
        await page.waitForTimeout(800);
        console.log(`OK clicked ${x},${y}`);
        break;
      }
      // Generous delays: fields that auto-advance focus per character (the OTP
      // boxes) drop keystrokes typed faster than the focus hop.
      case 'type': await page.keyboard.type(arg, { delay: 120 }); console.log('OK typed'); break;
      case 'press':
        await page.keyboard.press(arg);
        await page.waitForTimeout(350);
        console.log('OK pressed', arg);
        break;
      case 'tree': {
        const nodes = await semanticNodes();
        console.log(nodes.map((n) => `- ${n.label}`).join('\n') || '(empty — did goto run?)');
        break;
      }
      // Paste-style input: the whole string arrives as ONE input event. Use for
      // fields that drop fast keystrokes (the OTP boxes) — the app handles it
      // as SMS-autofill/paste.
      case 'insert': await page.keyboard.insertText(arg); console.log('OK inserted'); break;
      case 'wait': await page.waitForTimeout(Number(arg) || 500); console.log('OK waited'); break;
      case 'eval': console.log(JSON.stringify(await page.evaluate(arg))); break;
      case 'quit': await browser.close(); process.exit(0); break;
      case '': break;
      default: console.log('unknown command:', cmd);
    }
  } catch (err) {
    console.log('ERROR:', err.message?.split('\n')[0]);
  }
  console.log('<done>'); // sentinel so callers know the command finished
}
