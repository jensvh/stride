import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { CanUseTool } from '@anthropic-ai/claude-agent-sdk';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Down, State, Up } from '../../protocol/schema.ts';
import { Bridge, type SessionLike } from '../src/bridge.ts';
import type { Config } from '../src/config.ts';
import type { SessionEvents } from '../src/session.ts';

// A scripted stand-in for the Claude session.
class FakeSession implements SessionLike {
  busy = false;
  tools = 0;
  sent: string[] = [];
  interrupted = 0;
  disposed: boolean[] = [];
  readonly can: CanUseTool;
  readonly events: SessionEvents;
  readonly resumeId: string | undefined;

  constructor(can: CanUseTool, events: SessionEvents, resumeId?: string) {
    this.can = can;
    this.events = events;
    this.resumeId = resumeId;
  }
  send(text: string) {
    this.busy = true;
    this.sent.push(text);
  }
  async interrupt() {
    this.interrupted++;
    this.finish('', 'error_during_execution', false);
  }
  dispose(forget = false) {
    this.disposed.push(forget);
    this.busy = false;
  }
  finish(text: string, subtype = 'success', ok = true) {
    this.busy = false;
    this.events.onResult({ ok, text, subtype, durationMs: 1000 });
  }
  ask(tool: string, input: Record<string, unknown>) {
    return this.can(tool, input, { signal: new AbortController().signal, toolUseID: 't1', requestId: 'r1' });
  }
}

let dir: string;
let out: Down[];
let sessions: Map<string, FakeSession>;
let bridge: Bridge;

const cfg = (over: Partial<Config> = {}): Config => ({
  relay: 'dev',
  devRelayPort: 0,
  projects: [
    { name: 'api', aliases: ['backend'], path: dir, allow: [] },
    { name: 'web', aliases: [], path: dir, allow: [] },
  ],
  lensCanPrompt: true,
  askTimeoutSeconds: 60,
  maxTurns: 10,
  deviceTokenDays: 30,
  allow: [],
  ...over,
});

const make = (over: Partial<Config> = {}) => {
  out = [];
  sessions = new Map();
  bridge = new Bridge({
    cfg: cfg(over),
    send: (m) => out.push(m),
    log: () => {},
    sessionsFile: join(dir, 'sessions.json'),
    makeSession: (project, can, events, resumeId) => {
      const s = new FakeSession(can, events, resumeId);
      sessions.set(project.name, s);
      return s;
    },
  });
};

const up = (m: Up, from = 'phone') => bridge.onUp(m, from);
const say = (text: string, from = 'phone') => up({ v: 1, t: 'prompt', id: 'p', text }, from);
const state = (): State => bridge.store.state;
const spoken = () => out.filter((m) => m.t === 'speak').map((m) => (m as Extract<Down, { t: 'speak' }>).text);
const settle = () => vi.waitFor(() => undefined, { timeout: 50 }).then(() => new Promise((r) => setTimeout(r, 20)));

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'stride-bridge-'));
  make();
});
afterEach(() => {
  bridge.shutdown();
  // On Windows a git child process may still hold the folder for a moment.
  try {
    rmSync(dir, { recursive: true, force: true, maxRetries: 20, retryDelay: 50 });
  } catch {
    // leftover temp folders are harmless
  }
});

describe('a task from start to finish', () => {
  it('goes idle → working → idle with a card and speech', async () => {
    say('Add a health endpoint');
    await vi.waitFor(() => expect(sessions.get('api')?.sent).toEqual(['Add a health endpoint']));
    expect(state().phase).toBe('working');
    expect(state().transcript).toBe('Add a health endpoint');

    sessions.get('api')!.events.onActivity('Edit server.ts');
    expect(state().activity).toBe('Edit server.ts');

    sessions.get('api')!.finish('Health endpoint added\nIt returns 200 with the build version.');
    await vi.waitFor(() => expect(state().phase).toBe('idle'));
    expect(state().card).toMatchObject({ kind: 'result', title: 'Health endpoint added', project: 'api' });
    expect(state().activity).toBeUndefined();
    expect(spoken().at(-1)).toBe('Health endpoint added. It returns 200 with the build version.');
  });

  it('attaches the graphic Claude showed to the result card', async () => {
    say('Run the tests');
    await vi.waitFor(() => expect(sessions.get('api')?.sent.length).toBe(1));
    const visual = { type: 'bars' as const, items: [{ label: 'passed', value: 41 }, { label: 'failed', value: 1 }] };
    sessions.get('api')!.events.onShow('Tests', visual);
    expect(state().live).toEqual({ title: 'Tests', visual });
    sessions.get('api')!.finish('One test fails');
    await vi.waitFor(() => expect(state().card?.visual).toEqual(visual));
    expect(state().live).toBeUndefined();
  });

  it('feeds words spoken mid-task into the running conversation', async () => {
    say('Refactor the importer');
    await vi.waitFor(() => expect(sessions.get('api')?.sent.length).toBe(1));
    say('and keep the old function name');
    await vi.waitFor(() => expect(sessions.get('api')?.sent.length).toBe(2));
    expect(state().phase).toBe('working');
  });
});

