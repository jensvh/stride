// Stand-in for a device, for testing from the PC:
//   npm run say -- "what does this project do"
//   npm run say -- --cmd status
//   npm run say -- --watch
// Options: --auto approve|deny   answer approval requests automatically
//          --pick N              answer choice requests with option N
//          --as cli|phone|lens   identity to connect as (default cli)
//          --timeout S           give up after S seconds (default 900)
import { createInterface } from 'node:readline/promises';
import { RelayClient } from '../../protocol/relayClient.ts';
import { Device, Down, GROUP_DOWN, GROUP_UP, type State, type Up } from '../../protocol/schema.ts';
import { loadConfig, loadEnv } from './config.ts';
import { clientUrl } from './tokens.ts';

const args = process.argv.slice(2);
const flag = (name: string) => {
  const i = args.indexOf(`--${name}`);
  if (i < 0) return undefined;
  const value = args[i + 1];
  args.splice(i, 2);
  return value;
};
const has = (name: string) => {
  const i = args.indexOf(`--${name}`);
  if (i < 0) return false;
  args.splice(i, 1);
  return true;
};

const watch = has('watch');
const cmd = flag('cmd');
const auto = flag('auto');
const pick = Number(flag('pick') ?? 0);
const as = Device.parse(flag('as') ?? 'cli');
const timeoutS = Number(flag('timeout') ?? 900);
const text = args.join(' ').trim();

if (!watch && !cmd && !text) {
  console.error('usage: npm run say -- "your words"   |   --cmd stop|status|repeat|undo|new|switch <name>   |   --watch');
  process.exit(2);
}

loadEnv();
const cfg = loadConfig();

let last: State | undefined;
let sent = false;
let sawResponse = false;
let quiet: ReturnType<typeof setTimeout> | undefined;
let answering = false;
const startCard = { id: undefined as string | undefined, known: false };

const up = (m: Up) => relay.send(GROUP_UP, m);

const finishSoon = () => {
  if (watch) return;
  if (quiet) clearTimeout(quiet);
  quiet = setTimeout(() => {
    if (sent && sawResponse && last?.phase === 'idle' && !answering) {
      relay.stop();
      process.exit(0);
    }
  }, 1500);
};

const describe = (s: State) => {
  const bits: string[] = [`[${s.project}] ${s.phase}`];
  if (s.phase === 'listening' && s.transcript) bits.push(`"${s.transcript}"`);
  if (s.phase === 'working' && s.activity) bits.push(s.activity);
  if (s.note) bits.push(`(${s.note})`);
  return bits.join('  ');
};

async function answerAsk(s: State): Promise<void> {
  const ask = s.ask!;
  console.log(`\n  ? ${ask.title}${ask.detail ? `\n    ${ask.detail}` : ''}`);
  ask.options?.forEach((o, i) => console.log(`    ${i + 1}. ${o.label}${o.description ? ` — ${o.description}` : ''}`));
  let choice: string | undefined;
  let extra: string | undefined;
  if (ask.kind === 'approve' && auto) choice = auto === 'approve' ? 'approve' : 'deny';
  else if (ask.kind === 'choice' && pick && ask.options?.[pick - 1]) choice = ask.options[pick - 1]!.label;
  else {
    answering = true;
    const rl = createInterface({ input: process.stdin, output: process.stdout });
    const reply = (await rl.question(ask.kind === 'approve' ? '  approve / deny [reason] > ' : '  number or text > ')).trim();
    rl.close();
    answering = false;
    if (ask.kind === 'approve') {
      const yes = /^(a|approve|y)$/i.test(reply);
      choice = yes ? 'approve' : 'deny';
      extra = yes ? undefined : reply.replace(/^(d|deny|n|no)\b[\s,:-]*/i, '') || undefined;
    } else {
      choice = ask.options?.[Number(reply) - 1]?.label ?? reply;
    }
  }
  console.log(`  -> ${choice}${extra ? ` (${extra})` : ''}`);
  up({ v: 1, t: 'answer', askId: ask.id, choice, ...(extra ? { text: extra } : {}) });
}

let lastLine = '';
let lastAskId: string | undefined;
let lastCardId: string | undefined;

const relay = new RelayClient({
  url: () => clientUrl(cfg, as),
  join: [GROUP_DOWN],
  onStatus: (s) => {
    if (s !== 'open') return;
    up({ v: 1, t: 'hello', device: as, app: 'say' });
  },
  onMessage: (_group, data) => {
    const parsed = Down.safeParse(data);
    if (!parsed.success) return;
    const m = parsed.data;
    if (m.t === 'speak') {
      console.log(`  🔊 (${m.to}) ${m.text}`);
      if (sent) sawResponse = true;
      return finishSoon();
    }
    if (m.t === 'listen') {
      console.log(`  🎤 listen ${m.on ? 'on' : 'off'}`);
      return;
    }
    if (m.t !== 'state') return;
    const s = m.state;
    last = s;

    if (!startCard.known) {
      startCard.known = true;
      startCard.id = s.card?.id;
      lastCardId = s.card?.id;
    }
    // First state after hello: now it is safe to send.
    if (!sent && !watch) {
      sent = true;
      if (cmd) up({ v: 1, t: 'command', name: cmd as never, ...(text ? { arg: text } : {}) });
      else up({ v: 1, t: 'prompt', id: crypto.randomUUID().slice(0, 8), text });
      console.log(`> ${cmd ? `[${cmd}] ${text}` : text}`);
    }

    const line = describe(s);
    if (line !== lastLine) {
      console.log(`  ${line}`);
      lastLine = line;
    }
    if (s.live) console.log(`  ▣ live graphic: ${s.live.visual.type}${s.live.title ? ` "${s.live.title}"` : ''}`);
    if (s.ask && s.ask.id !== lastAskId) {
      lastAskId = s.ask.id;
      void answerAsk(s);
    }
    if (s.card && s.card.id !== lastCardId) {
      lastCardId = s.card.id;
      const c = s.card;
      console.log(`\n  ┌ ${c.kind.toUpperCase()}: ${c.title}`);
      for (const l of c.lines) console.log(`  │ ${l}`);
      if (c.visual) console.log(`  │ [${c.visual.type}] ${JSON.stringify(c.visual).slice(0, 200)}`);
      if (c.stats) console.log(`  └ ${JSON.stringify(c.stats)}`);
      if (sent) sawResponse = true;
    }
    finishSoon();
  },
  log: (m) => console.error(`  relay: ${m}`),
});

relay.start();
setTimeout(() => {
  console.error('timed out');
  process.exit(1);
}, timeoutS * 1000).unref();
