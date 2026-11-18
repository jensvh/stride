// Renders one State into one 600x600 frame. No framework: a screen is rebuilt
// when its identity changes, and only its live text is patched otherwise, so
// focus stays where the wearer put it.
import type { CommandName, State } from '../../protocol/schema.ts';
import { h } from './dom.ts';
import { renderStats, renderVisual } from './visuals.ts';

export type Link = 'unpaired' | 'connecting' | 'online' | 'pc-offline';

export type ViewModel = { link: Link; state?: State | undefined };

export type Handlers = {
  prompt: (text: string) => void;
  answer: (askId: string, choice: string) => void;
  command: (name: CommandName) => void;
};

const clock = (ms: number) => {
  const s = Math.max(0, Math.floor(ms / 1000));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
};

export class LensView {
  private readonly root: HTMLElement;
  private readonly on: Handlers;
  private key = '';
  private vm: ViewModel = { link: 'connecting' };
  private patch: (() => void) | undefined;
  private ticker: ReturnType<typeof setInterval> | undefined;
  /** Demo frames must not steal focus from each other. */
  private readonly autofocus: boolean;

  constructor(root: HTMLElement, handlers: Handlers, opts: { autofocus?: boolean } = {}) {
    this.root = root;
    this.on = handlers;
    this.autofocus = opts.autofocus ?? true;
    root.classList.add('lens');
  }

  render(vm: ViewModel): void {
    this.vm = vm;
    const s = vm.state;
    const key = [
      vm.link,
      s?.phase,
      s?.project,
      s?.ask?.id,
      s?.phase === 'idle' ? s.card?.id : '',
      s?.live ? JSON.stringify(s.live) : '',
      s?.phone,
      s?.lensCanPrompt,
    ].join('|');
    if (key !== this.key) {
      this.key = key;
      this.build();
    }
    this.patch?.();
  }

  // ---- screens ----------------------------------------------------------------

