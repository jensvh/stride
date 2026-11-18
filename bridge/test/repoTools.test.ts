// get_repo and publish against local bare repositories standing in for GitHub.
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { GitHub } from '../src/github.ts';
import { getRepo, publish, publishTarget, type RepoToolsContext } from '../src/repoTools.ts';

let dir: string;
let ws: string;
let cloned: string[];
let prs: Record<string, unknown>[];
let ctx: RepoToolsContext;

const git = (cwd: string, ...args: string[]) => execFileSync('git', args, { cwd, windowsHide: true }).toString().trim();
const remoteDir = (full: string) => join(dir, 'remotes', `${full}.git`);

function seed(full: string) {
  const bare = remoteDir(full);
  mkdirSync(bare, { recursive: true });
  git(bare, 'init', '-q', '--bare', '--initial-branch=main');
  const tmp = join(dir, 'seed', full);
  mkdirSync(tmp, { recursive: true });
  git(tmp, 'init', '-q', '--initial-branch=main');
  writeFileSync(join(tmp, 'price.js'), 'export const vat = 0.2;\n');
  git(tmp, 'add', '-A');
  git(tmp, '-c', 'user.name=s', '-c', 'user.email=s@s', 'commit', '-q', '-m', 'init');
  git(tmp, 'push', '-q', pathToFileURL(bare).href, 'main');
}

const apiRepo = (full: string, push = true) => ({
  full_name: full,
  name: full.split('/')[1],
  owner: { login: full.split('/')[0] },
  private: true,
  default_branch: 'main',
  description: null,
  pushed_at: '2026-11-01T00:00:00Z',
  permissions: { push },
});

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'stride-repo-'));
  ws = join(dir, 'ws');
  mkdirSync(ws);
  seed('acme/Ledger');
  seed('work-org/readonly');
  cloned = [];
  prs = [];
  const fake = (async (url: string, init?: RequestInit) => {
    const u = new URL(url);
    if (u.pathname === '/user/repos') return Response.json([apiRepo('acme/Ledger'), apiRepo('work-org/readonly', false)]);
    if (u.pathname === '/user') return Response.json({ id: 42, login: 'tester', name: null });
    if (u.pathname.endsWith('/pulls') && init?.method === 'POST') {
      prs.push(JSON.parse(String(init.body)) as Record<string, unknown>);
      return Response.json({ number: 7, html_url: 'https://github.com/acme/Ledger/pull/7' });
    }
    if (u.pathname.endsWith('/pulls')) return Response.json([]);
    return new Response('not found', { status: 404 });
  }) as typeof fetch;
  ctx = {
    github: new GitHub({ accounts: ['tester'], token: () => 'tok', fetch: fake, remote: (full) => pathToFileURL(remoteDir(full)).href }),
    workspace: () => ws,
    onCloned: (folder) => cloned.push(folder),
    log: () => {},
  };
});
afterEach(() => rmSync(dir, { recursive: true, force: true, maxRetries: 20, retryDelay: 50 }));

describe('get_repo', () => {
  it('clones one of the user\'s repositories by its spoken name', async () => {
    const r = await getRepo(ctx, { name: 'the ledger repo' });
    expect(r.isError).toBeUndefined();
    expect(r.text).toMatch(/Cloned acme\/Ledger into the folder "Ledger"/);
    expect(readFileSync(join(ws, 'Ledger', 'price.js'), 'utf8')).toContain('vat');
    expect(cloned).toEqual(['Ledger']);
    // Commits made here carry the account's no-reply address, not a personal one.
    expect(git(join(ws, 'Ledger'), 'config', 'user.email')).toBe('42+tester@users.noreply.github.com');
  });

  it('fetches instead of cloning twice', async () => {
    await getRepo(ctx, { name: 'Ledger' });
    const again = await getRepo(ctx, { name: 'acme/Ledger' });
    expect(again.text).toMatch(/already in the folder "Ledger"/);
  });

  it('refuses repositories that are not on the user\'s list', async () => {
    const r = await getRepo(ctx, { name: 'torvalds/linux' });
    expect(r.isError).toBe(true);
    expect(r.text).toMatch(/not other public ones/);
  });
});

describe('publish', () => {
  it('commits, pushes a new branch and opens a pull request, never touching main', async () => {
    await getRepo(ctx, { name: 'Ledger' });
    const repo = join(ws, 'Ledger');
    writeFileSync(join(repo, 'price.js'), 'export const vat = 0.21;\n');
    const r = await publish(ctx, { repo: 'Ledger', title: 'Use the Belgian VAT rate', body: 'VAT is 21% here.' });
    expect(r.isError).toBeUndefined();
    expect(r.text).toMatch(/Pushed 1 commit to branch stride\/use-the-belgian-vat-rate .* pull request 7/);
    const bare = remoteDir('acme/Ledger');
    expect(git(bare, 'show', 'stride/use-the-belgian-vat-rate:price.js')).toContain('0.21');
    expect(git(bare, 'show', 'main:price.js')).toContain('0.2;');
    expect(prs[0]).toMatchObject({ head: 'stride/use-the-belgian-vat-rate', base: 'main', title: 'Use the Belgian VAT rate' });
    expect(String(prs[0]!.body)).toMatch(/^VAT is 21% here\./);
  });

  it('says why before the user is asked: nothing to publish, read only, foreign folder', async () => {
    await getRepo(ctx, { name: 'Ledger' });
    expect(await publishTarget(ctx, { repo: 'Ledger' })).toMatch(/Nothing to publish/);
    await getRepo(ctx, { name: 'work-org/readonly' });
    writeFileSync(join(ws, 'readonly', 'x.txt'), 'x');
    expect(await publishTarget(ctx, { repo: 'readonly' })).toMatch(/only read/);
    expect(await publishTarget(ctx, { repo: '../elsewhere' })).toMatch(/not a repository folder/);
  });

  it('refuses when the origin was pointed somewhere else', async () => {
    await getRepo(ctx, { name: 'Ledger' });
    const repo = join(ws, 'Ledger');
    git(repo, 'remote', 'set-url', 'origin', 'https://github.com/someone/else.git');
    writeFileSync(join(repo, 'price.js'), 'changed\n');
    expect(await publishTarget(ctx, { repo: 'Ledger' })).toMatch(/origin .* was changed/);
  });
});
