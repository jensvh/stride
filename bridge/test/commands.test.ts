import { describe, expect, it } from 'vitest';
import { matchProject, route } from '../src/commands.ts';

const projects = [
  { name: 'api', aliases: ['backend', 'the api'] },
  { name: 'rollmonitoring', aliases: ['roll monitoring'] },
];
const ctx = { projects };

describe('route without a pending question', () => {
  it('sends ordinary speech to Claude unchanged', () => {
    expect(route('Fix the failing importer test, please.', ctx)).toEqual({
      kind: 'prompt',
      text: 'Fix the failing importer test, please.',
    });
  });

  it.each([
    ['stop', 'stop'],
    ['Stop that.', 'stop'],
    ['cancel', 'stop'],
    ['status', 'status'],
    ["What's the status?", 'status'],
    ['repeat that', 'repeat'],
    ['undo that', 'undo'],
    ['new session', 'new'],
    ['start a new conversation', 'new'],
  ])('"%s" is the %s command', (said, name) => {
    expect(route(said, ctx)).toEqual({ kind: 'command', name });
  });

  it('switches only to known projects', () => {
    expect(route('switch to the backend', ctx)).toEqual({ kind: 'command', name: 'switch', arg: 'api' });
    expect(route('Switch to roll monitoring.', ctx)).toEqual({ kind: 'command', name: 'switch', arg: 'rollmonitoring' });
    expect(route('switch to pnpm instead of npm', ctx)).toEqual({ kind: 'prompt', text: 'switch to pnpm instead of npm' });
  });

  it('does not treat a sentence that merely starts with a command word as a command', () => {
    expect(route('stop the dev server and check the logs', ctx).kind).toBe('prompt');
    expect(route('undo the change to the readme only', ctx).kind).toBe('prompt');
  });
});

describe('route with an approval pending', () => {
  const asking = { projects, ask: { kind: 'approve' as const } };

  it.each(['approve', 'Approve.', 'go ahead', 'yes, run it'])('"%s" approves', (said) => {
    expect(route(said, asking)).toEqual({ kind: 'answer', choice: 'approve' });
  });

  it.each(['yes', 'yeah', 'okay', 'sure', 'mm'])('a bare "%s" never approves', (said) => {
    expect(route(said, asking)).toEqual({ kind: 'reask' });
  });

  it('denies, and keeps the instruction in the user\'s own words', () => {
    expect(route('deny', asking)).toEqual({ kind: 'answer', choice: 'deny' });
    expect(route('no', asking)).toEqual({ kind: 'answer', choice: 'deny' });
    expect(route('Deny, use pnpm instead.', asking)).toEqual({ kind: 'answer', choice: 'deny', text: 'use pnpm instead.' });
    expect(route('no use Yarn', asking)).toEqual({ kind: 'answer', choice: 'deny', text: 'use Yarn' });
  });

  it('does not start a new task from unrelated speech', () => {
    expect(route('what a nice view up here', asking)).toEqual({ kind: 'reask' });
  });
});

describe('route with a choice pending', () => {
  const asking = { projects, ask: { kind: 'choice' as const, options: ['Postgres', 'SQLite', 'Keep the JSON file'] } };

  it('accepts numbers and ordinals', () => {
    expect(route('two', asking)).toEqual({ kind: 'choice', label: 'SQLite' });
    expect(route('option one', asking)).toEqual({ kind: 'choice', label: 'Postgres' });
    expect(route('the third one', asking)).toEqual({ kind: 'choice', label: 'Keep the JSON file' });
  });

  it('accepts the label, whole or in part', () => {
    expect(route('sqlite', asking)).toEqual({ kind: 'choice', label: 'SQLite' });
    expect(route('keep the json file please', asking)).toEqual({ kind: 'choice', label: 'Keep the JSON file' });
  });

  it('passes anything else through as a free answer', () => {
    expect(route('Use DuckDB', asking)).toEqual({ kind: 'choice', label: 'Use DuckDB' });
  });
});

describe('matchProject', () => {
  it('ignores filler words and spacing', () => {
    expect(matchProject('the api project', projects)).toBe('api');
    expect(matchProject('roll  monitoring', projects)).toBe('rollmonitoring');
    expect(matchProject('Rollmonitoring', projects)).toBe('rollmonitoring');
    expect(matchProject('something else', projects)).toBeUndefined();
  });
});
