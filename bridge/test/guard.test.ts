import { mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterAll, describe, expect, it } from 'vitest';
import { checkTool } from '../src/guard.ts';
import { claudeEnv } from '../src/session.ts';

const ws = mkdtempSync(join(tmpdir(), 'stride-guard-'));
const repo = join(ws, 'api');
mkdirSync(repo);
afterAll(() => rmSync(ws, { recursive: true, force: true }));

const ok = (tool: string, input: Record<string, unknown>, cwd = ws) => expect(checkTool(tool, input, ws, cwd)).toBeUndefined();
const refused = (tool: string, input: Record<string, unknown>, cwd = ws) => expect(checkTool(tool, input, ws, cwd)).toMatch(/^Refused/);

describe('file tools', () => {
  it('may use files in the work folder', () => {
    ok('Read', { file_path: join(repo, 'src', 'a.ts') });
    ok('Read', { file_path: 'api/src/a.ts' });
    ok('Edit', { file_path: join(ws, 'notes.md') });
    ok('Grep', { pattern: 'TODO', path: 'api' });
    ok('Glob', { pattern: '**/*.ts' });
    ok('Read', { file_path: '../web/x.ts' }, repo);
  });

  it('may not touch anything else on the PC', () => {
    refused('Read', { file_path: join(homedir(), '.ssh', 'id_rsa') });
    refused('Read', { file_path: '~/.gitconfig' });
    refused('Write', { file_path: join(ws, '..', 'evil.txt') });
    refused('Read', { file_path: '../../x' }, repo);
    refused('Grep', { pattern: 'password', path: homedir() });
    refused('Glob', { pattern: `${homedir().replace(/\\/g, '/')}/**/*.env` });
  });
});

describe('shell commands', () => {
  it('runs ordinary commands', () => {
    ok('Bash', { command: 'npm test' });
    ok('Bash', { command: 'cd api && git log main..HEAD --oneline' });
    ok('Bash', { command: 'git diff HEAD~1..HEAD > /dev/null' });
    ok('Bash', { command: 'cd .. && ls' }, repo);
    ok('Bash', { command: `ls ${repo}` });
    ok('Bash', { command: 'curl -s https://example.com/a/b' });
  });

  it('refuses commands that reach outside the work folder', () => {
    refused('Bash', { command: 'cat ~/.ssh/id_rsa' });
    refused('Bash', { command: 'echo $HOME' });
    refused('Bash', { command: 'type %USERPROFILE%\\secrets.txt' });
    refused('Bash', { command: 'cd' });
    refused('Bash', { command: 'ls ../..' }, repo);
    refused('Bash', { command: `git diff --no-index "${join(homedir(), 'notes.txt')}" /dev/null` });
    refused('Bash', { command: 'cat /etc/passwd' });
    if (process.platform === 'win32') {
      refused('Bash', { command: 'cat /c/Users/someone/Documents/x.txt' });
      refused('Bash', { command: 'dir C:\\Users' });
    }
  });
});

describe('the environment Claude gets', () => {
  it('holds no tokens and no way to GitHub credentials', () => {
    const env = claudeEnv({
      PATH: '/bin',
      GITHUB_TOKEN_JENSVH: 'a',
      GH_TOKEN: 'b',
      WEBPUBSUB_CONNECTION_STRING: 'c',
    });
    expect(env.PATH).toBe('/bin');
    expect(env.GITHUB_TOKEN_JENSVH).toBeUndefined();
    expect(env.GH_TOKEN).toBeUndefined();
    expect(env.WEBPUBSUB_CONNECTION_STRING).toBeUndefined();
    expect(env).toMatchObject({ GIT_CONFIG_KEY_0: 'credential.helper', GIT_CONFIG_VALUE_0: '', GIT_TERMINAL_PROMPT: '0' });
    expect(env.GH_CONFIG_DIR).toMatch(/gh-empty$/);
  });
});
