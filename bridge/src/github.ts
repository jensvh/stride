// The user's GitHub repositories, as seen by the bridge only. Claude never gets
// a token: it asks the bridge (repoTools.ts) to list, clone and publish, and the
// bridge checks every repository against the user's own list first.
//
// "The user's own list" is what GitHub returns for
// affiliation=owner,collaborator,organization_member: repositories the user
// owns, those of organizations they belong to, and those shared with them.
// Any other public repository is not on it.

export type Repo = {
  fullName: string;
  owner: string;
  name: string;
  private: boolean;
  defaultBranch: string;
  canPush: boolean;
  /** The configured account that reaches this repository. */
  account: string;
  description?: string;
  pushedAt?: string;
};

/** bridge/.env variable that holds the token of an account: jensvh → GITHUB_TOKEN_JENSVH. */
export const tokenVar = (account: string) => `GITHUB_TOKEN_${account.toUpperCase().replace(/[^A-Z0-9]/g, '_')}`;

export type GitHubOptions = {
  accounts: string[];
  token?: (account: string) => string | undefined;
  fetch?: typeof fetch;
  api?: string;
  /** Where git clones from and pushes to. Tests point this at local bare repositories. */
  remote?: (fullName: string) => string;
  log?: (msg: string) => void;
};

const CACHE_MS = 10 * 60_000;

type ApiRepo = {
  full_name: string;
  name: string;
  owner: { login: string };
  private: boolean;
  default_branch: string;
  description: string | null;
  pushed_at: string | null;
  permissions?: { push?: boolean };
};

export class GitHub {
  readonly accounts: string[];
  private readonly tokenOf: (account: string) => string | undefined;
  private readonly http: typeof fetch;
  private readonly api: string;
  private readonly remote: (fullName: string) => string;
  private readonly log: (msg: string) => void;
  private cache: { at: number; repos: Repo[] } | undefined;

  constructor(opts: GitHubOptions) {
    this.accounts = opts.accounts;
    this.tokenOf = opts.token ?? ((a) => process.env[tokenVar(a)]?.trim() || undefined);
    this.http = opts.fetch ?? fetch;
    this.api = opts.api ?? 'https://api.github.com';
    this.remote = opts.remote ?? ((full) => `https://github.com/${full}.git`);
    this.log = opts.log ?? (() => {});
  }

  remoteUrl(fullName: string): string {
    return this.remote(fullName);
  }

  /**
   * Environment for one git child process that talks to GitHub as `account`.
   * The token travels in an HTTP header set through the environment, so it is
   * never written to the repository's config. Git's own credential helpers are
   * switched off for that process.
   */
  gitEnv(account: string): Record<string, string> {
    const token = this.tokenOf(account);
    const env: Record<string, string> = {
      GIT_TERMINAL_PROMPT: '0',
      GCM_INTERACTIVE: 'never',
      GIT_CONFIG_COUNT: '1',
      GIT_CONFIG_KEY_0: 'credential.helper',
      GIT_CONFIG_VALUE_0: '',
    };
    if (token) {
      env.GIT_CONFIG_COUNT = '2';
      env.GIT_CONFIG_KEY_1 = 'http.https://github.com/.extraheader';
      env.GIT_CONFIG_VALUE_1 = `AUTHORIZATION: basic ${Buffer.from(`x-access-token:${token}`).toString('base64')}`;
    }
    return env;
  }

  private async request(account: string, path: string, init: RequestInit = {}): Promise<Response> {
    const token = this.tokenOf(account);
    if (!token) throw new Error(`No GitHub token for ${account}. Set ${tokenVar(account)} in bridge/.env.`);
    return this.http(`${this.api}${path}`, {
      ...init,
      headers: {
        Accept: 'application/vnd.github+json',
        Authorization: `Bearer ${token}`,
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'stride-bridge',
        ...(init.body ? { 'Content-Type': 'application/json' } : {}),
      },
      signal: AbortSignal.timeout(20_000),
    });
  }

  /** Startup check: one line per account, and whether anything is wrong. */
  async check(): Promise<{ lines: string[]; ok: boolean }> {
    const lines: string[] = [];
    let ok = true;
    for (const account of this.accounts) {
      if (!this.tokenOf(account)) {
        lines.push(`github ${account}: no token, set ${tokenVar(account)} in bridge/.env`);
        ok = false;
        continue;
      }
      try {
        const res = await this.request(account, '/user');
        if (!res.ok) {
          lines.push(`github ${account}: token refused (${res.status})`);
          ok = false;
          continue;
        }
        const login = ((await res.json()) as { login: string }).login;
        const scopes = res.headers.get('x-oauth-scopes');
        if (login.toLowerCase() !== account.toLowerCase()) {
          lines.push(`github ${account}: the token belongs to ${login}, not ${account}`);
          ok = false;
          continue;
        }
        const warn = scopes !== null && !scopes.split(/,\s*/).includes('repo') ? ' (no "repo" scope: private repositories will be missing)' : '';
        lines.push(`github ${account}: ok${warn}`);
      } catch (err) {
        lines.push(`github ${account}: ${err instanceof Error ? err.message : String(err)}`);
        ok = false;
      }
    }
    return { lines, ok };
  }

