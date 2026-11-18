// Turns a spoken sentence into either a direct command or a prompt for Claude.
// Pure and synchronous so it is easy to test.
import type { CommandName } from '../../protocol/schema.ts';

export type Routed =
  | { kind: 'command'; name: CommandName; arg?: string }
  | { kind: 'answer'; choice: 'approve' | 'deny'; text?: string }
  | { kind: 'choice'; label: string }
  | { kind: 'reask' }
  | { kind: 'prompt'; text: string };

export type RouteContext = {
  ask?: { kind: 'approve' | 'choice'; options?: string[] };
  projects: { name: string; aliases: string[] }[];
};

const clean = (s: string) =>
  s
    .toLowerCase()
    .replace(/[’`]/g, "'")
    .replace(/[^a-z0-9' ]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();

// A bare "yes" is deliberately not an approval: wind noise and half-heard
// words must never approve a shell command.
const APPROVE = /^(approve|approved|i approve|yes approve|approve it|approve that|go ahead|yes go ahead|allow it|allow that|run it|yes run it)$/;
const DENY = /^(deny|denied|deny it|deny that|reject|reject it|no|nope|cancel|don't|do not)\b\s*(.*)$/;

const ORDINALS: Record<string, number> = {
  one: 1, first: 1, '1': 1,
  two: 2, second: 2, to: 2, too: 2, '2': 2,
  three: 3, third: 3, '3': 3,
  four: 4, fourth: 4, for: 4, '4': 4,
};

export function matchProject(spoken: string, projects: RouteContext['projects']): string | undefined {
  const want = clean(spoken).replace(/^(the )?(project )?/, '').replace(/ project$/, '');
  if (!want) return undefined;
  for (const p of projects) {
    if ([p.name, ...p.aliases].some((n) => clean(n) === want)) return p.name;
  }
  // Tolerate recognition gluing or splitting words: "roll monitoring" vs "rollmonitoring".
  const squash = want.replace(/ /g, '');
  for (const p of projects) {
    if ([p.name, ...p.aliases].some((n) => clean(n).replace(/ /g, '') === squash)) return p.name;
  }
  return undefined;
}

export function route(text: string, ctx: RouteContext): Routed {
  const raw = text.trim();
  const t = clean(raw);
  if (!t) return { kind: 'reask' };

  if (ctx.ask?.kind === 'approve') {
    if (APPROVE.test(t)) return { kind: 'answer', choice: 'approve' };
    const deny = DENY.exec(t);
    if (deny) {
      // Keep the user's own words (original casing) as the instruction for Claude.
      const rest = raw.replace(/^\s*\S+(\s+(it|that|not))?[\s,.:;-]*/i, '').trim();
      return { kind: 'answer', choice: 'deny', ...(deny[2] && rest ? { text: rest } : {}) };
    }
    if (/^(stop|abort|halt)( it| that)?$/.test(t)) return { kind: 'command', name: 'stop' };
    return { kind: 'reask' };
  }

  if (ctx.ask?.kind === 'choice') {
    const options = ctx.ask.options ?? [];
    const ord = /^(?:option |number |the )?(\w+)(?: one| option)?$/.exec(t);
    const n = ord?.[1] ? ORDINALS[ord[1]] : undefined;
    if (n && options[n - 1]) return { kind: 'choice', label: options[n - 1]! };
    const exact = options.find((o) => clean(o) === t);
    if (exact) return { kind: 'choice', label: exact };
    const partial = options.filter((o) => clean(o).includes(t) || t.includes(clean(o)));
    if (partial.length === 1) return { kind: 'choice', label: partial[0]! };
    if (/^(stop|abort|halt|cancel)( it| that)?$/.test(t)) return { kind: 'command', name: 'stop' };
    // Anything else is a free-text answer to the question.
    return { kind: 'choice', label: raw };
  }

  if (/^(stop|cancel|abort|halt)( it| that| now)?$/.test(t)) return { kind: 'command', name: 'stop' };
  if (/^(status|what's the status|what is the status|where are we|are you done|progress)$/.test(t)) {
    return { kind: 'command', name: 'status' };
  }
  if (/^(repeat|repeat that|say that again|say it again|again|what did you say)$/.test(t)) {
    return { kind: 'command', name: 'repeat' };
  }
  if (/^undo( that| it| the last one)?$/.test(t)) return { kind: 'command', name: 'undo' };
  if (/^(new|start a new|fresh|start a fresh) (session|chat|conversation)$/.test(t)) {
    return { kind: 'command', name: 'new' };
  }
  const sw = /^(?:switch|change|go|move) (?:over )?to (.+)$/.exec(t) ?? /^(?:open )?project (.+)$/.exec(t);
  if (sw?.[1]) {
    const name = matchProject(sw[1], ctx.projects);
    // Only a known project switches; "switch to pnpm" stays a prompt for Claude.
    if (name) return { kind: 'command', name: 'switch', arg: name };
  }
  return { kind: 'prompt', text: raw };
}
