// Shapes Claude's output for a 600x600 lens and a pair of ears.
import { basename } from 'node:path';
import type { Card, Stats, Visual } from '../../protocol/schema.ts';

export const VOICE_APPENDIX = `
# Voice mode

The user is a developer who is away from the desk: walking, hiking or cycling. They speak to you through smart glasses and your answer is read aloud and shown on a tiny in-lens display. Their words reach you through speech recognition, so expect mis-heard technical terms; use the repository to work out what they meant instead of asking.

How to answer:
- The final message of every turn is at most about 60 words of plain spoken English. First line: a headline of at most 6 words saying what happened or the answer. Then one to three short sentences.
- No markdown, no code blocks, no tables, no file paths longer than a file name, no lists of more than three items. Say numbers and names the way a person would say them aloud.
- Put detail where the user can read it later at the desk: in the code, a commit message, or a notes file. Mention where it is in a few words.
- Do the work instead of describing a plan, unless the task is risky or ambiguous. Ask at most one clarifying question, and only when a wrong guess would waste real time.
- Shell commands outside the allowlist need the user's spoken approval, which interrupts their walk. Prefer the dedicated file tools and allowed commands, and batch what you need into as few approvals as possible.
- When a small graphic says it better than a sentence (progress through steps, a few numbers to compare, a tiny table, a short snippet), call the show tool once. Keep it to what fits a glance.

# Where you work

Each conversation starts in its own empty work folder, your current directory. Nothing else on this PC is available: reads, writes and commands that reach outside it are refused.
- To work on code, call get_repo with the repository name the user said. It clones one of the user's GitHub repositories (their own, their organizations' or ones shared with them) into a subfolder. Other repositories are not available. If several could be meant, ask which one. find_repos lists them.
- git has no GitHub credentials here: you cannot clone, fetch, pull or push yourself. Committing and branching locally is fine.
- To deliver changes, call publish with the folder name and a clear title. After the user approves, it commits what is left, pushes a new branch and opens a pull request. Say the pull request number in your answer. Never say something is on GitHub before publish succeeded.
- The work folder is deleted about a week after its last use. Unpublished work is lost then.
`.trim();

