// Relay tokens. Every identity gets only the roles it needs:
//   bridge  reads "up",   writes "down"
//   devices write "up",   read  "down"
import { createHmac, randomBytes, timingSafeEqual } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { WebPubSubServiceClient } from '@azure/web-pubsub';
import { GROUP_DOWN, GROUP_UP, HUB } from '../../protocol/schema.ts';
import { STATE_DIR, type Config } from './config.ts';

export type Identity = 'bridge' | 'phone' | 'lens' | 'cli';

export function rolesFor(id: Identity): string[] {
  return id === 'bridge'
    ? [`webpubsub.joinLeaveGroup.${GROUP_UP}`, `webpubsub.sendToGroup.${GROUP_DOWN}`]
    : [`webpubsub.sendToGroup.${GROUP_UP}`, `webpubsub.joinLeaveGroup.${GROUP_DOWN}`];
}

// ---- tiny HS256 JWT, used only by the local dev relay ----------------------

const b64url = (b: Buffer | string) => Buffer.from(b).toString('base64url');

export function signJwt(payload: Record<string, unknown>, key: string): string {
  const head = b64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const body = b64url(JSON.stringify(payload));
  const sig = createHmac('sha256', key).update(`${head}.${body}`).digest('base64url');
  return `${head}.${body}.${sig}`;
}

export function verifyJwt(token: string, key: string): Record<string, unknown> | undefined {
  const [head, body, sig] = token.split('.');
  if (!head || !body || !sig) return undefined;
  const want = createHmac('sha256', key).update(`${head}.${body}`).digest();
  const got = Buffer.from(sig, 'base64url');
  if (got.length !== want.length || !timingSafeEqual(got, want)) return undefined;
  try {
    const payload = JSON.parse(Buffer.from(body, 'base64url').toString('utf8')) as Record<string, unknown>;
    if (typeof payload.exp === 'number' && payload.exp * 1000 < Date.now()) return undefined;
    return payload;
  } catch {
    return undefined;
  }
}

/** Random key for the dev relay, shared between the bridge and `npm run say` through a local file. */
export function devKey(): string {
  const file = join(STATE_DIR, 'dev-relay.key');
  if (!existsSync(file)) writeFileSync(file, randomBytes(32).toString('hex'), { mode: 0o600 });
  return readFileSync(file, 'utf8').trim();
}

/** Client URL (with token) for one identity. */
export async function clientUrl(cfg: Config, id: Identity, minutes?: number): Promise<string> {
  const lifetime = minutes ?? (id === 'bridge' || id === 'cli' ? 60 : cfg.deviceTokenDays * 24 * 60);
  if (cfg.relay === 'dev') {
    const now = Math.floor(Date.now() / 1000);
    const token = signJwt({ sub: id, role: rolesFor(id), iat: now, exp: now + lifetime * 60 }, devKey());
    return `ws://127.0.0.1:${cfg.devRelayPort}/client/hubs/${HUB}?access_token=${token}`;
  }
  const conn = process.env.WEBPUBSUB_CONNECTION_STRING;
  if (!conn) throw new Error('WEBPUBSUB_CONNECTION_STRING is not set (bridge/.env).');
  const service = new WebPubSubServiceClient(conn, HUB);
  const token = await service.getClientAccessToken({
    userId: id,
    roles: rolesFor(id),
    expirationTimeInMinutes: lifetime,
  });
  return token.url;
}
