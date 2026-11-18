// `npm run pair`: makes the codes that connect your glasses and phone to this PC.
// Writes a local page (bridge/.state/pair.html) with two QR codes. The page
// holds long-lived tokens: keep it on this PC and do not share screenshots of it.
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import QRCode from 'qrcode';
import { STATE_DIR, loadConfig, loadEnv } from './config.ts';
import { clientUrl } from './tokens.ts';

loadEnv();
const cfg = loadConfig();

const b64url = (s: string) => Buffer.from(s, 'utf8').toString('base64url');
const lensBase = cfg.lensUrl ?? (cfg.relay === 'dev' ? 'http://localhost:5173/' : undefined);
if (!lensBase) {
  console.error('Set "lensUrl" in bridge/config.json to where the lens web app is hosted (for example your GitHub Pages address).');
  process.exit(1);
}

const lensToken = b64url(await clientUrl(cfg, 'lens'));
const base = lensBase.endsWith('/') ? lensBase : `${lensBase}/`;
const lensLink = `${base}?r=${lensToken}`;
const probeLink = `${base}probe/index.html?r=${lensToken}`;
// The Meta AI app only keeps the query string when the whole app URL is encoded.
const install = (name: string, url: string) =>
  `fb-viewapp://web_app_deep_link?appName=${encodeURIComponent(name)}&appUrl=${encodeURIComponent(url)}`;
const lensInstall = install('Stride', lensLink);
const probeInstall = install('Stride probe', probeLink);
const phoneLink = `stride://pair?r=${b64url(await clientUrl(cfg, 'phone'))}`;
const expires = new Date(Date.now() + cfg.deviceTokenDays * 86_400_000).toISOString().slice(0, 10);

if (cfg.relay === 'dev') {
  console.log('\nDev relay: open the lens in a desktop browser on this PC:\n');
  console.log(`  ${lensLink}\n`);
  console.log('Probe page (what the glasses\' browser allows):\n');
  console.log(`  ${probeLink}\n`);
  process.exit(0);
}

const qr = (text: string) => QRCode.toString(text, { type: 'svg', errorCorrectionLevel: 'L', margin: 2 });
const page = `<!doctype html>
<meta charset="utf-8">
<title>Stride pairing</title>
<style>
  body { font: 16px/1.5 system-ui, sans-serif; background: #111; color: #eee; margin: 0; padding: 40px; }
  main { display: grid; grid-template-columns: repeat(auto-fit, minmax(340px, 1fr)); gap: 40px; max-width: 980px; margin: auto; }
  section { background: #1b1b1b; border-radius: 16px; padding: 28px; }
  h1 { font-size: 20px; margin: 0 0 6px; } p { margin: 0 0 16px; color: #aaa; }
  svg { width: 100%; height: auto; background: #fff; border-radius: 12px; }
  footer { max-width: 980px; margin: 28px auto 0; color: #888; font-size: 14px; }
</style>
<main>
  <section>
    <h1>0. First-time check (probe)</h1>
    <p>Scan this one first. It adds a test page that shows what your glasses allow and reports the results to this PC (bridge/logs/lens.log).</p>
    ${await qr(probeInstall)}
  </section>
  <section>
    <h1>1. Glasses</h1>
    <p>Scan with the iPhone camera. The Meta AI app opens and adds Stride as a web app (Developer Mode must be on).</p>
    ${await qr(lensInstall)}
  </section>
  <section>
    <h1>2. iPhone voice engine</h1>
    <p>Scan with the iPhone camera once the Stride app is installed. It opens the app and pairs it.</p>
    ${await qr(phoneLink)}
  </section>
</main>
<footer>These codes work until ${expires}. They let a device talk to Claude on this PC: treat them like a password. Run “npm run pair” again to renew; regenerate the Web PubSub key in Azure to revoke every device at once.</footer>
`;

const file = join(STATE_DIR, 'pair.html');
writeFileSync(file, page);
console.log(`\nPairing page written. Open it in a browser on this PC and scan the codes:\n\n  ${pathToFileURL(file).href}\n\nValid until ${expires}.\n`);
