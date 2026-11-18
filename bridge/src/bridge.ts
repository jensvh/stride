// The conductor: takes messages from devices, runs the Claude session of the
// current work folder, and keeps the one State object every device renders from.
import { randomUUID } from 'node:crypto';
import { join } from 'node:path';
import type { CanUseTool } from '@anthropic-ai/claude-agent-sdk';
import { Device, Up, type Card, type CommandName, type Down, type Visual } from '../../protocol/schema.ts';
import { errorCard, resultCard, speakAsk, speechFor } from './cards.ts';
import { matchProject, route } from './commands.ts';
import { STATE_DIR, type Config } from './config.ts';
import { GitHub } from './github.ts';
import { guardHook } from './guard.ts';
import { Asks, permissionHandler } from './permissions.ts';
import { githubServer, publishHook, type RepoToolsContext } from './repoTools.ts';
import { ClaudeSession, type SessionEvents, type SessionSetup, type TurnResult } from './session.ts';
import { lensServer } from './showTool.ts';
import { Store } from './state.ts';
import { diffAll, restoreAll, snapshotAll, type Checkpoint } from './stats.ts';
import { Workspaces } from './workspace.ts';

export type SessionLike = Pick<ClaudeSession, 'busy' | 'tools' | 'send' | 'interrupt' | 'dispose'>;

export type BridgeDeps = {
  cfg: Config;
  send: (msg: Down) => void;
  log: (msg: string) => void;
  walkLog?: (who: 'you' | 'claude' | 'bridge', text: string) => void;
  deviceLog?: (device: Device, level: string, msg: string) => void;
  /** Tests inject fakes; production uses the Agent SDK, GitHub and folders under cfg.workRoot. */
  makeSession?: (setup: SessionSetup, canUseTool: CanUseTool, events: SessionEvents, resumeId?: string) => SessionLike;
  github?: GitHub;
  workspaces?: Workspaces;
};

type Task = { before: Checkpoint; startedAt: number; prompt: string };

const PHONE_FRESH_MS = 45_000;
const NO_REPO = 'no repo yet';

const spokenDuration = (ms: number) => {
  const s = Math.round(ms / 1000);
  if (s < 90) return `${s} seconds`;
  return `${Math.round(s / 60)} minutes`;
};

export class Bridge {
  readonly store: Store;
  readonly asks: Asks;
  readonly workspaces: Workspaces;
  readonly github: GitHub;
  private readonly deps: BridgeDeps;
  private readonly seen = new Map<Device, number>();
  private lastSpeech: string | undefined;
  private readonly canUseTool: CanUseTool;

  private session: SessionLike | undefined;
  private card: Card | undefined;
  private task: Task | undefined;
  /** Checkpoints taken before tasks that changed files, newest last. */
  private undo: Checkpoint[] = [];
  /** Something Claude must know before the next prompt (for example that files were reverted). */
  private preface: string | undefined;
  private visual: Visual | undefined;
  private stopping = false;

