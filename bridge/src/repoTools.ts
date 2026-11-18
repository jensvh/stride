// The tools Claude uses to reach GitHub, all executed by the bridge with tokens
// Claude never sees: find_repos, get_repo and publish. Only repositories on the
// user's own list (see github.ts) can be cloned or published to.
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { createSdkMcpServer, tool, type HookCallback } from '@anthropic-ai/claude-agent-sdk';
import { z } from 'zod';
import { git, isRepo } from './git.ts';
import { matchRepos, type GitHub, type Repo } from './github.ts';

export type RepoToolsContext = {
  github: GitHub;
  /** The current work folder. */
  workspace: () => string;
  onCloned: (folder: string, repo: Repo) => void;
  log: (msg: string) => void;
};

type Result = { text: string; isError?: boolean };
const fail = (text: string): Result => ({ text, isError: true });

const line = (r: Repo) =>
  `${r.fullName}${r.private ? ' (private)' : ''}${r.canPush ? '' : ' (read only)'}${r.description ? `: ${r.description.slice(0, 80)}` : ''}`;

export async function findRepos(ctx: RepoToolsContext, args: { query?: string }): Promise<Result> {
  const repos = await ctx.github.repos();
  if (!args.query) {
    return { text: `The user's most recently active repositories:\n${repos.slice(0, 15).map(line).join('\n')}` };
  }
  const { match, candidates } = matchRepos(args.query, repos);
  const list = match ? [match] : candidates;
  if (!list.length) return { text: `None of the user's ${repos.length} repositories matches "${args.query}".` };
  return { text: list.map(line).join('\n') };
}

/** Folder for a repository: its name, or owner-name when another repository already uses the name. */
async function folderFor(ctx: RepoToolsContext, repo: Repo): Promise<{ folder: string; exists: boolean }> {
  const ws = ctx.workspace();
  for (const folder of [repo.name, `${repo.owner}-${repo.name}`]) {
    const dir = join(ws, folder);
    if (!existsSync(dir)) return { folder, exists: false };
    const tagged = await git(dir, ['config', '--get', 'stride.repo']).catch(() => '');
    if (tagged.toLowerCase() === repo.fullName.toLowerCase()) return { folder, exists: true };
  }
  throw new Error(`Both ${repo.name} and ${repo.owner}-${repo.name} are taken in the work folder.`);
}

export async function getRepo(ctx: RepoToolsContext, args: { name: string }): Promise<Result> {
  let repos = await ctx.github.repos();
  let found = matchRepos(args.name, repos);
  if (!found.match && !found.candidates.length) {
    repos = await ctx.github.repos(true);
    found = matchRepos(args.name, repos);
  }
  const repo = found.match;
  if (!repo) {
    if (!found.candidates.length) {
      return fail(
        `None of the user's repositories matches "${args.name}". Only their own, organization and shared repositories are available, not other public ones. Ask the user for the exact name, or call find_repos.`,
      );
    }
    return fail(
      `Several of the user's repositories could be meant:\n${found.candidates.map(line).join('\n')}\nAsk the user which one (AskUserQuestion), then call get_repo with the full owner/name.`,
    );
  }

  const ws = ctx.workspace();
  const { folder, exists } = await folderFor(ctx, repo);
  const dir = join(ws, folder);
  const env = ctx.github.gitEnv(repo.account);
  if (exists) {
    await git(dir, ['fetch', '--prune', 'origin'], env, 300_000);
    ctx.onCloned(folder, repo);
    return { text: `${repo.fullName} is already in the folder "${folder}". Fetched the latest from GitHub; local changes are untouched.` };
  }
  ctx.log(`cloning ${repo.fullName} into ${folder}`);
  await git(ws, ['clone', '--no-tags', ctx.github.remoteUrl(repo.fullName), folder], env, 600_000);
  // Remembered so publish knows where this folder came from.
  await git(dir, ['config', 'stride.repo', repo.fullName]);
  // Commits carry the identity of the account that owns the access, with its no-reply address.
  const who = await ctx.github.identity(repo.account);
  if (who) {
    await git(dir, ['config', 'user.name', who.name]);
    await git(dir, ['config', 'user.email', who.email]);
  }
  ctx.onCloned(folder, repo);
  const note = repo.canPush ? '' : ' The user can only read this repository, so publish will not work for it.';
  return { text: `Cloned ${repo.fullName} into the folder "${folder}" (default branch ${repo.defaultBranch}). Work inside that folder.${note}` };
}

type Target = { dir: string; repo: Repo };

/** Checks a publish request before the user is asked to approve it. Returns the problem, if any. */
export async function publishTarget(ctx: RepoToolsContext, args: { repo: string }): Promise<Target | string> {
  const folder = args.repo.trim().replace(/[\\/]+$/, '');
  if (!/^[\w.-]+$/.test(folder) || folder === '.' || folder === '..') {
    return `"${args.repo}" is not a repository folder. Pass the folder name that get_repo reported.`;
  }
  const dir = join(ctx.workspace(), folder);
  if (!existsSync(dir) || !(await isRepo(dir))) return `There is no repository folder "${folder}" in the work folder.`;
  const fullName = await git(dir, ['config', '--get', 'stride.repo']).catch(() => '');
  if (!fullName) return `"${folder}" was not cloned with get_repo, so it cannot be published.`;
  const repo = await ctx.github.get(fullName);
  if (!repo) return `${fullName} is not one of the user's repositories.`;
  if (!repo.canPush) return `The user can only read ${repo.fullName}; publishing is not possible.`;
  const origin = await git(dir, ['remote', 'get-url', 'origin']).catch(() => '');
  if (origin !== ctx.github.remoteUrl(repo.fullName)) return `The origin of "${folder}" was changed; publishing is refused.`;
  const dirty = (await git(dir, ['status', '--porcelain'])).length > 0;
  const ahead = Number(await git(dir, ['rev-list', '--count', `origin/${repo.defaultBranch}..HEAD`]).catch(() => '0'));
  if (!dirty && ahead === 0) return `Nothing to publish in "${folder}": no changes and no new commits.`;
  return { dir, repo };
}

