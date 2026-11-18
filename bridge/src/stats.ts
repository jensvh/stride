// Checkpoints and change counts through git, without touching the user's
// index, branches or history. A checkpoint is a tree object of the working
// directory (tracked and untracked files, .gitignore respected).
import { execFile } from 'node:child_process';
import { copyFile, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { promisify } from 'node:util';

const run = promisify(execFile);

async function git(cwd: string, args: string[], env?: Record<string, string>): Promise<string> {
  const { stdout } = await run('git', args, {
    cwd,
    env: { ...process.env, ...env },
    maxBuffer: 32 * 1024 * 1024,
    windowsHide: true,
  });
  return stdout.replace(/\r?\n$/, '');
}

async function topLevel(cwd: string): Promise<string | undefined> {
  try {
    return await git(cwd, ['rev-parse', '--show-toplevel']);
  } catch {
    return undefined;
  }
}

/** Tree id of the working directory as it is now, or undefined outside a git repository. */
export async function snapshot(cwd: string): Promise<string | undefined> {
  const top = await topLevel(cwd);
  if (!top) return undefined;
  const dir = await mkdtemp(join(tmpdir(), 'stride-idx-'));
  const tmpIndex = join(dir, 'index');
  try {
    const realIndex = await git(top, ['rev-parse', '--git-path', 'index']);
    // Starting from the real index makes `add -A` only hash what changed.
    await copyFile(resolve(top, realIndex), tmpIndex).catch(() => undefined);
    const env = { GIT_INDEX_FILE: tmpIndex };
    await git(top, ['add', '-A'], env);
    return await git(top, ['write-tree'], env);
  } catch {
    return undefined;
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

export type DiffStat = { files: number; added: number; removed: number };

export async function diffStat(cwd: string, before: string, after: string): Promise<DiffStat> {
  const out = await git(cwd, ['diff', '--shortstat', before, after]).catch(() => '');
  const n = (re: RegExp) => Number(re.exec(out)?.[1] ?? 0);
  return {
    files: n(/(\d+) files? changed/),
    added: n(/(\d+) insertions?\(\+\)/),
    removed: n(/(\d+) deletions?\(-\)/),
  };
}

/** Puts the working directory back to a checkpoint. Returns what was reverted. */
export async function restore(cwd: string, tree: string): Promise<DiffStat | undefined> {
  const top = await topLevel(cwd);
  if (!top) return undefined;
  const now = await snapshot(cwd);
  if (!now) return undefined;
  if (now === tree) return { files: 0, added: 0, removed: 0 };
  const stat = await diffStat(top, tree, now);
  const created = (await git(top, ['diff', '--name-only', '--diff-filter=A', '-z', tree, now]))
    .split('\0')
    .filter(Boolean);
  for (const f of created) await rm(resolve(top, f), { force: true });
  await git(top, ['restore', `--source=${tree}`, '--worktree', '--', ':/']);
  return stat;
}
