import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { Workspaces } from '../src/workspace.ts';

let dir: string;
const make = () => new Workspaces({ root: join(dir, 'work'), keepDays: 7, stateFile: join(dir, 'ws.json') });

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'stride-ws-'));
});
afterEach(() => rmSync(dir, { recursive: true, force: true, maxRetries: 10 }));

describe('work folders', () => {
  it('creates a marked folder under the root on first use and keeps it across restarts', () => {
    const a = make();
    const ws = a.current();
    expect(dirname(ws.path)).toBe(join(dir, 'work'));
    expect(existsSync(join(ws.path, '.stride-workspace'))).toBe(true);
    a.update({ sessionId: 'abc', focus: 'api' });
    const b = make().current();
    expect(b).toMatchObject({ path: ws.path, sessionId: 'abc', focus: 'api' });
  });

  it('gives a new conversation a new, empty folder', () => {
    const w = make();
    const first = w.current().path;
    const second = w.fresh().path;
    expect(second).not.toBe(first);
    expect(w.current().focus).toBeUndefined();
  });

  it('lists the repositories cloned into the folder', () => {
    const w = make();
    const p = w.current().path;
    mkdirSync(join(p, 'web', '.git'), { recursive: true });
    mkdirSync(join(p, 'api', '.git'), { recursive: true });
    mkdirSync(join(p, 'notes'));
    expect(w.repos()).toEqual(['api', 'web']);
  });

  it('deletes only old folders it made itself, never the current one', () => {
    const w = make();
    const old = w.current().path;
    writeFileSync(join(old, 'x.txt'), 'x');
    const current = w.fresh().path;
    const foreign = join(dir, 'work', 'not-ours');
    mkdirSync(foreign);
    const removed = w.cleanup(Date.now() + 8 * 86_400_000);
    expect(removed).toEqual([basename(old)]);
    expect(existsSync(old)).toBe(false);
    expect(existsSync(current)).toBe(true);
    expect(existsSync(foreign)).toBe(true);
    expect(w.cleanup()).toEqual([]);
  });
});