  private build(): void {
    if (this.ticker) clearInterval(this.ticker);
    this.ticker = undefined;
    this.patch = undefined;
    const { link, state: s } = this.vm;
    const main = h('div', { class: 'main' });
    const actions = h('div', { class: 'actions' });
    let tone: 'calm' | 'live' | 'bad' = 'calm';
    let label = 'ready';
    let focus: HTMLElement | undefined;

    if (link === 'unpaired') {
      label = 'not paired';
      main.append(h('h1', { class: 'title' }, 'Not paired yet'), h('p', { class: 'quiet' }, 'On the PC, run “npm run pair” and scan the code with your phone.'));
    } else if (!s) {
      label = link === 'pc-offline' ? 'pc offline' : 'connecting';
      tone = link === 'pc-offline' ? 'bad' : 'calm';
      main.append(
        h('h1', { class: 'title' }, link === 'pc-offline' ? 'PC is not answering' : 'Connecting'),
        h('p', { class: 'quiet' }, link === 'pc-offline' ? 'The bridge on your PC may be stopped or offline.' : 'Reaching your PC.'),
      );
    } else if (s.ask) {
      tone = 'live';
      label = 'your call';
      const ask = s.ask;
      if (ask.kind === 'approve') {
        const [verb, ...rest] = ask.title.split(': ');
        const isRun = rest.length > 0 && verb === 'Run';
        main.append(
          h('p', { class: 'kicker' }, ask.detail ?? 'Claude asks'),
          isRun ? h('p', { class: 'command' }, rest.join(': ')) : h('h1', { class: 'title' }, ask.title),
        );
        // Deny has the first focus: a stray pinch must never approve a command.
        const deny = h('button', { onclick: () => this.on.answer(ask.id, 'deny') }, 'Deny');
        const approve = h('button', { onclick: () => this.on.answer(ask.id, 'approve') }, 'Approve');
        actions.append(deny, approve);
        focus = deny;
      } else {
        main.append(h('h1', { class: 'title' }, ask.title));
        const list = h('div', { class: 'options' });
        (ask.options ?? []).forEach((o, i) => {
          const b = h(
            'button',
            { onclick: () => this.on.answer(ask.id, o.label) },
            h('span', { class: 'n' }, String(i + 1)),
            h('span', null, o.label, o.description ? h('small', null, o.description) : null),
          );
          list.append(b);
          if (i === 0) focus = b;
        });
        main.append(list);
      }
    } else if (s.phase === 'listening') {
      tone = 'live';
      label = 'listening';
      const heard = h('p', { class: 'heard' });
      main.append(h('div', { class: 'ring' }), heard);
      this.patch = () => {
        const text = this.vm.state?.transcript ?? '';
        if (heard.textContent !== text) heard.textContent = text;
      };
    } else if (s.phase === 'working') {
      tone = 'live';
      label = 'working';
      const activity = h('p', { class: 'activity' });
      const time = h('span', { class: 'clock' });
      // Fixtures carry startedAt 0; show a plausible running clock for them.
      const started = s.startedAt && s.startedAt > 0 ? s.startedAt : Date.now() - 42_000;
      main.append(h('p', { class: 'task' }, s.transcript ?? ''), activity, h('div', { class: 'progress' }));
      if (s.live) main.append(renderVisual(s.live.visual, s.live.title));
      const stop = h('button', { class: 'small', onclick: () => this.on.command('stop') }, 'Stop');
      actions.append(stop, time);
      focus = stop;
      const tick = () => (time.textContent = clock(Date.now() - started));
      tick();
      this.ticker = setInterval(tick, 1000);
      this.patch = () => {
        const text = this.vm.state?.activity ?? 'Working';
        if (activity.textContent !== text) activity.textContent = text;
      };
    } else {
      // idle: the last result, or a calm "ready"
      const card = s.card;
      if (card) {
        const scroll = h('div', { class: 'scroll' });
        scroll.append(h('h1', { class: 'title', 'data-kind': card.kind }, card.title));
        if (card.lines.length) scroll.append(h('div', { class: 'lines' }, ...card.lines.map((l) => h('p', null, l))));
        if (card.visual) scroll.append(renderVisual(card.visual));
        main.append(scroll);
        const stats = card.stats ? renderStats(card.stats) : null;
        if (stats) main.append(stats);
        main.style.justifyContent = 'flex-start';
        // Only scrollable text takes focus; decided after layout.
        queueMicrotask(() => {
          if (scroll.scrollHeight > scroll.clientHeight + 4) {
            scroll.tabIndex = 0;
            scroll.dataset.more = 'true';
            scroll.addEventListener('scroll', () => {
              scroll.dataset.more = String(scroll.scrollTop + scroll.clientHeight < scroll.scrollHeight - 4);
            });
          }
        });
      } else {
        main.append(h('h1', { class: 'title' }, 'Ready'), h('p', { class: 'quiet' }, s.phone ? 'Pinch Talk and say what you need.' : 'Pinch the field and say what you need.'));
      }

      if (s.phone) {
        const talk = h('button', { onclick: () => this.on.command('talk') }, 'Talk');
        actions.append(talk);
        focus = talk;
      }
      if (s.lensCanPrompt) {
        const field = h('input', { type: 'text', placeholder: s.phone ? 'or dictate here' : 'Ask Claude', enterkeyhint: 'send', autocomplete: 'off', autocapitalize: 'sentences' });
        const submit = () => {
          const text = field.value.trim();
          if (!text) return;
          field.value = '';
          this.on.prompt(text);
        };
        // The glasses' composer commits with "change"; a desktop keyboard with Enter.
        field.addEventListener('change', submit);
        field.addEventListener('keydown', (ev) => {
          if (ev.key === 'Enter') submit();
        });
        actions.append(field);
        focus ??= field;
      }
      if (!s.phone && !s.lensCanPrompt) actions.append(h('p', { class: 'hint' }, 'Open Stride on the phone to talk.'));
    }

    // Without the PC nothing on this screen can act, so say that instead of offering buttons.
    if (s && link !== 'online') {
      tone = link === 'pc-offline' ? 'bad' : 'calm';
      label = link === 'pc-offline' ? 'pc offline' : 'reconnecting';
      focus = undefined;
      actions.replaceChildren(h('p', { class: 'hint' }, link === 'pc-offline' ? 'Your PC is not answering. This is the last thing it sent.' : 'Reconnecting to your PC.'));
    }

    const note = s?.note && !s.ask ? h('p', { class: 'note' }, s.note) : null;
    this.root.replaceChildren(
      h('div', { class: 'top' }, h('span', null, s?.project ?? 'stride'), h('span', { class: 'status', 'data-tone': tone }, h('span', { class: 'dot' }), label)),
      main,
      ...(actions.childNodes.length ? [actions] : []),
      ...(note ? [note] : []),
    );
    if (this.autofocus && focus) focus.focus({ preventScroll: true });
  }
}