  constructor(deps: BridgeDeps) {
    this.deps = deps;
    const { cfg } = deps;
    this.workspaces =
      deps.workspaces ??
      new Workspaces({ root: cfg.workRoot, keepDays: cfg.keepDays, stateFile: join(STATE_DIR, 'workspace.json'), log: deps.log });
    this.github = deps.github ?? new GitHub({ accounts: cfg.github.accounts, log: deps.log });

    this.store = new Store(
      { project: this.label(), projects: this.workspaces.repos(), phase: 'idle', phone: false, lensCanPrompt: cfg.lensCanPrompt },
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
        this.store.set({ ask: undefined, phase: this.session?.busy ? 'working' : 'idle' });
        deps.walkLog?.('you', `${answer.reason ?? answer.choice}${answer.text ? `: ${answer.text}` : ''} (${ask.title})`);
        if (answer.reason === 'timeout') this.speak('No answer, so I denied it.', false);
      },
    });
    this.canUseTool = permissionHandler(this.asks, deps.log);
  }

  /** What the lens shows at the top: the repository being worked on. */
  private label(): string {
    return this.workspaces.current().focus ?? NO_REPO;
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
    this.session?.dispose();
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
      projects: this.workspaces.repos().map((name) => ({ name, aliases: [] })),
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
    const session = this.sessionFor();
    if (session.busy) {
      // Claude is mid-task: the words join the running conversation.
      session.send(text);
      this.store.set({ note: 'Added to the running task' });
      return;
    }
    this.stopping = false;
    this.visual = undefined;
    this.store.set({
      phase: 'working',
      transcript: text,
      activity: 'Starting',
      startedAt: Date.now(),
      live: undefined,
      note: undefined,
    });
    this.workspaces.touch();
    const ws = this.workspaces.current();
    const before = await snapshotAll(ws.path, this.workspaces.repos());
    this.task = { before, startedAt: Date.now(), prompt: text };
    session.send(this.preface ? `${this.preface}\n\n${text}` : text);
    this.preface = undefined;
  }

  private sessionFor(): SessionLike {
    if (this.session) return this.session;
    const ws = this.workspaces.current();
    const events: SessionEvents = {
      onActivity: (line) => {
        if (this.store.state.phase === 'working') this.store.set({ activity: line });
      },
      onShow: (title, visual) => {
        this.visual = visual;
        this.store.set({ live: { ...(title ? { title } : {}), visual } });
      },
      onResult: (r) => void this.finishTask(r).catch((err) => this.deps.log(`finish failed: ${String(err)}`)),
      onSessionId: (id) => this.workspaces.update({ sessionId: id }),
      onTrouble: (kind, detail) => this.trouble(kind, detail),
      log: (msg) => this.deps.log(msg),
    };
    const repoCtx: RepoToolsContext = {
      github: this.github,
      workspace: () => this.workspaces.current().path,
      onCloned: (folder) => {
        this.workspaces.update({ focus: folder });
        this.store.set({ project: folder, projects: this.workspaces.repos() });
      },
      log: this.deps.log,
    };
    const setup: SessionSetup = {
      cwd: ws.path,
      mcpServers: { lens: lensServer(events.onShow), github: githubServer(repoCtx) },
      hooks: {
        PreToolUse: [
          { hooks: [guardHook(() => this.workspaces.current().path)] },
          { matcher: 'mcp__github__publish', hooks: [publishHook(repoCtx)] },
        ],
      },
    };
    const make = this.deps.makeSession ?? ((s, can, ev, resume) => new ClaudeSession(s, this.deps.cfg, can, ev, resume));
    this.session = make(setup, this.canUseTool, events, ws.sessionId);
    return this.session;
  }

  private async finishTask(r: TurnResult): Promise<void> {
    const task = this.task;
    const id = randomUUID().slice(0, 8);
    const where = this.label();
    let card: Card;
    let speech: string | undefined;

    // Whatever the outcome, remember how to get back if files changed.
    const root = this.workspaces.current().path;
    const after = task ? await snapshotAll(root, Object.keys(task.before)) : undefined;
    const diff = task && after ? await diffAll(root, task.before, after) : undefined;
    if (task && diff && diff.files > 0) {
      this.undo.push(task.before);
      if (this.undo.length > 10) this.undo.shift();
    }

    if (this.stopping) {
      const lines = diff && diff.files > 0 ? [`${diff.files} ${diff.files === 1 ? 'file was' : 'files were'} changed before the stop. Say "undo that" to revert.`] : [];
      card = { id, kind: 'info', title: 'Stopped', lines, project: where, at: Date.now() };
    } else if (r.ok) {
      card = resultCard({
        id,
        project: where,
        text: r.text,
        stats: {
          durationS: Math.round((Date.now() - (task?.startedAt ?? Date.now())) / 1000),
          tools: this.session?.tools ?? 0,
          ...(diff && diff.files > 0 ? diff : {}),
        },
        ...(this.visual ? { visual: this.visual } : {}),
      });
      speech = speechFor(r.text);
    } else if (r.subtype === 'error_max_turns') {
      card = errorCard(id, where, 'Hit the step limit', 'Say "continue" to keep going.');
      speech = 'I hit the step limit. Say continue to keep going.';
    } else {
      card = errorCard(id, where, 'Something went wrong', r.text || r.subtype);
      speech = `Something went wrong. ${speechFor(r.text).slice(0, 160)}`;
    }

    this.card = card;
    this.task = undefined;
    this.stopping = false;
    this.deps.walkLog?.('claude', `${card.title}${card.lines.length ? ` — ${card.lines.join(' ')}` : ''}`);
    this.store.set({
      phase: this.asks.pending ? 'asking' : 'idle',
      card,
      project: where,
      projects: this.workspaces.repos(),
      activity: undefined,
      startedAt: undefined,
      live: undefined,
      transcript: undefined,
    });
    if (speech) this.speak(speech);
  }

  private trouble(kind: 'login' | 'limit' | 'crash' | 'overloaded', detail: string): void {
    this.deps.log(`trouble: ${kind} (${detail})`);
    if (kind === 'overloaded') {
      this.store.set({ note: 'Claude is busy, retrying' });
      return;
    }
    const [title, spoken] =
      kind === 'login'
        ? ['Claude login expired', 'The Claude login on your PC has expired. Sign in again at the desk.']
        : kind === 'limit'
          ? ['Usage limit reached', 'Your Claude usage limit is reached. Try again later.']
          : ['Claude stopped unexpectedly', 'The Claude process on your PC stopped. Your next request starts it again.'];
    this.card = errorCard(randomUUID().slice(0, 8), this.label(), title, kind === 'crash' ? detail : undefined);
    this.task = undefined;
    if (kind === 'crash') {
      this.session?.dispose();
      this.session = undefined;
    }
    this.store.set({ phase: 'idle', card: this.card, activity: undefined, startedAt: undefined, live: undefined });
    this.speak(spoken);
  }

  // ---- commands --------------------------------------------------------------

  private async command(name: CommandName, arg?: string): Promise<void> {
    switch (name) {
      case 'talk':
        this.deps.send({ v: 1, t: 'listen', on: true });
        break;

      case 'stop':
        if (!this.session?.busy && !this.asks.pending) {
          this.speak('Nothing is running.', false);
          break;
        }
        this.stopping = true;
        this.asks.cancel();
        await this.session?.interrupt();
        this.speak('Stopped.', false);
        break;

      case 'status':
        this.speak(this.statusText(), false);
        break;

      case 'repeat':
        this.speak(this.lastSpeech ?? 'Nothing to repeat yet.', false);
        break;

      case 'undo': {
        if (this.session?.busy) {
          this.speak('Claude is still working. Say stop first.', false);
          break;
        }
        const point = this.undo.at(-1);
        if (!point) {
          this.speak('Nothing to undo.', false);
          break;
        }
        const reverted = await restoreAll(this.workspaces.current().path, point);
        if (!reverted) {
          this.speak('I could not undo that.', false);
          break;
        }
        this.undo.pop();
        const msg = reverted.files === 0 ? 'Nothing had changed.' : `Undone. ${reverted.files} ${reverted.files === 1 ? 'file' : 'files'} restored.`;
        this.card = { id: randomUUID().slice(0, 8), kind: 'info', title: reverted.files === 0 ? 'Nothing to undo' : 'Undone', lines: [msg], project: this.label(), at: Date.now() };
        this.store.set({ card: this.card, note: undefined });
        // Claude must know the files changed under it; it hears so with the next prompt.
        if (reverted.files > 0) {
          this.preface = '(Note from the bridge: the user said "undo that", so the file changes from your previous task were reverted on disk. Commits stay. Re-read files before editing and do not redo those changes unless asked.)';
        }
        this.speak(msg, false);
        break;
      }

      case 'new':
        this.asks.cancel();
        this.session?.dispose(true);
        this.session = undefined;
        this.card = undefined;
        this.task = undefined;
        this.undo = [];
        this.preface = undefined;
        this.workspaces.fresh();
        this.store.set({
          phase: 'idle',
          project: this.label(),
          projects: [],
          card: undefined,
          activity: undefined,
          startedAt: undefined,
          live: undefined,
          transcript: undefined,
          note: undefined,
        });
        this.speak('New session with an empty work folder. Which repo?', false);
        break;

      case 'switch': {
        const target = arg ? matchProject(arg, this.workspaces.repos().map((n) => ({ name: n, aliases: [] }))) : undefined;
        if (!target) {
          this.speak(`There is no ${arg ?? 'such'} repo in this session yet. Ask me to get it.`, false);
          break;
        }
        this.workspaces.update({ focus: target });
        this.preface = `(Note from the bridge: the user switched to the "${target}" folder. Work there from now on.)`;
        this.store.set({ project: target, note: undefined });
        this.speak(`Switched to ${target}.`, false);
        break;
      }
    }
  }

  private statusText(): string {
    const s = this.store.state;
    const focus = this.workspaces.current().focus;
    if (s.ask) return `Waiting for you. ${s.ask.title}`;
    if (s.phase === 'working') {
      const since = s.startedAt ? ` for ${spokenDuration(Date.now() - s.startedAt)}` : '';
      return `Working${focus ? ` on ${focus}` : ''}${since}. ${s.activity ?? ''}`.trim();
    }
    const idle = focus ? `${focus} is idle.` : 'Idle, no repo yet.';
    return s.card ? `${idle} Last result: ${s.card.title}.` : idle;
  }

  // ---- speech out --------------------------------------------------------------

  private speak(text: string, remember = true): void {
    if (remember) this.lastSpeech = text;
    const phoneFresh = Date.now() - (this.seen.get('phone') ?? 0) < PHONE_FRESH_MS;
    this.deps.send({ v: 1, t: 'speak', id: randomUUID().slice(0, 8), text, to: phoneFresh ? 'phone' : 'lens' });
  }
}
