import type { State } from '../../protocol/schema.ts';

/**
 * Holds the one State object and publishes it, at most every `minGapMs`.
 * Setting a key to undefined removes it.
 */
export class Store {
  state: State;
  private timer: ReturnType<typeof setTimeout> | undefined;
  private dirty = false;
  private readonly publish: (s: State) => void;
  private readonly minGapMs: number;

  constructor(initial: Omit<State, 'rev'>, publish: (s: State) => void, minGapMs = 150) {
    this.state = { ...initial, rev: 0 };
    this.publish = publish;
    this.minGapMs = minGapMs;
  }

  set(patch: Partial<Omit<State, 'rev'>>): void {
    const next: Record<string, unknown> = { ...this.state, ...patch, rev: this.state.rev + 1 };
    for (const k of Object.keys(next)) if (next[k] === undefined) delete next[k];
    this.state = next as State;
    this.schedule();
  }

  /** Publish now, e.g. when a device says hello. */
  flush(): void {
    if (this.timer) clearTimeout(this.timer);
    this.timer = undefined;
    this.dirty = false;
    this.publish(this.state);
  }

  private schedule(): void {
    if (this.timer) {
      this.dirty = true;
      return;
    }
    this.publish(this.state);
    this.timer = setTimeout(() => {
      this.timer = undefined;
      if (this.dirty) {
        this.dirty = false;
        this.schedule();
      }
    }, this.minGapMs);
  }
}
