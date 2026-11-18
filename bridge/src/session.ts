// One long-lived Claude Code session for one work folder, fed by a queue.
import { mkdirSync } from 'node:fs';
import { join } from 'node:path';
import {
  query,
  type CanUseTool,
  type McpServerConfig,
  type Options,
  type Query,
  type SDKMessage,
  type SDKUserMessage,
} from '@anthropic-ai/claude-agent-sdk';
import type { Visual } from '../../protocol/schema.ts';
import { VOICE_APPENDIX, describeTool } from './cards.ts';
import { STATE_DIR, type Config } from './config.ts';

// Commands that are safe to run without asking; config.json can add more.
// Claude Code's built-in read-only commands (ls, cat, git status, git diff, ...) never ask anyway.
// Local git writes are allowed too: the work folder is a throwaway clone and
// nothing leaves it except through publish, which the user approves.
const BASE_ALLOW = [
  'mcp__lens__show', 'mcp__github__find_repos', 'mcp__github__get_repo',
  'Bash(git status)', 'Bash(git status *)', 'Bash(git diff)', 'Bash(git diff *)',
  'Bash(git log)', 'Bash(git log *)', 'Bash(git show *)', 'Bash(git branch)', 'Bash(git branch --list *)',
  'Bash(git add *)', 'Bash(git commit *)', 'Bash(git switch *)', 'Bash(git checkout -b *)', 'Bash(git stash)', 'Bash(git stash *)',
  'Bash(npm test)', 'Bash(npm test *)', 'Bash(npm run test)', 'Bash(npm run test *)',
  'Bash(npm run lint)', 'Bash(npm run lint *)', 'Bash(npm run build)', 'Bash(npm run build *)',
  'Bash(npm run typecheck)', 'Bash(npm run typecheck *)', 'Bash(npx tsc *)', 'Bash(npx vitest *)',
  'Bash(pnpm test)', 'Bash(pnpm test *)', 'Bash(pnpm run test *)', 'Bash(pnpm run lint *)', 'Bash(pnpm run build *)',
  'Bash(dotnet build)', 'Bash(dotnet build *)', 'Bash(dotnet test)', 'Bash(dotnet test *)',
  'Bash(pytest)', 'Bash(pytest *)', 'Bash(python -m pytest *)',
];

// Never run remotely, not even with a spoken approval.
const HARD_DENY = [
  'Bash(git push --force *)', 'Bash(git push -f *)', 'Bash(git push * --force)', 'Bash(git push * --force *)', 'Bash(git push * -f)',
  'Bash(git reset --hard)', 'Bash(git reset --hard *)', 'Bash(git clean *)',
  'Bash(rm -rf /)', 'Bash(rm -rf /*)', 'Bash(rm -rf ~)', 'Bash(rm -rf ~/*)', 'Bash(rm -rf .git)', 'Bash(rm -rf .git/*)',
  'Bash(shutdown *)', 'Bash(format *)', 'Bash(diskpart *)', 'Bash(reg delete *)',
  // GitHub only through the bridge's tools, which check the repository is the user's.
  'Bash(git clone *)', 'Bash(git push *)', 'Bash(git push)', 'Bash(git pull *)', 'Bash(git fetch *)',
  'Bash(git remote add *)', 'Bash(git remote set-url *)', 'Bash(git submodule *)', 'Bash(git config *)',
  'Bash(gh *)', 'Bash(gh)',
];

/**
 * The environment Claude's processes get: no relay key, no GitHub tokens, no
 * gh login and no git credential helper, so nothing it runs can reach GitHub
 * as the user.
 */
export function claudeEnv(base: NodeJS.ProcessEnv = process.env): Record<string, string | undefined> {
  const env: Record<string, string | undefined> = {};
  for (const [k, v] of Object.entries(base)) {
    if (/^(GITHUB_TOKEN|GH_TOKEN|GH_ENTERPRISE_TOKEN|GITHUB_ENTERPRISE_TOKEN|WEBPUBSUB_)/i.test(k)) continue;
    env[k] = v;
  }
  const ghDir = join(STATE_DIR, 'gh-empty');
  mkdirSync(ghDir, { recursive: true });
  return {
    ...env,
    // One shell, one allowlist: Git Bash only.
    CLAUDE_CODE_USE_POWERSHELL_TOOL: '0',
    CLAUDE_AGENT_SDK_CLIENT_APP: 'stride-bridge/0.2.0',
    GH_CONFIG_DIR: ghDir,
    GIT_TERMINAL_PROMPT: '0',
    GCM_INTERACTIVE: 'never',
    GIT_CONFIG_COUNT: '1',
    GIT_CONFIG_KEY_0: 'credential.helper',
    GIT_CONFIG_VALUE_0: '',
  };
}

/** What a session needs from the bridge: where it works and the tools and hooks it gets. */
export type SessionSetup = {
  cwd: string;
  mcpServers: Record<string, McpServerConfig>;
  hooks: NonNullable<Options['hooks']>;
};

class InputQueue implements AsyncIterable<SDKUserMessage> {
  private items: SDKUserMessage[] = [];
  private wake: (() => void) | undefined;
  private ended = false;

  push(m: SDKUserMessage): void {
    this.items.push(m);
    this.wake?.();
  }

  end(): void {
    this.ended = true;
    this.wake?.();
  }

