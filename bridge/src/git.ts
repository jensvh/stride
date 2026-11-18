// One way to run git from the bridge.
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const run = promisify(execFile);

export async function git(cwd: string, args: string[], env?: Record<string, string>, timeoutMs = 120_000): Promise<string> {
  try {
    const { stdout } = await run('git', args, {
      cwd,
      env: { ...process.env, ...env },
      maxBuffer: 32 * 1024 * 1024,
      windowsHide: true,
      timeout: timeoutMs,
    });
    return stdout.replace(/\r?\n$/, '');
  } catch (err) {
    // Keep git's own words: they explain the problem better than a stack trace.
    const e = err as { stderr?: string; message?: string };
    const detail = (e.stderr || e.message || String(err)).trim().split(/\r?\n/).slice(-3).join(' ');
    throw new Error(`git ${args[0]} failed: ${detail}`);
  }
}

export async function isRepo(dir: string): Promise<boolean> {
  try {
    return (await git(dir, ['rev-parse', '--show-toplevel'])).length > 0;
  } catch {
    return false;
  }
}
