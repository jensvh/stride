import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { diffStat, restore, snapshot } from '../src/stats.ts';

let repo: string;
const git = (...args: string[]) => execFileSync('git', args, { cwd: repo, encoding: 'utf8' }).trim();
const write = (name: string, text: string) => {
  mkdirSync(join(repo, name, '..'), { recursive: true });
  writeFileSync(join(repo, name), text);
};

beforeEach(() => {
  repo = mkdtempSync(join(tmpdir(), 'stride-test-'));
  git('init', '-q', '-b', 'main');
  git('config', 'user.email', 'test@example.invalid');
  git('config', 'user.name', 'test');
  git('config', 'core.autocrlf', 'false');
  write('kept.txt', 'one\ntwo\n');
  write('removed.txt', 'bye\n');
  git('add', '-A');
  git('commit', '-q', '-m', 'init');
  // Uncommitted work the user already had before the voice task:
  write('kept.txt', 'one\ntwo\nmine\n');
  write('draft.txt', 'my untracked notes\n');
});
afterEach(() => rmSync(repo, { recursive: true, force: true }));

describe('checkpoints', () => {
  it('returns undefined outside a git repository', async () => {
    const plain = mkdtempSync(join(tmpdir(), 'stride-plain-'));
    try {
      expect(await snapshot(plain)).toBeUndefined();
    } finally {
      rmSync(plain, { recursive: true, force: true });
    }
  });

  it('does not touch the real index or history', async () => {
    const statusBefore = git('status', '--porcelain');
    const head = git('rev-parse', 'HEAD');
    expect(await snapshot(repo)).toMatch(/^[0-9a-f]{40}$/);
    expect(git('status', '--porcelain')).toBe(statusBefore);
    expect(git('rev-parse', 'HEAD')).toBe(head);
  });

  it('counts what a task changed, including new files', async () => {
    const before = (await snapshot(repo))!;
    write('kept.txt', 'one\nTWO\nmine\nmore\n');
    write('src/new.ts', 'export {};\n');
    rmSync(join(repo, 'removed.txt'));
    const after = (await snapshot(repo))!;
    expect(await diffStat(repo, before, after)).toEqual({ files: 3, added: 3, removed: 2 });
  });

  it('undo restores edits, brings back deleted files, removes created ones, and keeps earlier uncommitted work', async () => {
    const before = (await snapshot(repo))!;
    write('kept.txt', 'changed by the task\n');
    write('src/new.ts', 'export {};\n');
    rmSync(join(repo, 'removed.txt'));
    rmSync(join(repo, 'draft.txt'));

    const reverted = await restore(repo, before);

    expect(reverted?.files).toBe(4);
    expect(readFileSync(join(repo, 'kept.txt'), 'utf8')).toBe('one\ntwo\nmine\n');
    expect(readFileSync(join(repo, 'removed.txt'), 'utf8')).toBe('bye\n');
    expect(readFileSync(join(repo, 'draft.txt'), 'utf8')).toBe('my untracked notes\n');
    expect(existsSync(join(repo, 'src/new.ts'))).toBe(false);
    expect(await snapshot(repo)).toBe(before);
  });

  it('reports zero when nothing changed', async () => {
    const before = (await snapshot(repo))!;
    expect(await restore(repo, before)).toEqual({ files: 0, added: 0, removed: 0 });
  });
});
