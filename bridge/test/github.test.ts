import { describe, expect, it } from 'vitest';
import { GitHub, matchRepos, tokenVar, type Repo } from '../src/github.ts';

const repo = (fullName: string, over: Partial<Repo> = {}): Repo => {
  const [owner, name] = fullName.split('/') as [string, string];
  return { fullName, owner, name, private: true, defaultBranch: 'main', canPush: true, account: 'me', ...over };
};

const repos = [
  repo('acme/Ledger', { pushedAt: '2026-11-17' }),
  repo('me/MailPilot', { pushedAt: '2026-11-16' }),
  repo('acme/inspection-app', { pushedAt: '2026-11-15' }),
  repo('me/stride', { pushedAt: '2026-11-18' }),
  repo('work-org/stride', { pushedAt: '2026-01-01' }),
  repo('work-org/ChemDocs'),
];

describe('matchRepos', () => {
  it('finds a repository by the name as spoken', () => {
    expect(matchRepos('Ledger', repos).match?.fullName).toBe('acme/Ledger');
    expect(matchRepos('the ledger repo', repos).match?.fullName).toBe('acme/Ledger');
    expect(matchRepos('mail pilot', repos).match?.fullName).toBe('me/MailPilot');
    expect(matchRepos('inspection app', repos).match?.fullName).toBe('acme/inspection-app');
    expect(matchRepos('chem docs', repos).match?.fullName).toBe('work-org/ChemDocs');
  });

  it('accepts owner/name and GitHub links', () => {
    expect(matchRepos('work-org/stride', repos).match?.fullName).toBe('work-org/stride');
    expect(matchRepos('https://github.com/me/stride.git', repos).match?.fullName).toBe('me/stride');
  });

  it('asks back when two repositories share the name, newest first', () => {
    const r = matchRepos('stride', repos);
    expect(r.match).toBeUndefined();
    expect(r.candidates.map((c) => c.fullName)).toEqual(['me/stride', 'work-org/stride']);
  });

  it('offers close names instead of guessing', () => {
    const r = matchRepos('mail manager', repos);
    expect(r.match).toBeUndefined();
    expect(r.candidates.map((c) => c.fullName)).toContain('me/MailPilot');
  });

  it('finds nothing for a repository that is not the user\'s', () => {
    expect(matchRepos('torvalds/linux', repos)).toEqual({ candidates: [] });
    expect(matchRepos('kubernetes', repos)).toEqual({ candidates: [] });
  });
});

describe('GitHub', () => {
  it('names the token variable after the account', () => {
    expect(tokenVar('me')).toBe('GITHUB_TOKEN_ME');
    expect(tokenVar('work-login.2')).toBe('GITHUB_TOKEN_WORK_LOGIN_2');
  });

  const api = (x: { full_name: string; push?: boolean }) => ({
    full_name: x.full_name,
    name: x.full_name.split('/')[1],
    owner: { login: x.full_name.split('/')[0] },
    private: true,
    default_branch: 'main',
    description: null,
    pushed_at: '2026-11-01T00:00:00Z',
    permissions: { push: x.push ?? true },
  });

  it('lists only owner, organization and shared repositories, page by page, across accounts', async () => {
    const urls: string[] = [];
    const page1 = Array.from({ length: 100 }, (_, i) => api({ full_name: `a/r${i}` }));
    const gh = new GitHub({
      accounts: ['a', 'b', 'c'],
      token: (acc) => (acc === 'c' ? undefined : `tok-${acc}`),
      fetch: (async (url: string, init: RequestInit) => {
        urls.push(url);
        const auth = (init.headers as Record<string, string>).Authorization;
        if (auth === 'Bearer tok-a') {
          return Response.json(new URL(url).searchParams.get('page') === '1' ? page1 : [api({ full_name: 'shared/x', push: false })]);
        }
        return Response.json([api({ full_name: 'shared/x', push: true }), api({ full_name: 'b/own' })]);
      }) as typeof fetch,
    });
    const list = await gh.repos();
    expect(urls.every((u) => u.includes('affiliation=owner,collaborator,organization_member'))).toBe(true);
    expect(urls).toHaveLength(3); // two pages for a, one for b, none for c (no token)
    expect(list).toHaveLength(102);
    // Reachable from both accounts: the one with push access wins.
    expect(list.find((r) => r.fullName === 'shared/x')).toMatchObject({ canPush: true, account: 'b' });
  });

  it('reports missing and mismatched tokens at startup', async () => {
    const gh = new GitHub({
      accounts: ['me', 'work'],
      token: (acc) => (acc === 'me' ? 'tok' : undefined),
      fetch: (async () => new Response(JSON.stringify({ login: 'someone-else' }), { headers: { 'x-oauth-scopes': 'repo' } })) as unknown as typeof fetch,
    });
    const { lines, ok } = await gh.check();
    expect(ok).toBe(false);
    expect(lines).toEqual(['github me: the token belongs to someone-else, not me', 'github work: no token, set GITHUB_TOKEN_WORK in bridge/.env']);
  });

  it('gives git a token only through the environment and switches off credential helpers', () => {
    const gh = new GitHub({ accounts: ['me'], token: () => 'secret' });
    const env = gh.gitEnv('me');
    expect(env).toMatchObject({ GIT_CONFIG_KEY_0: 'credential.helper', GIT_CONFIG_VALUE_0: '', GIT_TERMINAL_PROMPT: '0' });
    expect(Buffer.from(env.GIT_CONFIG_VALUE_1!.split(' ').at(-1)!, 'base64').toString()).toBe('x-access-token:secret');
    expect(new GitHub({ accounts: ['me'], token: () => undefined }).gitEnv('me').GIT_CONFIG_COUNT).toBe('1');
  });
});
