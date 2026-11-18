import { describe, expect, it } from 'vitest';
import { describeAsk, describeTool, speakAsk, speechFor, splitAnswer } from '../src/cards.ts';

describe('splitAnswer', () => {
  it('uses the first line as the headline', () => {
    expect(splitAnswer('Tests pass now\nThe importer read the wrong column. I fixed the mapping and added a test.')).toEqual({
      title: 'Tests pass now',
      lines: ['The importer read the wrong column.', 'I fixed the mapping and added a test.'],
    });
  });

  it('strips markdown that would look like noise on the lens', () => {
    const { title, lines } = splitAnswer('## **Fixed** the `auth` hook\n- Updated [the docs](http://x.y)\n1. Ran tests');
    expect(title).toBe('Fixed the auth hook');
    expect(lines).toEqual(['Updated the docs', 'Ran tests']);
  });

  it('cuts a long single paragraph at its first sentence', () => {
    const { title, lines } = splitAnswer('Three files changed. The retry logic now backs off exponentially and the tests cover the timeout path as well.');
    expect(title).toBe('Three files changed');
    expect(lines[0]).toMatch(/^The retry logic/);
  });

  it('keeps version numbers and file names inside one sentence', () => {
    expect(splitAnswer('Done\nYou are on Node 24.17.0 now. The change is in price.js and is not committed.').lines).toEqual([
      'You are on Node 24.17.0 now.',
      'The change is in price.js and is not committed.',
    ]);
  });

  it('never returns an empty headline', () => {
    expect(splitAnswer('   ').title).toBe('Done');
  });
});

describe('speechFor', () => {
  it('reads as sentences without markup', () => {
    expect(speechFor('Done\n\nI renamed `foo` to **bar**.')).toBe('Done. I renamed foo to bar.');
  });
});

describe('describeTool', () => {
  it('shows file names, not paths', () => {
    expect(describeTool('Edit', { file_path: 'C:\\repo\\src\\auth\\session.ts' })).toBe('Edit session.ts');
    expect(describeTool('Read', { file_path: '/repo/README.md' })).toBe('Read README.md');
  });

  it('shortens commands', () => {
    expect(describeTool('Bash', { command: 'npm   test -- --run' })).toBe('Run npm test -- --run');
    expect(describeTool('Bash', { command: 'x'.repeat(100) })!.length).toBeLessThanOrEqual(48);
  });

  it('hides bookkeeping tools', () => {
    expect(describeTool('TodoWrite', {})).toBeUndefined();
    expect(describeTool('mcp__lens__show', {})).toBeUndefined();
  });
});

describe('describeAsk', () => {
  it('puts the command first and the reason second', () => {
    expect(describeAsk('Bash', { command: 'npm install zod', description: 'Add the validation library' })).toEqual({
      title: 'Run: npm install zod',
      detail: 'Add the validation library',
    });
  });
});

describe('speakAsk', () => {
  it('says the reason, then the start of the real command in speakable form', () => {
    expect(speakAsk('Run: git add -A && git commit -m "Add discount"', 'Commit all changes.')).toBe(
      'Commit all changes. Run: git add -A, then git commit -m Add discount. Approve or deny?',
    );
    expect(speakAsk('Run: npm install zod')).toBe('Run: npm install zod. Approve or deny?');
  });
});
