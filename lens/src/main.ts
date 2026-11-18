// Stride lens: the web app that runs on the glasses.
import { RelayClient } from '../../protocol/relayClient.ts';
import type { Down, State, Up } from '../../protocol/schema.ts';
import { installArrowFallback } from './nav.ts';
import { LensView, type Link } from './view.ts';
import './style.css';

const STORE_KEY = 'stride.relay.v1';
const app = document.getElementById('app')!;
const params = new URLSearchParams(location.search);

async function boot(): Promise<void> {
  installArrowFallback();
  if (params.has('demo')) {
    const { runDemo } = await import('./demo.ts');
    runDemo(app, params.get('demo') || 'all');
    return;
  }
  live();
}

/** The relay URL arrives once in the install link (?r=...), then lives in local storage. */
function relayUrl(): string | undefined {
  const fromLink = params.get('r');
  if (fromLink) {
    try {
      const url = atob(fromLink.replace(/-/g, '+').replace(/_/g, '/'));
      if (/^wss?:\/\//.test(url)) {
        try {
          localStorage.setItem(STORE_KEY, url);
        } catch {
          // storage can be unavailable on the glasses; the link still works for this launch
        }
        history.replaceState(null, '', location.pathname);
        return url;
      }
    } catch {
      // fall through to storage
    }
  }
  try {
    return localStorage.getItem(STORE_KEY) ?? undefined;
  } catch {
    return undefined;
  }
}

function live(): void {
  const frame = document.createElement('div');
  app.append(frame);

  let state: State | undefined;
  let link: Link = 'connecting';
  let lastDown = 0;
  let pingN = 0;

  const send = (m: Up) => relay?.send('up', m) ?? false;
  const log = (level: 'info' | 'warn' | 'error', msg: string) => send({ v: 1, t: 'log', level, msg: msg.slice(0, 3900) });

  const view = new LensView(frame, {
    prompt: (text) => send({ v: 1, t: 'prompt', id: Math.random().toString(36).slice(2, 10), text }),
    answer: (askId, choice) => send({ v: 1, t: 'answer', askId, choice }),
    command: (name) => send({ v: 1, t: 'command', name }),
  });
  const render = () => view.render({ link, state });

  const url = relayUrl();
  if (!url) {
    link = 'unpaired';
    render();
    return;
  }

  const speak = (text: string) => {
    try {
      speechSynthesis.cancel();
      speechSynthesis.speak(new SpeechSynthesisUtterance(text));
    } catch {
      // no speech on this device
    }
  };

  const relay = new RelayClient({
    url,
    join: ['down'],
    onStatus: (s) => {
      if (s === 'open') {
        send({ v: 1, t: 'hello', device: 'lens', app: 'lens-web' });
        send({ v: 1, t: 'ping', n: ++pingN });
        // The relay is up; whether the PC is too shows when it answers.
        setTimeout(() => {
          if (Date.now() - lastDown > 6000 && link !== 'online') {
            link = 'pc-offline';
            render();
          }
        }, 6000);
      } else if (link !== 'connecting') {
        link = 'connecting';
        render();
      }
    },
    onMessage: (_group, data) => {
      const m = data as Down;
      if (!m || m.v !== 1) return;
      lastDown = Date.now();
      if (link !== 'online') link = 'online';
      if (m.t === 'state') state = m.state;
      else if (m.t === 'speak' && m.to === 'lens') speak(m.text);
      render();
    },
  });
  relay.start();
  render();

  // Heartbeat: is the PC still there?
  setInterval(() => {
    if (!relay.isOpen) return;
    send({ v: 1, t: 'ping', n: ++pingN });
    setTimeout(() => {
      if (relay.isOpen && Date.now() - lastDown > 20_000 && link === 'online') {
        link = 'pc-offline';
        render();
      }
    }, 8000);
  }, 15_000);

  // Coming back from display sleep: the socket may be dead without knowing it.
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState !== 'visible') return;
    if (relay.isOpen) send({ v: 1, t: 'hello', device: 'lens', app: 'lens-web' });
    else relay.reconnect();
  });

  // The glasses have no console: send our errors to the PC.
  window.addEventListener('error', (ev) => log('error', `${ev.message} @ ${ev.filename}:${ev.lineno}`));
  window.addEventListener('unhandledrejection', (ev) => log('error', `unhandled: ${String(ev.reason)}`));
}

void boot();
