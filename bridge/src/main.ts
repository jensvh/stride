// Entry point: `npm run bridge`.
import { appendFileSync } from 'node:fs';
import { join } from 'node:path';
import { RelayClient } from '../../protocol/relayClient.ts';
import { GROUP_DOWN, GROUP_UP, type Down } from '../../protocol/schema.ts';
import { Bridge } from './bridge.ts';
import { LOG_DIR, loadConfig, loadEnv } from './config.ts';
import { startDevRelay } from './devRelay.ts';
import { clientUrl, devKey } from './tokens.ts';

loadEnv();
const cfg = loadConfig();

const stamp = () => new Date().toISOString().slice(11, 19);
const day = () => new Date().toISOString().slice(0, 10);
const append = (file: string, line: string) => {
  try {
    appendFileSync(join(LOG_DIR, file), `${line}\n`);
  } catch {
    // logging must never take the bridge down
  }
};
const log = (msg: string) => {
  console.log(`${stamp()} ${msg}`);
  append('bridge.log', `${day()} ${stamp()} ${msg}`);
};

if (cfg.relay === 'dev') startDevRelay(cfg.devRelayPort, devKey(), log);

// Azure's free tier allows 20,000 messages a day; say so before it runs out.
const FREE_DAILY = 20_000;
let quotaDay = day();
let quotaUsed = 0;
const meter = () => {
  if (day() !== quotaDay) {
    quotaDay = day();
    quotaUsed = 0;
  }
  quotaUsed++;
  if (cfg.relay === 'azure' && [0.5, 0.75, 0.9].some((f) => quotaUsed === Math.floor(FREE_DAILY * f))) {
    log(`relay quota: ${quotaUsed} of ${FREE_DAILY} messages used today`);
  }
};

let bridge: Bridge | undefined;

const relay = new RelayClient({
  url: () => clientUrl(cfg, 'bridge'),
  join: [GROUP_UP],
  onMessage: (group, data, from) => {
    if (group === GROUP_UP) bridge?.onUp(data, from);
  },
  onStatus: (s) => {
    log(`relay ${s}`);
    if (s === 'open') bridge?.onRelayOpen();
  },
  log,
});

bridge = new Bridge({
  cfg,
  send: (msg: Down) => {
    if (relay.send(GROUP_DOWN, msg)) meter();
  },
  log,
  walkLog: (who, text) => append(`walk-${day()}.md`, `- ${stamp().slice(0, 5)} **${who}** ${text.replace(/\s+/g, ' ')}`),
  deviceLog: (device, level, msg) => append(`${device}.log`, `${day()} ${stamp()} ${level} ${msg}`),
});

log(`stride bridge: ${cfg.projects.length} project(s), relay "${cfg.relay}", lens prompting ${cfg.lensCanPrompt ? 'on' : 'off'}`);
relay.start();

setInterval(() => bridge?.tick(), 10_000);
// The relay can die silently (sleeping network, NAT timeout): check it and reconnect.
setInterval(() => {
  if (!relay.isOpen) return;
  void relay.probe().then((ok) => {
    if (!ok && relay.isOpen) {
      log('relay probe failed, reconnecting');
      relay.reconnect();
    }
  });
}, 30_000);

const stop = () => {
  log('stopping');
  bridge?.shutdown();
  relay.stop();
  process.exit(0);
};
process.on('SIGINT', stop);
process.on('SIGTERM', stop);
