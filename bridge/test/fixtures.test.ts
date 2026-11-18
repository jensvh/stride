import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { State } from '../../protocol/schema.ts';

// The lens demo, and later the iPhone tests, render these files. They must stay
// valid against the protocol, or the demo would show something the bridge can never send.
const fixtures = JSON.parse(readFileSync(new URL('../../protocol/fixtures/states.json', import.meta.url), 'utf8')) as {
  name: string;
  state: unknown;
}[];

describe('protocol fixtures', () => {
  it.each(fixtures.map((f) => [f.name, f.state] as const))('%s is a valid State', (_name, state) => {
    const parsed = State.safeParse(state);
    expect(parsed.error?.issues ?? []).toEqual([]);
  });

  it('has unique names', () => {
    expect(new Set(fixtures.map((f) => f.name)).size).toBe(fixtures.length);
  });
});