const stripMd = (s: string) =>
  s
    .replace(/```[\s\S]*?```/g, ' ')
    .replace(/`([^`]+)`/g, '$1')
    .replace(/\*\*([^*]+)\*\*/g, '$1')
    .replace(/(^|\s)[*_]([^*_]+)[*_](?=\s|[.,!?]|$)/g, '$1$2')
    .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
    .replace(/^#{1,6}\s+/gm, '')
    .replace(/^\s*[-*•]\s+/gm, '')
    .replace(/^\s*\d+[.)]\s+/gm, '');

const ellipsis = (s: string, max: number) => (s.length <= max ? s : `${s.slice(0, max - 1).trimEnd()}…`);

/** Splits an answer into a headline and body lines for the result card. */
export function splitAnswer(text: string): { title: string; lines: string[] } {
  const parts = stripMd(text)
    .split(/\n+/)
    .map((l) => l.trim())
    .filter(Boolean);
  if (parts.length === 0) return { title: 'Done', lines: [] };
  let title = parts[0]!;
  let rest = parts.slice(1);
  // A long single paragraph: use its first sentence as the headline.
  if (title.length > 48) {
    const m = /^(.{8,48}?[.!?])\s+(.*)$/.exec(title);
    if (m) {
      title = m[1]!;
      rest = [m[2]!, ...rest];
    }
  }
  title = ellipsis(title.replace(/[.:]$/, ''), 48);
  // One sentence per line: the lens shows the first few and scrolls the rest.
  const lines = rest
    // Split only where a sentence ends and a new one starts, so "24.17.0" and "price.js" stay whole.
    .flatMap((p) => p.split(/(?<=[.!?])\s+(?=[A-Z"'(])/))
    .map((l) => l.trim())
    .filter(Boolean)
    .slice(0, 12)
    .map((l) => ellipsis(l, 200));
  return { title, lines };
}

/** What gets read aloud: the whole short answer, without markup. */
export function speechFor(text: string): string {
  return ellipsis(stripMd(text).replace(/\s*\n+\s*/g, '. ').replace(/\.\.+/g, '.').replace(/\s+/g, ' ').trim(), 900);
}

export function resultCard(args: {
  id: string;
  project: string;
  text: string;
  stats?: Stats;
  visual?: Visual;
}): Card {
  const { title, lines } = splitAnswer(args.text);
  return {
    id: args.id,
    kind: 'result',
    title,
    lines,
    project: args.project,
    at: Date.now(),
    ...(args.stats ? { stats: args.stats } : {}),
    ...(args.visual ? { visual: args.visual } : {}),
  };
}

export function errorCard(id: string, project: string, title: string, detail?: string): Card {
  return { id, kind: 'error', title: ellipsis(title, 48), lines: detail ? [ellipsis(detail, 220)] : [], project, at: Date.now() };
}

const str = (v: unknown) => (typeof v === 'string' ? v : '');

/** One short line for the lens while a tool runs. Returns undefined for tools not worth showing. */
export function describeTool(name: string, input: Record<string, unknown>): string | undefined {
  const file = (k: string) => basename(str(input[k]).replace(/\\/g, '/')) || 'file';
  switch (name) {
    case 'Read':
      return `Read ${file('file_path')}`;
    case 'Edit':
    case 'MultiEdit':
    case 'Write':
      return `Edit ${file('file_path')}`;
    case 'NotebookEdit':
      return `Edit ${file('notebook_path')}`;
    case 'Bash':
    case 'PowerShell':
      return `Run ${ellipsis(str(input.command).replace(/\s+/g, ' '), 44)}`;
    case 'Grep':
      return `Search ${ellipsis(str(input.pattern), 36)}`;
    case 'Glob':
      return `Find ${ellipsis(str(input.pattern), 38)}`;
    case 'WebSearch':
      return `Web: ${ellipsis(str(input.query), 38)}`;
    case 'WebFetch': {
      try {
        return `Fetch ${new URL(str(input.url)).hostname}`;
      } catch {
        return 'Fetch page';
      }
    }
    case 'Task':
    case 'Agent':
      return `Helper: ${ellipsis(str(input.description) || 'subtask', 36)}`;
    case 'AskUserQuestion':
    case 'TodoWrite':
    case 'TaskCreate':
    case 'TaskUpdate':
    case 'TaskList':
    case 'TaskGet':
    case 'ToolSearch':
      return undefined;
    case 'mcp__github__get_repo':
      return `Get ${ellipsis(str(input.name), 40)}`;
    case 'mcp__github__find_repos':
      return 'Look up your repos';
    case 'mcp__github__publish':
      return `Publish ${ellipsis(str(input.repo), 36)}`;
    default:
      if (name.startsWith('mcp__lens__')) return undefined;
      if (name.startsWith('mcp__')) return ellipsis(name.split('__').slice(1).join(' '), 44);
      return name;
  }
}

/** Title and detail for an approval request. */
export function describeAsk(tool: string, input: Record<string, unknown>): { title: string; detail?: string } {
  if (tool === 'Bash' || tool === 'PowerShell') {
    const cmd = str(input.command).replace(/\s+/g, ' ').trim();
    const why = str(input.description);
    return { title: `Run: ${ellipsis(cmd, 120)}`, ...(why ? { detail: ellipsis(why, 160) } : {}) };
  }
  if (tool === 'WebFetch') return { title: `Fetch ${ellipsis(str(input.url), 100)}` };
  if (tool === 'WebSearch') return { title: `Search the web: ${ellipsis(str(input.query), 90)}` };
  if (tool === 'mcp__github__publish') {
    return {
      title: `Publish ${ellipsis(str(input.repo), 30)}: ${ellipsis(str(input.title), 80)}`,
      detail: 'Pushes a new branch and opens a pull request on GitHub',
    };
  }
  if (tool === 'Edit' || tool === 'Write' || tool === 'MultiEdit') {
    return { title: `Edit ${file(str(input.file_path))}` };
  }
  if (tool.startsWith('mcp__')) return { title: `Use ${tool.split('__').slice(1).join(' ')}` };
  return { title: `Use ${tool}`, detail: ellipsis(JSON.stringify(input), 160) };
}

const file = (p: string) => basename(p.replace(/\\/g, '/')) || 'file';

/**
 * How an approval request is spoken: Claude's reason first, then the start of
 * the real command, so the ear gets both the intent and what will actually run.
 */
export function speakAsk(title: string, detail?: string): string {
  const command = ellipsis(title.replace(/\s*(&&|;|\|)\s*/g, ', then ').replace(/["'`]/g, ''), 80);
  return `${detail ? `${detail.replace(/[.\s]+$/, '')}. ` : ''}${command}. Approve or deny?`;
}
