// The conductor: takes messages from devices, runs Claude sessions, and keeps
// the one State object that every device renders from.
import { randomUUID } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import type { CanUseTool } from '@anthropic-ai/claude-agent-sdk';
import { Device, Up, type Card, type CommandName, type Down, type Visual } from '../../protocol/schema.ts';
import { errorCard, resultCard, speakAsk, speechFor } from './cards.ts';
import { matchProject, route } from './commands.ts';
import { STATE_DIR, type Config, type Project } from './config.ts';
import { Asks, permissionHandler } from './permissions.ts';
import { ProjectSession, type SessionEvents, type TurnResult } from './session.ts';
import { Store } from './state.ts';
import { diffStat, restore, snapshot } from './stats.ts';

export type SessionLike = Pick<ProjectSession, 'busy' | 'tools' | 'send' | 'interrupt' | 'dispose'>;

export type BridgeDeps = {
  cfg: Config;
  send: (msg: Down) => void;
  log: (msg: string) => void;
  walkLog?: (who: 'you' | 'claude' | 'bridge', text: string) => void;
  deviceLog?: (device: Device, level: string, msg: string) => void;
  /** Tests inject a fake; production uses the Agent SDK. */
  makeSession?: (project: Project, canUseTool: CanUseTool, events: SessionEvents, resumeId?: string) => SessionLike;
  sessionsFile?: string;
};

type Runtime = {
  project: Project;
  session?: SessionLike;
  card?: Card;
  task?: { before: string | undefined; startedAt: number; prompt: string };
  /** Checkpoints taken before tasks that changed files, newest last. */
  undo: string[];
  /** Something Claude must know before the next prompt (for example that files were reverted). */
  preface?: string;
  visual?: Visual;
  stopping?: boolean;
};

const PHONE_FRESH_MS = 45_000;

const spokenDuration = (ms: number) => {
  const s = Math.round(ms / 1000);
  if (s < 90) return `${s} seconds`;
  return `${Math.round(s / 60)} minutes`;
};

export class Bridge {
  readonly store: Store;
  readonly asks: Asks;
  private readonly deps: BridgeDeps;
  private readonly runtimes = new Map<string, Runtime>();
  private active: Runtime;
  private readonly seen = new Map<Device, number>();
  private lastSpeech: string | undefined;
  private readonly sessionsFile: string;
  private savedSessions: Record<string, string> = {};
  private readonly canUseTool: CanUseTool;

  constructor(deps: BridgeDeps) {
    this.deps = deps;
    const { cfg } = deps;
    for (const p of cfg.projects) this.runtimes.set(p.name, { project: p, undo: [] });
    const first = cfg.projects.find((p) => p.name.toLowerCase() === cfg.defaultProject?.toLowerCase()) ?? cfg.projects[0]!;
    this.active = this.runtimes.get(first.name)!;

    this.sessionsFile = deps.sessionsFile ?? join(STATE_DIR, 'sessions.json');
    if (existsSync(this.sessionsFile)) {
      try {
        this.savedSessions = JSON.parse(readFileSync(this.sessionsFile, 'utf8')) as Record<string, string>;
      } catch {
        this.savedSessions = {};
      }
    }

    this.store = new Store(
      { project: first.name, projects: cfg.projects.map((p) => p.name), phase: 'idle', phone: false, lensCanPrompt: cfg.lensCanPrompt },
      (state) => deps.send({ v: 1, t: 'state', state }),
    );

    this.asks = new Asks({
      timeoutMs: cfg.askTimeoutSeconds * 1000,
      onOpen: (ask) => {
        this.store.set({ phase: 'asking', ask });
        const spoken =
          ask.kind === 'approve'
            ? speakAsk(ask.title, ask.detail)
            : `${ask.title} ${(ask.options ?? []).map((o, i) => `${i + 1}: ${o.label}.`).join(' ')}`;
        this.speak(spoken);
        deps.send({ v: 1, t: 'listen', on: true });
        deps.walkLog?.('claude', `asks: ${ask.title}`);
      },
      onClose: (ask, answer) => {
        this.store.set({ ask: undefined, phase: this.active.session?.busy ? 'working' : 'idle' });
        deps.walkLog?.('you', `${answer.reason ?? answer.choice}${answer.text ? `: ${answer.text}` : ''} (${ask.title})`);
        if (answer.reason === 'timeout') this.speak('No answer, so I denied it.', false);
      },
    });
    this.canUseTool = permissionHandler(this.asks, deps.log);
  }