  async *[Symbol.asyncIterator](): AsyncGenerator<SDKUserMessage> {
    for (;;) {
      const next = this.items.shift();
      if (next) {
        yield next;
        continue;
      }
      if (this.ended) return;
      await new Promise<void>((r) => (this.wake = r));
      this.wake = undefined;
    }
  }
}

export type TurnResult = { ok: boolean; text: string; subtype: string; durationMs: number };

export type SessionEvents = {
  onActivity: (text: string) => void;
  onShow: (title: string | undefined, visual: Visual) => void;
  onResult: (r: TurnResult) => void;
  onSessionId: (id: string) => void;
  /** Problems the user should hear about: expired login, usage limit, crashed process. */
  onTrouble: (kind: 'login' | 'limit' | 'crash' | 'overloaded', detail: string) => void;
  log: (msg: string) => void;
};

export class ClaudeSession {
  busy = false;
  /** Tool calls in the current task. */
  tools = 0;
  private q: Query | undefined;
  private input: InputQueue | undefined;
  private resumeId: string | undefined;
  private readonly setup: SessionSetup;
  private readonly cfg: Config;
  private readonly canUseTool: CanUseTool;
  private readonly events: SessionEvents;

  constructor(setup: SessionSetup, cfg: Config, canUseTool: CanUseTool, events: SessionEvents, resumeId?: string) {
    this.setup = setup;
    this.cfg = cfg;
    this.canUseTool = canUseTool;
    this.events = events;
    this.resumeId = resumeId;
  }

  send(text: string): void {
    if (!this.q) this.start();
    if (!this.busy) this.tools = 0;
    this.busy = true;
    this.input!.push({ type: 'user', message: { role: 'user', content: text }, parent_tool_use_id: null });
  }

  async interrupt(): Promise<void> {
    await this.q?.interrupt().catch((err) => this.events.log(`interrupt failed: ${String(err)}`));
  }

  /** Ends the process. With `forget`, the next prompt starts a brand-new conversation. */
  dispose(forget = false): void {
    const q = this.q;
    this.q = undefined;
    this.input?.end();
    this.input = undefined;
    this.busy = false;
    if (forget) this.resumeId = undefined;
    try {
      q?.close();
    } catch {
      // already gone
    }
  }

  private start(): void {
    const input = new InputQueue();
    this.input = input;
    const q = query({
      prompt: input,
      options: {
        cwd: this.setup.cwd,
        ...(this.resumeId ? { resume: this.resumeId } : {}),
        ...(this.cfg.model ? { model: this.cfg.model } : {}),
        systemPrompt: { type: 'preset', preset: 'claude_code', append: VOICE_APPENDIX },
        // Settings of the work folder only (which has none). Allow rules from your
        // personal settings, and from a cloned repository's own .claude folder,
        // cannot bypass the remote approval.
        settingSources: ['project'],
        permissionMode: 'acceptEdits',
        allowedTools: [...BASE_ALLOW, ...this.cfg.allow],
        disallowedTools: HARD_DENY,
        canUseTool: this.canUseTool,
        mcpServers: this.setup.mcpServers,
        hooks: this.setup.hooks,
        maxTurns: this.cfg.maxTurns,
        env: claudeEnv(),
        stderr: (data) => this.events.log(`[claude] ${data.trimEnd()}`),
      },
    });
    this.q = q;

    void (async () => {
      try {
        for await (const m of q) this.handle(m);
      } catch (err) {
        if (this.q === q) this.events.onTrouble('crash', err instanceof Error ? err.message : String(err));
      } finally {
        if (this.q === q) {
          this.q = undefined;
          this.input = undefined;
          this.busy = false;
        }
      }
    })();
  }

  private handle(m: SDKMessage): void {
    switch (m.type) {
      case 'system':
        if (m.subtype === 'init') {
          this.resumeId = m.session_id;
          this.events.onSessionId(m.session_id);
          this.events.log(`session ${m.session_id} (${m.model}, auth: ${m.apiKeySource}, Claude Code ${m.claude_code_version})`);
        }
        break;
      case 'assistant': {
        if (m.error) {
          if (m.error === 'authentication_failed' || m.error === 'oauth_org_not_allowed' || m.error === 'account_on_hold' || m.error === 'verification_required') {
            this.events.onTrouble('login', m.error);
          } else if (m.error === 'rate_limit' || m.error === 'billing_error') {
            this.events.onTrouble('limit', m.error);
          } else if (m.error === 'overloaded' || m.error === 'server_error') {
            this.events.onTrouble('overloaded', m.error);
          }
        }
        if (m.parent_tool_use_id !== null) break; // subagent chatter
        this.busy = true;
        for (const block of m.message.content) {
          if (block.type !== 'tool_use') continue;
          this.tools++;
          const line = describeTool(block.name, (block.input ?? {}) as Record<string, unknown>);
          if (line) this.events.onActivity(line);
        }
        break;
      }
      case 'rate_limit_event':
        if (m.rate_limit_info.status === 'rejected') this.events.onTrouble('limit', m.rate_limit_info.rateLimitType ?? 'usage limit');
        break;
      case 'result': {
        this.busy = false;
        const ok = m.subtype === 'success' && !m.is_error;
        const text = m.subtype === 'success' ? m.result : m.errors.join(' ');
        this.events.onResult({ ok, text, subtype: m.subtype, durationMs: m.duration_ms });
        break;
      }
      default:
        break;
    }
  }
}