const slug = (s: string) =>
  s
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 40)
    .replace(/-+$/, '') || 'changes';

export async function publish(ctx: RepoToolsContext, args: { repo: string; title: string; body?: string }): Promise<Result> {
  const target = await publishTarget(ctx, args);
  if (typeof target === 'string') return fail(target);
  const { dir, repo } = target;
  const env = ctx.github.gitEnv(repo.account);

  if ((await git(dir, ['status', '--porcelain'])).length > 0) {
    await git(dir, ['add', '-A']);
    await git(dir, ['commit', '-q', '-m', args.title]);
  }

  // Never push to the default branch: changes always arrive as a pull request.
  let branch = await git(dir, ['rev-parse', '--abbrev-ref', 'HEAD']);
  if (branch === 'HEAD' || branch === repo.defaultBranch) {
    const base = `stride/${slug(args.title)}`;
    branch = base;
    for (let n = 2; ; n++) {
      const remote = await git(dir, ['ls-remote', '--heads', 'origin', branch], env, 60_000);
      const local = await git(dir, ['branch', '--list', branch]);
      if (!remote && !local) break;
      branch = `${base}-${n}`;
    }
    await git(dir, ['switch', '-q', '-c', branch]);
  }
  const commits = Number(await git(dir, ['rev-list', '--count', `origin/${repo.defaultBranch}..HEAD`]));

  ctx.log(`publishing ${repo.fullName} ${branch} (${commits} commit(s))`);
  // No force: if the branch moved on GitHub, the push fails and says so.
  await git(dir, ['push', '-q', 'origin', `HEAD:refs/heads/${branch}`], env, 300_000);
  await git(dir, ['branch', '-q', `--set-upstream-to=origin/${branch}`]).catch(() => undefined);

  const body = `${args.body?.trim() ? `${args.body.trim()}\n\n` : ''}---\nOpened by Claude Code through Stride.`;
  const pr = await ctx.github.openPullRequest(repo, { head: branch, title: args.title, body });
  return {
    text: `Pushed ${commits} commit${commits === 1 ? '' : 's'} to branch ${branch} of ${repo.fullName} and ${pr.existed ? 'updated' : 'opened'} pull request ${pr.number}: ${pr.url}`,
  };
}

// ---- wiring into the Agent SDK -------------------------------------------------

const wrap = (fn: () => Promise<Result>) =>
  fn()
    .catch((err: unknown) => fail(err instanceof Error ? err.message : String(err)))
    .then((r) => ({ content: [{ type: 'text' as const, text: r.text }], ...(r.isError ? { isError: true } : {}) }));

export function githubServer(ctx: RepoToolsContext) {
  return createSdkMcpServer({
    name: 'github',
    version: '1.0.0',
    tools: [
      tool(
        'find_repos',
        "Lists the user's GitHub repositories (their own, their organizations' and those shared with them). Without a query: the 15 most recently active. With a query: the best matches for a name.",
        { query: z.string().max(200).optional().describe('A repository name as the user said it, or owner/name.') },
        (args) => wrap(() => findRepos(ctx, args)),
        { alwaysLoad: true },
      ),
      tool(
        'get_repo',
        "Clones one of the user's GitHub repositories into the work folder, or fetches the latest if it is already there. The only way to get code. Pass the name as the user said it, or owner/name.",
        { name: z.string().min(1).max(200) },
        (args) => wrap(() => getRepo(ctx, args)),
        { alwaysLoad: true },
      ),
      tool(
        'publish',
        'Delivers your work: commits anything uncommitted in the repository folder, pushes it to a new branch (never the default branch) and opens a pull request. The user approves it first.',
        {
          repo: z.string().min(1).max(200).describe('The repository folder name in the work folder, as get_repo reported it.'),
          title: z.string().min(3).max(120).describe('Pull request title, also the commit message for uncommitted changes.'),
          body: z.string().max(4000).optional().describe('Pull request description in markdown: what changed and why.'),
        },
        (args) => wrap(() => publish(ctx, args)),
        { alwaysLoad: true },
      ),
    ],
  });
}

/** Refuses a publish that cannot work before the user is asked to approve it. */
export function publishHook(ctx: RepoToolsContext): HookCallback {
  return async (input) => {
    if (input.hook_event_name !== 'PreToolUse') return {};
    const args = (input.tool_input ?? {}) as { repo?: unknown };
    const problem = await publishTarget(ctx, { repo: String(args.repo ?? '') }).catch((err: unknown) => (err instanceof Error ? err.message : String(err)));
    if (typeof problem !== 'string') return {};
    return { hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: problem } };
  };
}
