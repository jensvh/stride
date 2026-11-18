import { existsSync, mkdirSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, isAbsolute, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { z } from 'zod';

const here = dirname(fileURLToPath(import.meta.url));
export const BRIDGE_DIR = resolve(here, '..');
export const STATE_DIR = join(BRIDGE_DIR, '.state');
export const LOG_DIR = join(BRIDGE_DIR, 'logs');

// Outside the user profile, so nothing personal sits next to the work folders.
const DEFAULT_WORK_ROOT = process.platform === 'win32' ? 'C:\\stride-work' : join(homedir(), 'stride-work');

const Config = z.object({
  /** "dev" runs a local stand-in relay on this PC; "azure" uses Web PubSub. */
  relay: z.enum(['dev', 'azure']).default('dev'),
  devRelayPort: z.number().default(8787),
  /** Each conversation gets an empty folder in here; Claude cannot work anywhere else. */
  workRoot: z.string().default(DEFAULT_WORK_ROOT),
  /** Work folders unused for this many days are deleted. */
  keepDays: z.number().min(1).default(7),
  github: z.object({
    /** Accounts whose repositories Claude may clone: their own, their organizations' and shared ones. Token per account in bridge/.env. */
    accounts: z.array(z.string().min(1)).min(1),
  }),
  /** Stage 1: the lens dictates prompts. Switch off once the phone handles voice. */
  lensCanPrompt: z.boolean().default(true),
  askTimeoutSeconds: z.number().default(180),
  maxTurns: z.number().default(60),
  deviceTokenDays: z.number().default(30),
  /** Where the lens web app is hosted, e.g. https://you.github.io/stride/ . */
  lensUrl: z.string().url().optional(),
  model: z.string().optional(),
  /** Extra commands Claude may run without asking, e.g. "Bash(npm run e2e *)". */
  allow: z.array(z.string()).default([]),
});
export type Config = z.infer<typeof Config>;

export function loadConfig(path = process.env.STRIDE_CONFIG ?? join(BRIDGE_DIR, 'config.json')): Config {
  if (!existsSync(path)) {
    throw new Error(`No config at ${path}. Copy config.example.json to config.json and fill in your GitHub accounts.`);
  }
  const raw = JSON.parse(readFileSync(path, 'utf8')) as Record<string, unknown>;
  if ('projects' in raw) {
    throw new Error('config.json still lists "projects". Stride no longer works in folders on this PC: replace them with "github": { "accounts": [...] } (see config.example.json).');
  }
  const cfg = Config.parse(raw);
  if (!isAbsolute(cfg.workRoot)) throw new Error(`workRoot must be an absolute path, got ${cfg.workRoot}`);
  const rel = relative(resolve(cfg.workRoot), BRIDGE_DIR);
  if (!rel.startsWith('..') && !isAbsolute(rel)) throw new Error('workRoot must not contain the bridge itself.');
  mkdirSync(STATE_DIR, { recursive: true });
  mkdirSync(LOG_DIR, { recursive: true });
  return cfg;
}

/** Loads bridge/.env if present (relay connection string and GitHub tokens live there, never in git). */
export function loadEnv(): void {
  const envFile = join(BRIDGE_DIR, '.env');
  if (existsSync(envFile)) process.loadEnvFile(envFile);
}
