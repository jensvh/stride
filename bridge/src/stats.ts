// Checkpoints and change counts through git, without touching the user's
// index, branches or history. A checkpoint is a tree object of the working
// directory (tracked and untracked files, .gitignore respected).
import { copyFile, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { git } from './git.ts';

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

// ---- several repositories in one work folder ---------------------------------

/** Repository folder name → checkpoint. */
export type Checkpoint = Record<string, string>;

export async function snapshotAll(root: string, folders: string[]): Promise<Checkpoint> {
  const cp: Checkpoint = {};
  for (const f of folders) {
    const tree = await snapshot(join(root, f));
    if (tree) cp[f] = tree;
  }
  return cp;
}

const add = (a: DiffStat, b: DiffStat): DiffStat => ({ files: a.files + b.files, added: a.added + b.added, removed: a.removed + b.removed });
const NONE: DiffStat = { files: 0, added: 0, removed: 0 };

/** What changed between two checkpoints, summed over the repositories in both. */
export async function diffAll(root: string, before: Checkpoint, after: Checkpoint): Promise<DiffStat> {
  let total = NONE;
  for (const [f, tree] of Object.entries(before)) {
    const now = after[f];
    if (now && now !== tree) total = add(total, await diffStat(join(root, f), tree, now));
  }
  return total;
}

/** Puts every repository of a checkpoint back. Undefined when one could not be restored. */
export async function restoreAll(root: string, cp: Checkpoint): Promise<DiffStat | undefined> {
  let total = NONE;
  for (const [f, tree] of Object.entries(cp)) {
    const r = await restore(join(root, f), tree);
    if (!r) return undefined;
    total = add(total, r);
  }
  return total;
}
