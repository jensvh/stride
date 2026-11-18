// The one custom tool Claude gets: put a small graphic on the lens.
import { createSdkMcpServer, tool } from '@anthropic-ai/claude-agent-sdk';
import { z } from 'zod';
import { Visual } from '../../protocol/schema.ts';

const DESCRIPTION = `Show one small graphic on the user's smart-glasses display (600 by 600 pixels, read at a glance while walking).
Use it when a picture says it better than a sentence: progress through steps (checklist), a few numbers to compare (bars), a tiny table, or a short code snippet.
Call it at most once or twice per task. Each call replaces the previous graphic. The graphic stays with your final answer, so do not repeat its content in words.`;

export function lensServer(onShow: (title: string | undefined, visual: Visual) => void) {
  return createSdkMcpServer({
    name: 'lens',
    version: '1.0.0',
    tools: [
      tool(
        'show',
        DESCRIPTION,
        {
          title: z.string().max(40).optional().describe('Optional caption, at most 5 words.'),
          visual: Visual.describe(
            'checklist: up to 8 steps with done flags. bars: up to 6 labelled numbers. table: up to 6 rows of 4 short cells. code: at most 12 short lines.',
          ),
        },
        async (args) => {
          onShow(args.title, args.visual);
          return { content: [{ type: 'text', text: 'Shown on the lens.' }] };
        },
        { alwaysLoad: true },
      ),
    ],
  });
}