  // ---- input from devices ---------------------------------------------------

  onUp(data: unknown, fromUserId: string | undefined): void {
    const sender = Device.safeParse(fromUserId);
    if (!sender.success) return this.deps.log(`dropped message from unknown sender "${fromUserId}"`);
    const parsed = Up.safeParse(data);
    if (!parsed.success) return this.deps.log(`dropped malformed message from ${sender.data}`);
    const device = sender.data;
    const m = parsed.data;
    this.touch(device);

    switch (m.t) {
      case 'hello':
        this.deps.log(`${device} connected${m.app ? ` (${m.app})` : ''}`);
        this.store.flush();
        break;
      case 'ping':
        this.deps.send({ v: 1, t: 'pong', n: m.n });
        break;
      case 'log':
        this.deps.deviceLog?.(device, m.level, m.msg);
        break;
      case 'partial': {
        if (!this.mayPrompt(device)) break;
        const phase = this.store.state.phase;
        if (phase !== 'idle' && phase !== 'listening') break;
        if (m.text) this.store.set({ phase: 'listening', transcript: m.text });
        else this.store.set({ phase: 'idle', transcript: undefined });
        break;
      }
      case 'prompt':
        if (!this.mayPrompt(device)) {
          this.deps.log(`${device} is not allowed to send prompts`);
          break;
        }
        void this.utterance(m.text).catch((err) => this.deps.log(`utterance failed: ${String(err)}`));
        break;
      case 'answer':
        if (!this.asks.answer(m.askId, m.choice, m.text)) this.deps.log(`stale answer from ${device}`);
        break;
      case 'command':
        void this.command(m.name, m.arg).catch((err) => this.deps.log(`command failed: ${String(err)}`));
        break;
    }
  }

  /** A device (re)connected to the relay or we did: make sure everyone has current state. */
  onRelayOpen(): void {
    this.store.flush();
  }

  /** Call every few seconds. */
  tick(now = Date.now()): void {
    const phone = now - (this.seen.get('phone') ?? 0) < PHONE_FRESH_MS;
    if (phone !== this.store.state.phone) this.store.set({ phone });
  }

  shutdown(): void {
    this.asks.cancel();
    for (const rt of this.runtimes.values()) rt.session?.dispose();
  }

  private touch(device: Device): void {
    this.seen.set(device, Date.now());
    if (device === 'phone' && !this.store.state.phone) this.store.set({ phone: true });
  }

  private mayPrompt(device: Device): boolean {
    return device !== 'lens' || this.deps.cfg.lensCanPrompt;
  }

  // ---- speech in -------------------------------------------------------------

  private async utterance(text: string): Promise<void> {
    const ask = this.asks.pending;
    const routed = route(text, {
      ...(ask ? { ask: { kind: ask.kind, ...(ask.options ? { options: ask.options.map((o) => o.label) } : {}) } } : {}),
      projects: this.deps.cfg.projects,
    });
    if (this.store.state.phase === 'listening') this.store.set({ phase: 'idle', transcript: undefined });
    this.deps.walkLog?.('you', text);

    switch (routed.kind) {
      case 'reask':
        if (ask) {
          this.speak(ask.kind === 'approve' ? 'Say approve or deny.' : 'Say the number of an option.', false);
          this.deps.send({ v: 1, t: 'listen', on: true });
        }
        break;
      case 'answer':
        this.asks.answer(undefined, routed.choice, routed.text);
        break;
      case 'choice':
        this.asks.answer(undefined, routed.label);
        break;
      case 'command':
        await this.command(routed.name, routed.arg);
        break;
      case 'prompt':
        await this.startTask(routed.text);
        break;
    }
  }

  private async startTask(text: string): Promise<void> {
    const rt = this.active;
    const session = this.sessionFor(rt);
    if (session.busy) {
      // Claude is mid-task: the words join the running conversation.
      session.send(text);
      this.store.set({ note: 'Added to the running task' });
      return;
    }
    rt.stopping = false;
    rt.visual = undefined;
    this.store.set({
      phase: 'working',
      transcript: text,
      activity: 'Starting',
      startedAt: Date.now(),
      live: undefined,
      note: undefined,
    });
    const before = await snapshot(rt.project.path);
    rt.task = { before, startedAt: Date.now(), prompt: text };
    session.send(rt.preface ? `${rt.preface}\n\n${text}` : text);
    rt.preface = undefined;
  }

