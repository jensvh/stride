// Questions that wait for the person on the walk: approve/deny for a tool
// call, or a choice Claude asked for. One at a time; no answer means deny.
import { randomUUID } from 'node:crypto';
import type { CanUseTool } from '@anthropic-ai/claude-agent-sdk';
import type { Ask } from '../../protocol/schema.ts';
import { describeAsk } from './cards.ts';

export type AskAnswer = { choice: string; text?: string; reason?: 'timeout' | 'cancelled' };

type Pending = { ask: Ask; resolve: (a: AskAnswer) => void; timer: ReturnType<typeof setTimeout> };

export class Asks {
  private current: Pending | undefined;
  private chain: Promise<unknown> = Promise.resolve();
  private readonly timeoutMs: number;
  private readonly onOpen: (ask: Ask) => void;
  private readonly onClose: (ask: Ask, answer: AskAnswer) => void;

  constructor(opts: { timeoutMs: number; onOpen: (ask: Ask) => void; onClose: (ask: Ask, answer: AskAnswer) => void }) {
    this.timeoutMs = opts.timeoutMs;
    this.onOpen = opts.onOpen;
    this.onClose = opts.onClose;
  }

  get pending(): Ask | undefined {
    return this.current?.ask;
  }

  /** Queues a question and resolves with the answer, a timeout or a cancellation. */
  open(q: Pick<Ask, 'kind' | 'title' | 'detail' | 'options'>, signal?: AbortSignal): Promise<AskAnswer> {
    const next = this.chain.then(
      () =>
        new Promise<AskAnswer>((resolve) => {
          if (signal?.aborted) return resolve({ choice: 'deny', reason: 'cancelled' });
          const ask: Ask = { ...q, id: randomUUID().slice(0, 8), expiresAt: Date.now() + this.timeoutMs };
          const finish = (a: AskAnswer) => {
            if (this.current?.ask.id !== ask.id) return;
            clearTimeout(this.current.timer);
            this.current = undefined;
            signal?.removeEventListener('abort', onAbort);
            this.onClose(ask, a);
            resolve(a);
          };
          const onAbort = () => finish({ choice: 'deny', reason: 'cancelled' });
          signal?.addEventListener('abort', onAbort, { once: true });
          this.current = {
            ask,
            resolve: finish,
            timer: setTimeout(() => finish({ choice: 'deny', reason: 'timeout' }), this.timeoutMs),
          };
          this.onOpen(ask);
        }),
    );
    this.chain = next.catch(() => undefined);
    return next;
  }

  /** Answers the pending question. `askId` undefined means "whatever is pending" (spoken answers). */
  answer(askId: string | undefined, choice: string, text?: string): boolean {
    const cur = this.current;
    if (!cur || (askId !== undefined && cur.ask.id !== askId)) return false;
    if (cur.ask.kind === 'approve' && choice !== 'approve' && choice !== 'deny') return false;
    cur.resolve({ choice, ...(text ? { text } : {}) });
    return true;
  }

  cancel(): void {
    this.current?.resolve({ choice: 'deny', reason: 'cancelled' });
  }
}

const AWAY =
  'The user is away from the desk and did not answer in time. Do not retry this. Continue without it if you can, otherwise stop and say in one sentence what you need.';

/** The Agent SDK permission callback: everything not pre-approved lands here. */
export function permissionHandler(asks: Asks, log: (m: string) => void): CanUseTool {
  return async (toolName, input, opts) => {
    if (toolName === 'AskUserQuestion') {
      const questions = Array.isArray(input.questions) ? (input.questions as Record<string, unknown>[]) : [];
      const answers: Record<string, string> = {};
      for (const q of questions) {
        const question = String(q.question ?? '');
        const options = (Array.isArray(q.options) ? (q.options as Record<string, unknown>[]) : []).map((o) => ({
          label: String(o.label ?? ''),
          ...(o.description ? { description: String(o.description) } : {}),
        }));
        const a = await asks.open({ kind: 'choice', title: question, options }, opts.signal);
        if (a.reason) return { behavior: 'deny', message: a.reason === 'timeout' ? AWAY : 'Cancelled by the user.' };
        answers[question] = a.choice;
      }
      return { behavior: 'allow', updatedInput: { ...input, answers } };
    }

    const { title, detail } = describeAsk(toolName, input);
    log(`ask: ${title}`);
    const a = await asks.open({ kind: 'approve', title, ...(detail ? { detail } : {}) }, opts.signal);
    if (a.choice === 'approve') return { behavior: 'allow', updatedInput: input };
    if (a.reason === 'timeout') return { behavior: 'deny', message: AWAY };
    if (a.reason === 'cancelled') return { behavior: 'deny', message: 'Cancelled by the user.' };
    return {
      behavior: 'deny',
      message: a.text
        ? `The user denied this and said: "${a.text}". Follow that instruction.`
        : 'The user denied this. Do not retry it; find another way or stop and summarize.',
    };
  };
}
