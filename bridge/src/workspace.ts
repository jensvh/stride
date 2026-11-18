// One empty work folder per conversation. Claude works only in there, the
// user's repositories are cloned into it on request, and folders that have not
// been used for a while are deleted.
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

/** Every work folder carries this file; cleanup never touches a folder without it. */
const MARKER = '.stride-workspace';

export type Workspace = {
  path: string;
  created: number;
  lastUsed: number;
  /** Claude conversation to resume after a bridge restart. */
  sessionId?: string;
  /** The repository folder the user is working on, shown on the lens. */
  focus?: string;
};

const pad = (n: number) => String(n).padStart(2, '0');
const stamp = (d: Date) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}-${pad(d.getHours())}${pad(d.getMinutes())}`;

export class Workspaces {
  readonly root: string;
  private readonly keepMs: number;
  private readonly stateFile: string;
  private readonly log: (msg: string) => void;
  private ws: Workspace | undefined;

  constructor(opts: { root: string; keepDays: number; stateFile: string; log?: (msg: string) => void }) {
    this.root = resolve(opts.root);
    this.keepMs = opts.keepDays * 86_400_000;
    this.stateFile = opts.stateFile;
    this.log = opts.log ?? (() => {});
  }

  /** The folder of the current conversation, created on first use. */
  current(): Workspace {
    if (!this.ws) {
      const saved = this.load();
      // A folder unused for longer than the keep period starts over.
      this.ws = saved && Date.now() - saved.lastUsed < this.keepMs ? saved : this.create();
      this.save();
    }
    return this.ws;
  }

  /** A new, empty folder for a new conversation. */
  fresh(): Workspace {
    this.ws = this.create();
    this.save();
    return this.ws;
  }

  update(patch: Partial<Pick<Workspace, 'sessionId' | 'focus'>>): void {
    const ws = this.current();
    for (const [k, v] of Object.entries(patch) as [keyof typeof patch, string | undefined][]) {
      if (v === undefined) delete ws[k];
      else ws[k] = v;
    }
    this.save();
  }

  touch(): void {
    const ws = this.current();
    ws.lastUsed = Date.now();
    this.save();
    this.writeMarker(ws);
  }

  /** Repository folders in the current work folder, by name. */
  repos(): string[] {
    const { path } = this.current();
    try {
      return readdirSync(path, { withFileTypes: true })
        .filter((d) => d.isDirectory() && existsSync(join(path, d.name, '.git')))
        .map((d) => d.name)
        .sort((a, b) => a.localeCompare(b));
    } catch {
      return [];
    }
  }

  /** Deletes work folders unused for longer than the keep period. Returns their names. */
  cleanup(now = Date.now()): string[] {
    const removed: string[] = [];
    let entries: string[];
    try {
      entries = readdirSync(this.root);
    } catch {
      return removed;
    }
    const current = this.ws?.path;
    for (const name of entries) {
      const dir = join(this.root, name);
      const marker = join(dir, MARKER);
      if (dir === current || !existsSync(marker)) continue;
      let lastUsed: number;
      try {
        const m = JSON.parse(readFileSync(marker, 'utf8')) as { lastUsed?: number; created?: number };
        lastUsed = m.lastUsed ?? m.created ?? statSync(marker).mtimeMs;
      } catch {
        lastUsed = statSync(marker).mtimeMs;
      }
      if (now - lastUsed < this.keepMs) continue;
      try {
        rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
        removed.push(name);
      } catch (err) {
        this.log(`could not remove old work folder ${name}: ${String(err)}`);
      }
    }
    if (removed.length) this.log(`removed ${removed.length} old work folder(s): ${removed.join(', ')}`);
    return removed;
  }

  private create(): Workspace {
    mkdirSync(this.root, { recursive: true });
    const base = stamp(new Date());
    let path = join(this.root, base);
    for (let n = 2; existsSync(path); n++) path = join(this.root, `${base}-${n}`);
    mkdirSync(path);
    const now = Date.now();
    const ws: Workspace = { path, created: now, lastUsed: now };
    this.writeMarker(ws);
    this.log(`new work folder ${path}`);
    return ws;
  }

  private writeMarker(ws: Workspace): void {
    writeFileSync(join(ws.path, MARKER), JSON.stringify({ created: ws.created, lastUsed: ws.lastUsed }));
  }

  private load(): Workspace | undefined {
    try {
      const ws = JSON.parse(readFileSync(this.stateFile, 'utf8')) as Workspace;
      // Only folders this bridge made, under the configured root, are reused.
      if (resolve(ws.path, '..') !== this.root || !existsSync(join(ws.path, MARKER))) return undefined;
      return ws;
    } catch {
      return undefined;
    }
  }

  private save(): void {
    if (!this.ws) return;
    try {
      writeFileSync(this.stateFile, JSON.stringify(this.ws, null, 2));
    } catch (err) {
      this.log(`could not save the work folder state: ${String(err)}`);
    }
  }
}