  private sessionFor(rt: Runtime): SessionLike {
    if (rt.session) return rt.session;
    const events: SessionEvents = {
      onActivity: (line) => {
        if (this.active === rt && this.store.state.phase === 'working') this.store.set({ activity: line });
      },
      onShow: (title, visual) => {
        rt.visual = visual;
        if (this.active === rt) this.store.set({ live: { ...(title ? { title } : {}), visual } });
      },
      onResult: (r) => void this.finishTask(rt, r).catch((err) => this.deps.log(`finish failed: ${String(err)}`)),
      onSessionId: (id) => {
        this.savedSessions[rt.project.name] = id;
        this.saveSessions();
      },
      onTrouble: (kind, detail) => this.trouble(rt, kind, detail),
      log: (msg) => this.deps.log(`[${rt.project.name}] ${msg}`),
    };
    const make = this.deps.makeSession ?? ((p, can, ev, resume) => new ProjectSession(p, this.deps.cfg, can, ev, resume));
    rt.session = make(rt.project, this.canUseTool, events, this.savedSessions[rt.project.name]);
    return rt.session;
  }

  private async finishTask(rt: Runtime, r: TurnResult): Promise<void> {
    const task = rt.task;
    const id = randomUUID().slice(0, 8);
    let card: Card;
    let speech: string | undefined;

    // Whatever the outcome, remember how to get back if files changed.
    const after = task?.before ? await snapshot(rt.project.path) : undefined;
    const diff = task?.before && after && after !== task.before ? await diffStat(rt.project.path, task.before, after) : undefined;
    if (task?.before && diff && diff.files > 0) {
      rt.undo.push(task.before);
      if (rt.undo.length > 10) rt.undo.shift();
    }

    if (rt.stopping) {
      const lines = diff && diff.files > 0 ? [`${diff.files} ${diff.files === 1 ? 'file was' : 'files were'} changed before the stop. Say "undo that" to revert.`] : [];
      card = { id, kind: 'info', title: 'Stopped', lines, project: rt.project.name, at: Date.now() };
    } else if (r.ok) {
      card = resultCard({
        id,
        project: rt.project.name,
        text: r.text,
        stats: {
          durationS: Math.round((Date.now() - (task?.startedAt ?? Date.now())) / 1000),
          tools: rt.session?.tools ?? 0,
          ...(diff && diff.files > 0 ? diff : {}),
        },
        ...(rt.visual ? { visual: rt.visual } : {}),
      });
      speech = speechFor(r.text);
    } else if (r.subtype === 'error_max_turns') {
      card = errorCard(id, rt.project.name, 'Hit the step limit', 'Say "continue" to keep going.');
      speech = 'I hit the step limit. Say continue to keep going.';
    } else {
      card = errorCard(id, rt.project.name, 'Something went wrong', r.text || r.subtype);
      speech = `Something went wrong. ${speechFor(r.text).slice(0, 160)}`;
    }

    rt.card = card;
    rt.task = undefined;
    rt.stopping = false;
    this.deps.walkLog?.('claude', `${card.title}${card.lines.length ? ` — ${card.lines.join(' ')}` : ''}`);

    if (this.active === rt) {
      this.store.set({ phase: this.asks.pending ? 'asking' : 'idle', card, activity: undefined, startedAt: undefined, live: undefined, transcript: undefined });
      if (speech) this.speak(speech);
    } else if (speech) {
      // The user moved on to another project; tell them, but do not take over the lens.
      this.speak(`${rt.project.name} finished: ${card.title}.`);
    }
  }

  private trouble(rt: Runtime, kind: 'login' | 'limit' | 'crash' | 'overloaded', detail: string): void {
    this.deps.log(`[${rt.project.name}] trouble: ${kind} (${detail})`);
    if (kind === 'overloaded') {
      if (this.active === rt) this.store.set({ note: 'Claude is busy, retrying' });
      return;
    }
    const [title, spoken] =
      kind === 'login'
        ? ['Claude login expired', 'The Claude login on your PC has expired. Sign in again at the desk.']
        : kind === 'limit'
          ? ['Usage limit reached', 'Your Claude usage limit is reached. Try again later.']
          : ['Claude stopped unexpectedly', 'The Claude process on your PC stopped. Your next request starts it again.'];
    rt.card = errorCard(randomUUID().slice(0, 8), rt.project.name, title, kind === 'crash' ? detail : undefined);
    rt.task = undefined;
    if (kind === 'crash') {
      rt.session?.dispose();
      rt.session = undefined;
    }
    if (this.active === rt) {
      this.store.set({ phase: 'idle', card: rt.card, activity: undefined, startedAt: undefined, live: undefined });
    }
    this.speak(spoken);
  }