describe('approvals', () => {
  const pendingAsk = async () => {
    say('Install zod');
    await vi.waitFor(() => expect(sessions.get('api')?.sent.length).toBe(1));
    const decision = sessions.get('api')!.ask('Bash', { command: 'npm install zod' });
    await vi.waitFor(() => expect(state().phase).toBe('asking'));
    return { decision };
  };

  it('shows the request, speaks it and opens the microphone', async () => {
    await pendingAsk();
    expect(state().ask).toMatchObject({ kind: 'approve', title: 'Run: npm install zod' });
    expect(spoken().at(-1)).toBe('Run: npm install zod. Approve or deny?');
    expect(out.some((m) => m.t === 'listen' && m.on)).toBe(true);
  });

  it('approves by voice', async () => {
    const { decision } = await pendingAsk();
    say('approve');
    await expect(decision).resolves.toMatchObject({ behavior: 'allow' });
    expect(state().ask).toBeUndefined();
    expect(state().phase).toBe('working');
  });

  it('approves by pinch on the lens button', async () => {
    const { decision } = await pendingAsk();
    up({ v: 1, t: 'answer', askId: state().ask!.id, choice: 'approve' }, 'lens');
    await expect(decision).resolves.toMatchObject({ behavior: 'allow' });
  });

  it('does not approve on a bare "yes", and asks again', async () => {
    const { decision } = await pendingAsk();
    say('yes');
    await settle();
    expect(state().phase).toBe('asking');
    expect(spoken().at(-1)).toBe('Say approve or deny.');
    say('deny, use pnpm instead');
    await expect(decision).resolves.toMatchObject({ behavior: 'deny', message: expect.stringContaining('use pnpm instead') });
  });

  it('denies when nobody answers in time', async () => {
    vi.useFakeTimers();
    try {
      const decision = pendingAskSync();
      await vi.advanceTimersByTimeAsync(61_000);
      await expect(decision).resolves.toMatchObject({ behavior: 'deny', message: expect.stringContaining('away from the desk') });
      expect(state().ask).toBeUndefined();
    } finally {
      vi.useRealTimers();
    }
  });

  // With fake timers the session must exist before time is frozen-advanced.
  const pendingAskSync = () => {
    bridge.shutdown();
    make();
    const s = new FakeSession(
      (bridge as unknown as { canUseTool: CanUseTool }).canUseTool,
      {} as SessionEvents,
    );
    return s.ask('Bash', { command: 'npm install zod' });
  };

  it('ignores an answer for a question that is no longer open', async () => {
    const { decision } = await pendingAsk();
    up({ v: 1, t: 'answer', askId: 'stale', choice: 'approve' }, 'lens');
    await settle();
    expect(state().phase).toBe('asking');
    say('deny');
    await decision;
  });

  it('turns a clarifying question from Claude into a choice', async () => {
    say('Pick a database');
    await vi.waitFor(() => expect(sessions.get('api')).toBeDefined());
    const input = { questions: [{ question: 'Which database?', options: [{ label: 'Postgres' }, { label: 'SQLite' }] }] };
    const decision = sessions.get('api')!.ask('AskUserQuestion', input);
    await vi.waitFor(() => expect(state().ask?.kind).toBe('choice'));
    expect(spoken().at(-1)).toBe('Which database? 1: Postgres. 2: SQLite.');
    say('two');
    await expect(decision).resolves.toMatchObject({ behavior: 'allow', updatedInput: { answers: { 'Which database?': 'SQLite' } } });
  });
});

describe('who may do what', () => {
  it('drops messages from unknown identities and malformed messages', () => {
    bridge.onUp({ v: 1, t: 'prompt', id: 'x', text: 'rm -rf everything' }, 'stranger');
    bridge.onUp({ v: 1, t: 'prompt', id: 'x', text: 'hi' }, undefined);
    bridge.onUp({ v: 1, t: 'prompt', text: 42 }, 'phone');
    bridge.onUp({ v: 2, t: 'prompt', id: 'x', text: 'hi' }, 'phone');
    expect(sessions.size).toBe(0);
    expect(state().phase).toBe('idle');
  });

  it('lets the lens prompt only while lensCanPrompt is on', async () => {
    bridge.shutdown();
    make({ lensCanPrompt: false });
    say('do something', 'lens');
    await settle();
    expect(sessions.size).toBe(0);
    say('do something', 'phone');
    await vi.waitFor(() => expect(sessions.get('api')?.sent).toEqual(['do something']));
  });
});

