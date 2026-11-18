import { existsSync, mkdirSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { z } from 'zod';

const here = dirname(fileURLToPath(import.meta.url));
export const BRIDGE_DIR = resolve(here, '..');
export const STATE_DIR = join(BRIDGE_DIR, '.state');
export const LOG_DIR = join(BRIDGE_DIR, 'logs');

const Project = z.object({
  name: z.string().min(1),
  /** Other ways you might say the name out loud. */
  aliases: z.array(z.string()).default([]),
  path: z.string().min(1),
  /** Extra allow rules for this project, e.g. "Bash(npm run e2e *)". */
  allow: z.array(z.string()).default([]),
});
export type Project = z.infer<typeof Project>;

const Config = z.object({
  /** "dev" runs a local stand-in relay on this PC; "azure" uses Web PubSub. */
  relay: z.enum(['dev', 'azure']).default('dev'),
  devRelayPort: z.number().default(8787),
  defaultProject: z.string().optional(),
  projects: z.array(Project).min(1),
  /** Stage 1: the lens dictates prompts. Switch off once the phone handles voice. */
  lensCanPrompt: z.boolean().default(true),
  askTimeoutSeconds: z.number().default(180),
  maxTurns: z.number().default(60),
  deviceTokenDays: z.number().default(30),
  /** Where the lens web app is hosted, e.g. https://you.github.io/stride/ . */
  lensUrl: z.string().url().optional(),
  model: z.string().optional(),
  /** Allow rules applied to every project, on top of the built-in ones. */
  allow: z.array(z.string()).default([]),
});
export type Config = z.infer<typeof Config>;

export function loadConfig(path = process.env.STRIDE_CONFIG ?? join(BRIDGE_DIR, 'config.json')): Config {
  if (!existsSync(path)) {
    throw new Error(`No config at ${path}. Copy config.example.json to config.json and list your projects.`);
  }
  const cfg = Config.parse(JSON.parse(readFileSync(path, 'utf8')));
  for (const p of cfg.projects) {
    if (!existsSync(p.path)) throw new Error(`Project "${p.name}": folder not found: ${p.path}`);
  }
  const names = new Set(cfg.projects.map((p) => p.name.toLowerCase()));
  if (names.size !== cfg.projects.length) throw new Error('Project names must be unique.');
  if (cfg.defaultProject && !names.has(cfg.defaultProject.toLowerCase())) {
    throw new Error(`defaultProject "${cfg.defaultProject}" is not in projects.`);
  }
  mkdirSync(STATE_DIR, { recursive: true });
  mkdirSync(LOG_DIR, { recursive: true });
  return cfg;
}

/** Loads bridge/.env if present (Web PubSub connection string lives there, never in git). */
export function loadEnv(): void {
  const envFile = join(BRIDGE_DIR, '.env');
  if (existsSync(envFile)) process.loadEnvFile(envFile);
}