  // ---- commands --------------------------------------------------------------

  private async command(name: CommandName, arg?: string): Promise<void> {
    const rt = this.active;
    switch (name) {
      case 'talk':
        this.deps.send({ v: 1, t: 'listen', on: true });
        break;

      case 'stop':
        if (!rt.session?.busy && !this.asks.pending) {
          this.speak('Nothing is running.', false);
          break;
        }
        rt.stopping = true;
        this.asks.cancel();
        await rt.session?.interrupt();
        this.speak('Stopped.', false);
        break;

      case 'status':
        this.speak(this.statusText(), false);
        break;

      case 'repeat':
        this.speak(this.lastSpeech ?? 'Nothing to repeat yet.', false);
        break;

      case 'undo': {
        if (rt.session?.busy) {
          this.speak('Claude is still working. Say stop first.', false);
          break;
        }
        const point = rt.undo.at(-1);
        if (!point) {
          this.speak('Nothing to undo.', false);
          break;
        }
        const reverted = await restore(rt.project.path, point);
        if (!reverted) {
          this.speak('I could not undo that.', false);
          break;
        }
        rt.undo.pop();
        const msg = reverted.files === 0 ? 'Nothing had changed.' : `Undone. ${reverted.files} ${reverted.files === 1 ? 'file' : 'files'} restored.`;
        rt.card = { id: randomUUID().slice(0, 8), kind: 'info', title: reverted.files === 0 ? 'Nothing to undo' : 'Undone', lines: [msg], project: rt.project.name, at: Date.now() };
        this.store.set({ card: rt.card, note: undefined });
        // Claude must know the files changed under it; it hears so with the next prompt.
        if (reverted.files > 0) {
          rt.preface = '(Note from the bridge: the user said "undo that", so the file changes from your previous task were reverted on disk. Re-read files before editing and do not redo those changes unless asked.)';
        }
        this.speak(msg, false);
        break;
      }

      case 'new':
        this.asks.cancel();
        rt.session?.dispose(true);
        rt.session = undefined;
        rt.card = undefined;
        rt.task = undefined;
        rt.undo = [];
        delete this.savedSessions[rt.project.name];
        this.saveSessions();
        this.store.set({ phase: 'idle', card: undefined, activity: undefined, startedAt: undefined, live: undefined, transcript: undefined });
        this.speak(`New session in ${rt.project.name}.`, false);
        break;

      case 'switch': {
        const target = arg ? matchProject(arg, this.deps.cfg.projects) : undefined;
        const next = target ? this.runtimes.get(target) : undefined;
        if (!next) {
          this.speak(`I don't know a project called ${arg ?? 'that'}.`, false);
          break;
        }
        this.active = next;
        const busy = next.session?.busy ?? false;
        this.store.set({
          project: next.project.name,
          phase: this.asks.pending ? 'asking' : busy ? 'working' : 'idle',
          card: next.card,
          transcript: busy ? next.task?.prompt : undefined,
          activity: busy ? 'Working' : undefined,
          startedAt: busy ? next.task?.startedAt : undefined,
          live: undefined,
          note: undefined,
        });
        this.speak(`Switched to ${next.project.name}.${busy ? ' It is still working.' : ''}`, false);
        break;
      }
    }
  }

  private statusText(): string {
    const s = this.store.state;
    if (s.ask) return `Waiting for you. ${s.ask.title}`;
    if (s.phase === 'working') {
      const since = s.startedAt ? ` for ${spokenDuration(Date.now() - s.startedAt)}` : '';
      return `Working on ${s.project}${since}. ${s.activity ?? ''}`.trim();
    }
    return s.card ? `${s.project} is idle. Last result: ${s.card.title}.` : `${s.project} is idle.`;
  }

  // ---- speech out --------------------------------------------------------------

  private speak(text: string, remember = true): void {
    if (remember) this.lastSpeech = text;
    const phoneFresh = Date.now() - (this.seen.get('phone') ?? 0) < PHONE_FRESH_MS;
    this.deps.send({ v: 1, t: 'speak', id: randomUUID().slice(0, 8), text, to: phoneFresh ? 'phone' : 'lens' });
  }

  private saveSessions(): void {
    try {
      writeFileSync(this.sessionsFile, JSON.stringify(this.savedSessions, null, 2));
    } catch (err) {
      this.deps.log(`could not save sessions: ${String(err)}`);
    }
  }
}