describe('commands', () => {
  it('stop interrupts and shows Stopped instead of an error', async () => {
    say('Do a long thing');
    await vi.waitFor(() => expect(sessions.get('api')?.busy).toBe(true));
    say('stop');
    await vi.waitFor(() => expect(state().card?.title).toBe('Stopped'));
    expect(sessions.get('api')!.interrupted).toBe(1);
    expect(state().phase).toBe('idle');
    expect(spoken()).toContain('Stopped.');
  });

  it('undo has nothing to do when no task changed files', async () => {
    say('undo that');
    await vi.waitFor(() => expect(spoken().at(-1)).toBe('Nothing to undo.'));
    expect(sessions.size).toBe(0);
  });

  it('status and repeat answer by voice only', async () => {
    say('status');
    await vi.waitFor(() => expect(spoken().at(-1)).toBe('api is idle.'));
    say('Explain the build');
    await vi.waitFor(() => expect(sessions.get('api')?.sent).toEqual(['Explain the build']));
    sessions.get('api')!.finish('It uses Vite');
    await vi.waitFor(() => expect(state().phase).toBe('idle'));
    say('repeat');
    await vi.waitFor(() => expect(spoken().at(-1)).toBe('It uses Vite'));
    expect(sessions.get('api')!.sent).toEqual(['Explain the build']);
  });

  it('switches project and keeps each project\'s own card', async () => {
    say('Explain the build');
    await vi.waitFor(() => expect(sessions.get('api')?.sent.length).toBe(1));
    sessions.get('api')!.finish('It uses Vite');
    await vi.waitFor(() => expect(state().card?.title).toBe('It uses Vite'));

    say('switch to web');
    await vi.waitFor(() => expect(state().project).toBe('web'));
    expect(state().card).toBeUndefined();
    say('switch to the backend');
    await vi.waitFor(() => expect(state().project).toBe('api'));
    expect(state().card?.title).toBe('It uses Vite');
  });

  it('new session forgets the conversation', async () => {
    say('Hello');
    await vi.waitFor(() => expect(sessions.get('api')?.sent.length).toBe(1));
    const first = sessions.get('api')!;
    first.events.onSessionId('abc');
    first.finish('Hi');
    await vi.waitFor(() => expect(state().phase).toBe('idle'));
    say('new session');
    await vi.waitFor(() => expect(first.disposed).toEqual([true]));
    say('Hello again');
    await vi.waitFor(() => expect(sessions.get('api')).not.toBe(first));
    expect(sessions.get('api')!.resumeId).toBeUndefined();
  });

  it('resumes the saved conversation after a bridge restart', async () => {
    say('Hello');
    await vi.waitFor(() => expect(sessions.get('api')).toBeDefined());
    sessions.get('api')!.events.onSessionId('abc');
    bridge.shutdown();
    make();
    say('Still there?');
    await vi.waitFor(() => expect(sessions.get('api')?.resumeId).toBe('abc'));
  });
});

describe('presence and sync', () => {
  it('sends the whole state when a device says hello', () => {
    out = [];
    up({ v: 1, t: 'hello', device: 'lens' }, 'lens');
    expect(out.at(-1)).toMatchObject({ t: 'state', state: { phase: 'idle', project: 'api' } });
  });

  it('speaks through the phone while it is connected, otherwise through the lens', async () => {
    say('status', 'cli');
    await vi.waitFor(() => expect(out.find((m) => m.t === 'speak')).toMatchObject({ to: 'lens' }));
    out = [];
    up({ v: 1, t: 'ping', n: 1 }, 'phone');
    expect(state().phone).toBe(true);
    say('status', 'cli');
    await vi.waitFor(() => expect(out.find((m) => m.t === 'speak')).toMatchObject({ to: 'phone' }));
    bridge.tick(Date.now() + 60_000);
    expect(state().phone).toBe(false);
  });

  it('shows live words while listening and clears them when listening ends', () => {
    up({ v: 1, t: 'partial', text: 'fix the' });
    expect(state()).toMatchObject({ phase: 'listening', transcript: 'fix the' });
    up({ v: 1, t: 'partial', text: '' });
    expect(state().phase).toBe('idle');
    expect(state().transcript).toBeUndefined();
  });
});

describe('trouble the user cannot see', () => {
  it('says so when the Claude login expired', async () => {
    say('Hello');
    await vi.waitFor(() => expect(sessions.get('api')).toBeDefined());
    sessions.get('api')!.events.onTrouble('login', 'authentication_failed');
    expect(state().card).toMatchObject({ kind: 'error', title: 'Claude login expired' });
    expect(spoken().at(-1)).toMatch(/login on your PC has expired/);
    expect(state().phase).toBe('idle');
  });
});
