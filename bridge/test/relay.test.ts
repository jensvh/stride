import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { RelayClient } from '../../protocol/relayClient.ts';
import { GROUP_DOWN, GROUP_UP, HUB } from '../../protocol/schema.ts';
import { startDevRelay } from '../src/devRelay.ts';
import { rolesFor, signJwt, verifyJwt, type Identity } from '../src/tokens.ts';

const PORT = 18787;
const KEY = 'test-key';
const url = (id: Identity, key = KEY) => {
  const now = Math.floor(Date.now() / 1000);
  return `ws://127.0.0.1:${PORT}/client/hubs/${HUB}?access_token=${signJwt({ sub: id, role: rolesFor(id), exp: now + 60 }, key)}`;
};

const opened = (c: RelayClient) =>
  new Promise<void>((resolve, reject) => {
    const t = setTimeout(() => reject(new Error('not open in time')), 4000);
    const poll = setInterval(() => {
      if (c.isOpen) {
        clearTimeout(t);
        clearInterval(poll);
        resolve();
      }
    }, 10);
  });

let relay: { close: () => void };
const clients: RelayClient[] = [];
const client = (id: Identity, join: string[], onMessage: (g: string, d: unknown, from?: string) => void = () => {}, key = KEY) => {
  const c = new RelayClient({ url: url(id, key), join, onMessage });
  clients.push(c);
  c.start();
  return c;
};

beforeAll(() => {
  relay = startDevRelay(PORT, KEY, () => {});
});
afterAll(() => {
  for (const c of clients) c.stop();
  relay.close();
});

describe('jwt', () => {
  it('round-trips and rejects a wrong key or an expired token', () => {
    const now = Math.floor(Date.now() / 1000);
    expect(verifyJwt(signJwt({ sub: 'a', exp: now + 10 }, KEY), KEY)?.sub).toBe('a');
    expect(verifyJwt(signJwt({ sub: 'a', exp: now + 10 }, KEY), 'other')).toBeUndefined();
    expect(verifyJwt(signJwt({ sub: 'a', exp: now - 10 }, KEY), KEY)).toBeUndefined();
  });
});

describe('relay roles', () => {
  it('carries device messages up to the bridge with the sender identity', async () => {
    const got: unknown[] = [];
    const bridge = client('bridge', [GROUP_UP], (_g, d, from) => got.push([d, from]));
    const lens = client('lens', [GROUP_DOWN]);
    await Promise.all([opened(bridge), opened(lens)]);
    expect(lens.send(GROUP_UP, { hello: 1 })).toBe(true);
    await expect.poll(() => got).toEqual([[{ hello: 1 }, 'lens']]);
  });

  it('carries bridge messages down to every device', async () => {
    const a: unknown[] = [];
    const b: unknown[] = [];
    const bridge = client('bridge', [GROUP_UP]);
    const phone = client('phone', [GROUP_DOWN], (_g, d) => a.push(d));
    const lens = client('lens', [GROUP_DOWN], (_g, d) => b.push(d));
    await Promise.all([opened(bridge), opened(phone), opened(lens)]);
    bridge.send(GROUP_DOWN, { n: 7 });
    await expect.poll(() => [a, b]).toEqual([[{ n: 7 }], [{ n: 7 }]]);
  });

  it('does not let a device publish to "down" (impersonate the bridge)', async () => {
    const seen: unknown[] = [];
    const lens = client('lens', [GROUP_DOWN]);
    const phone = client('phone', [GROUP_DOWN], (_g, d) => seen.push(d));
    await Promise.all([opened(lens), opened(phone)]);
    lens.send(GROUP_DOWN, { fake: 'state' });
    await new Promise((r) => setTimeout(r, 200));
    expect(seen).toEqual([]);
  });

  it('does not let a device read "up" (eavesdrop on other devices)', async () => {
    const spy = client('lens', [GROUP_UP]);
    await new Promise((r) => setTimeout(r, 400));
    expect(spy.isOpen).toBe(false);
  });

  it('refuses a token signed with another key', async () => {
    const bad = client('bridge', [GROUP_UP], () => {}, 'stolen-guess');
    await new Promise((r) => setTimeout(r, 400));
    expect(bad.isOpen).toBe(false);
  });

  it('answers a probe', async () => {
    const bridge = client('bridge', [GROUP_UP]);
    await opened(bridge);
    expect(await bridge.probe(2000)).toBe(true);
  });
});