  /** Every repository the configured accounts may use, newest activity first. Cached for 10 minutes. */
  async repos(force = false): Promise<Repo[]> {
    if (!force && this.cache && Date.now() - this.cache.at < CACHE_MS) return this.cache.repos;
    const byName = new Map<string, Repo>();
    const errors: string[] = [];
    for (const account of this.accounts) {
      if (!this.tokenOf(account)) continue;
      try {
        for (let page = 1; page <= 10; page++) {
          const res = await this.request(
            account,
            `/user/repos?affiliation=owner,collaborator,organization_member&sort=pushed&per_page=100&page=${page}`,
          );
          if (!res.ok) throw new Error(`GitHub answered ${res.status}`);
          const list = (await res.json()) as ApiRepo[];
          for (const x of list) {
            const repo: Repo = {
              fullName: x.full_name,
              owner: x.owner.login,
              name: x.name,
              private: x.private,
              defaultBranch: x.default_branch,
              canPush: x.permissions?.push === true,
              account,
              ...(x.description ? { description: x.description } : {}),
              ...(x.pushed_at ? { pushedAt: x.pushed_at } : {}),
            };
            const key = repo.fullName.toLowerCase();
            const prev = byName.get(key);
            if (!prev || (!prev.canPush && repo.canPush)) byName.set(key, repo);
          }
          if (list.length < 100) break;
        }
      } catch (err) {
        errors.push(`${account}: ${err instanceof Error ? err.message : String(err)}`);
      }
    }
    if (byName.size === 0 && errors.length) throw new Error(`Could not list repositories (${errors.join('; ')})`);
    for (const e of errors) this.log(`github: ${e}`);
    const repos = [...byName.values()].sort((a, b) => (b.pushedAt ?? '').localeCompare(a.pushedAt ?? ''));
    this.cache = { at: Date.now(), repos };
    return repos;
  }

  private readonly identities = new Map<string, { name: string; email: string }>();

  /** Commit identity for an account, with GitHub's private no-reply address. */
  async identity(account: string): Promise<{ name: string; email: string } | undefined> {
    const known = this.identities.get(account);
    if (known) return known;
    try {
      const res = await this.request(account, '/user');
      if (!res.ok) return undefined;
      const u = (await res.json()) as { id: number; login: string; name?: string | null };
      const who = { name: u.name || u.login, email: `${u.id}+${u.login}@users.noreply.github.com` };
      this.identities.set(account, who);
      return who;
    } catch {
      return undefined;
    }
  }

  /** The repository with this full name, if it is on the user's list. */
  async get(fullName: string): Promise<Repo | undefined> {
    const want = fullName.toLowerCase();
    const hit = (await this.repos()).find((r) => r.fullName.toLowerCase() === want);
    return hit ?? (await this.repos(true)).find((r) => r.fullName.toLowerCase() === want);
  }

  /** Opens a pull request, or returns the one already open for this branch. */
  async openPullRequest(repo: Repo, args: { head: string; title: string; body: string }): Promise<{ number: number; url: string; existed: boolean }> {
    const open = await this.request(repo.account, `/repos/${repo.fullName}/pulls?state=open&head=${encodeURIComponent(`${repo.owner}:${args.head}`)}`);
    if (open.ok) {
      const list = (await open.json()) as { number: number; html_url: string }[];
      if (list[0]) return { number: list[0].number, url: list[0].html_url, existed: true };
    }
    const res = await this.request(repo.account, `/repos/${repo.fullName}/pulls`, {
      method: 'POST',
      body: JSON.stringify({ title: args.title, head: args.head, base: repo.defaultBranch, body: args.body }),
    });
    if (!res.ok) {
      const detail = await res.text().catch(() => '');
      throw new Error(`GitHub refused the pull request (${res.status}): ${detail.slice(0, 300)}`);
    }
    const pr = (await res.json()) as { number: number; html_url: string };
    return { number: pr.number, url: pr.html_url, existed: false };
  }
}

// ---- finding a repository by what the user said --------------------------------

const norm = (s: string) => s.toLowerCase().replace(/[^a-z0-9]/g, '');
const words = (s: string) =>
  s
    .replace(/([a-z])([A-Z])/g, '$1 $2')
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter(Boolean);

/**
 * Matches a spoken or typed name against the user's repositories. A clear
 * winner is `match`; otherwise `candidates` holds the closest few, newest first.
 */
export function matchRepos(query: string, repos: Repo[]): { match?: Repo; candidates: Repo[] } {
  const q = query
    .trim()
    .replace(/^https?:\/\/github\.com\//i, '')
    .replace(/\.git$/i, '')
    .replace(/\/+$/, '')
    .replace(/^(the|my|our)\s+/i, '')
    .replace(/\s+(repo|repository|project)$/i, '');
  const slash = q.indexOf('/');
  const ownerPart = slash > 0 ? q.slice(0, slash) : undefined;
  const namePart = slash > 0 ? q.slice(slash + 1) : q;
  const nq = norm(namePart);
  const no = ownerPart ? norm(ownerPart) : undefined;
  if (!nq) return { candidates: [] };
  const qWords = words(namePart).filter((w) => w.length >= 3);

  const scored = repos
    .map((r) => {
      if (no && norm(r.owner) !== no) return { r, s: 0 };
      const nn = norm(r.name);
      let s = 0;
      if (nn === nq) s = 100;
      else if (nq.length >= 4 && nn.length >= 4 && (nn.startsWith(nq) || nq.startsWith(nn))) s = 70;
      else if (nq.length >= 4 && nn.includes(nq)) s = 50;
      else {
        const have = new Set(words(r.name));
        const hits = qWords.filter((w) => have.has(w)).length;
        if (hits) s = 20 + 10 * hits;
      }
      return { r, s };
    })
    .filter((x) => x.s > 0)
    .sort((a, b) => b.s - a.s || (b.r.pushedAt ?? '').localeCompare(a.r.pushedAt ?? ''));

  const top = scored[0];
  if (!top) return { candidates: [] };
  const tied = scored.filter((x) => x.s === top.s).length;
  if (top.s >= 70 && tied === 1) return { match: top.r, candidates: [] };
  return { candidates: scored.slice(0, 6).map((x) => x.r) };
}
