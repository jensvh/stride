// Keeps Claude inside the work folder. Runs as a PreToolUse hook, before any
// permission check, so a refusal here never reaches the user as a question.
//
// File tools are checked exactly. Shell commands are checked for paths that
// point outside the folder (absolute paths, ~, home variables, ".." that climbs
// out). This stops the obvious ways out; code from a repository that Claude
// runs (a test script, a build) still runs with the user's Windows rights.
import { realpathSync } from 'node:fs';
import { homedir } from 'node:os';
import { relative, resolve } from 'node:path';
import type { HookCallback } from '@anthropic-ai/claude-agent-sdk';

const WIN = process.platform === 'win32';

/** Git Bash spells C:\Users as /c/Users. */
function native(p: string): string {
  if (WIN) {
    const m = /^\/([a-zA-Z])(\/.*)?$/.exec(p);
    if (m) return `${m[1]!.toUpperCase()}:${(m[2] ?? '/').replace(/\//g, '\\')}`;
  }
  return p.replace(/^~(?=$|[\\/])/, homedir());
}

function real(p: string): string {
  try {
    return realpathSync.native(p);
  } catch {
    return p; // does not exist yet: judge the path as written
  }
}

/** Whether `p` (relative to `base`) lies inside `root`. */
export function inside(root: string, p: string, base = root): boolean {
  const abs = real(resolve(base, native(p)));
  const rel = relative(real(resolve(root)), abs);
  const out = rel === '..' || rel.startsWith(`..\\`) || rel.startsWith('../') || /^[a-zA-Z]:/.test(rel) || rel.startsWith('/') || rel.startsWith('\\');
  return !out;
}

const FILE_KEYS: Record<string, string[]> = {
  Read: ['file_path'],
  Write: ['file_path'],
  Edit: ['file_path'],
  MultiEdit: ['file_path'],
  NotebookEdit: ['notebook_path'],
  NotebookRead: ['notebook_path'],
  Glob: ['path', 'pattern'],
  Grep: ['path'],
  LS: ['path'],
};

const DEVICES = new Set(['/dev/null', '/dev/stdin', '/dev/stdout', '/dev/stderr']);
const END = String.raw`[^\s"'\x60;|&<>()]*`;
const HOME_VARS = /\$\{?(HOME|USERPROFILE|APPDATA|LOCALAPPDATA|HOMEDRIVE|HOMEPATH|TEMP|TMP|OneDrive)\b|%(USERPROFILE|APPDATA|LOCALAPPDATA|HOMEDRIVE|HOMEPATH|TEMP|TMP|OneDrive)%/i;

/** Paths a shell command names that may lead outside: absolute, home-relative or climbing with "..". */
function commandPaths(cmd: string): string[] {
  const found: string[] = [];
  const grab = (re: RegExp) => {
    for (const m of cmd.matchAll(re)) found.push(m[1] ?? m[0]);
  };
  grab(new RegExp(String.raw`(?<![\w/])([a-zA-Z]:[\\/]${END})`, 'g')); // C:\x or C:/x
  grab(new RegExp(String.raw`(?:^|[\s"'=(])(\/${END})`, 'g')); // /c/x, /etc/x
  grab(new RegExp(String.raw`(?:^|[\s"'=(])(~${END})`, 'g')); // ~ and ~/x
  grab(new RegExp(String.raw`(?:^|[\s"'=(])((?:[^\s"'\x60;|&<>()]*[\\/])?\.\.(?:[\\/]${END})?)`, 'g')); // ../x
  return found.filter((p) => !DEVICES.has(p) && !p.startsWith('//'));
}

/** Why a tool call must not run, or undefined when it may. */
export function checkTool(tool: string, input: Record<string, unknown>, root: string, cwd = root): string | undefined {
  const refuse = (what: string) =>
    `Refused: ${what} is outside the work folder. Only ${root} is available; the rest of this PC is off limits. Use get_repo to fetch code.`;

  const keys = FILE_KEYS[tool];
  if (keys) {
    for (const k of keys) {
      const v = input[k];
      if (typeof v !== 'string' || !v) continue;
      // A Glob pattern only matters when it is absolute or climbs out.
      if (k === 'pattern' && !/^([a-zA-Z]:|[\\/]|~|\.\.)/.test(v)) continue;
      const path = k === 'pattern' ? v.replace(/[*?[{].*$/, '') || '.' : v;
      if (!inside(root, path, cwd)) return refuse(v);
    }
    return undefined;
  }

  if (tool === 'Bash' || tool === 'PowerShell') {
    const cmd = typeof input.command === 'string' ? input.command : '';
    if (HOME_VARS.test(cmd)) return refuse('your home folder');
    if (/(^|[;&|]\s*|\b(then|do)\s+)cd\s*($|[;&|])/.test(cmd)) return refuse('your home folder');
    for (const p of commandPaths(cmd)) {
      if (!inside(root, p, cwd)) return refuse(p);
    }
  }
  return undefined;
}

/** The hook the Agent SDK calls before every tool use. */
export function guardHook(root: () => string): HookCallback {
  return async (input) => {
    if (input.hook_event_name !== 'PreToolUse') return {};
    const reason = checkTool(input.tool_name, (input.tool_input ?? {}) as Record<string, unknown>, root(), input.cwd || root());
    if (!reason) return {};
    return { hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason } };
  };
}
