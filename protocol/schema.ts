// Stride wire protocol, version 1. Source of truth for the bridge, the lens and the phone.
//
// Two relay groups: devices publish to "up", the bridge publishes to "down".
// Device tokens can only send to "up" and read "down", so a device can never
// impersonate the bridge.
//
// The bridge owns all state. It publishes the whole State object on every
// change; devices render from it and never merge. Reconnecting is therefore
// just "say hello, receive the current state".
import { z } from 'zod';

export const PROTOCOL_VERSION = 1;
export const HUB = 'stride';
export const GROUP_UP = 'up';
export const GROUP_DOWN = 'down';

export const Device = z.enum(['phone', 'lens', 'cli']);
export type Device = z.infer<typeof Device>;

// ---- graphics Claude (or the bridge) can put on the lens --------------------

export const Visual = z.discriminatedUnion('type', [
  z.object({
    type: z.literal('checklist'),
    items: z.array(z.object({ text: z.string().max(60), done: z.boolean() })).min(1).max(8),
  }),
  z.object({
    type: z.literal('bars'),
    unit: z.string().max(8).optional(),
    items: z
      .array(z.object({ label: z.string().max(24), value: z.number(), max: z.number().optional() }))
      .min(1)
      .max(6),
  }),
  z.object({
    type: z.literal('table'),
    head: z.array(z.string().max(16)).max(4).optional(),
    rows: z.array(z.array(z.string().max(24)).max(4)).min(1).max(6),
  }),
  z.object({
    type: z.literal('code'),
    lang: z.string().max(16).optional(),
    text: z.string().max(600),
  }),
]);
export type Visual = z.infer<typeof Visual>;

export const Stats = z.object({
  files: z.number().optional(),
  added: z.number().optional(),
  removed: z.number().optional(),
  durationS: z.number().optional(),
  tools: z.number().optional(),
});
export type Stats = z.infer<typeof Stats>;

export const Card = z.object({
  id: z.string(),
  kind: z.enum(['result', 'error', 'info']),
  title: z.string(),
  lines: z.array(z.string()),
  visual: Visual.optional(),
  stats: Stats.optional(),
  project: z.string(),
  at: z.number(),
});
export type Card = z.infer<typeof Card>;

export const Ask = z.object({
  id: z.string(),
  kind: z.enum(['approve', 'choice']),
  title: z.string(),
  detail: z.string().optional(),
  options: z.array(z.object({ label: z.string(), description: z.string().optional() })).optional(),
  expiresAt: z.number(),
});
export type Ask = z.infer<typeof Ask>;

export const Phase = z.enum(['idle', 'listening', 'working', 'asking']);
export type Phase = z.infer<typeof Phase>;

export const State = z.object({
  rev: z.number(),
  project: z.string(),
  projects: z.array(z.string()),
  phase: Phase,
  /** Live words while listening, then the prompt that is being worked on. */
  transcript: z.string().optional(),
  /** One short line about what Claude is doing right now. */
  activity: z.string().optional(),
  /** Epoch ms when the current task started. */
  startedAt: z.number().optional(),
  /** A graphic Claude pushed while still working. */
  live: z.object({ title: z.string().optional(), visual: Visual }).optional(),
  ask: Ask.optional(),
  card: Card.optional(),
  /** Short transient notice such as "Undone" or "Switched to api". */
  note: z.string().optional(),
  /** True while a phone voice engine is connected. */
  phone: z.boolean(),
  /** True when the lens may send free-text prompts (stage 1 dictation). */
  lensCanPrompt: z.boolean(),
});
export type State = z.infer<typeof State>;

// ---- devices -> bridge (group "up") ---------------------------------------

const v = z.literal(PROTOCOL_VERSION);

export const Up = z.discriminatedUnion('t', [
  z.object({ v, t: z.literal('hello'), device: Device, app: z.string().max(60).optional() }),
  z.object({ v, t: z.literal('prompt'), id: z.string().max(64), text: z.string().min(1).max(4000) }),
  z.object({ v, t: z.literal('partial'), text: z.string().max(4000) }),
  z.object({
    v,
    t: z.literal('answer'),
    askId: z.string().max(64),
    choice: z.string().max(200),
    text: z.string().max(2000).optional(),
  }),
  z.object({
    v,
    t: z.literal('command'),
    name: z.enum(['stop', 'status', 'repeat', 'undo', 'new', 'switch', 'talk']),
    arg: z.string().max(100).optional(),
  }),
  z.object({
    v,
    t: z.literal('log'),
    level: z.enum(['debug', 'info', 'warn', 'error']),
    msg: z.string().max(4000),
  }),
  z.object({ v, t: z.literal('ping'), n: z.number() }),
]);
export type Up = z.infer<typeof Up>;

// ---- bridge -> devices (group "down") -------------------------------------

export const Down = z.discriminatedUnion('t', [
  z.object({ v, t: z.literal('state'), state: State }),
  /** Speak once. `to` names the device that should voice it. */
  z.object({ v, t: z.literal('speak'), id: z.string(), text: z.string(), to: z.enum(['phone', 'lens']) }),
  /** Ask the phone to open or close the microphone. */
  z.object({ v, t: z.literal('listen'), on: z.boolean() }),
  z.object({ v, t: z.literal('pong'), n: z.number() }),
]);
export type Down = z.infer<typeof Down>;

export type CommandName = Extract<Up, { t: 'command' }>['name'];
