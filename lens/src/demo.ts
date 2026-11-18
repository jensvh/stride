// Desktop review without glasses or bridge:
//   ?demo=all       every fixture side by side
//   ?demo=<name>    one fixture at lens size (see protocol/fixtures/states.json)
//   ?demo=offline | connecting | unpaired
import fixtures from '../../protocol/fixtures/states.json';
import type { State } from '../../protocol/schema.ts';
import { LensView, type Link, type ViewModel } from './view.ts';

type Fixture = { name: string; state: State };

const handlers = {
  prompt: (text: string) => console.log('prompt', text),
  answer: (askId: string, choice: string) => console.log('answer', askId, choice),
  command: (name: string) => console.log('command', name),
};

export function runDemo(app: HTMLElement, which: string): void {
  const all: { name: string; vm: ViewModel }[] = [
    ...(fixtures as Fixture[]).map((f) => ({ name: f.name, vm: { link: 'online' as Link, state: f.state } })),
    { name: 'connecting', vm: { link: 'connecting' } },
    { name: 'offline', vm: { link: 'pc-offline', state: (fixtures as Fixture[]).find((f) => f.name === 'result')!.state } },
    { name: 'unpaired', vm: { link: 'unpaired' } },
  ];

  if (which !== 'all') {
    const one = all.find((f) => f.name === which) ?? all[0]!;
    const frame = document.createElement('div');
    app.append(frame);
    new LensView(frame, handlers).render(one.vm);
    return;
  }

  const gallery = document.createElement('div');
  gallery.className = 'gallery';
  app.append(gallery);
  for (const f of all) {
    const fig = document.createElement('figure');
    const cap = document.createElement('figcaption');
    cap.textContent = f.name;
    const frame = document.createElement('div');
    fig.append(cap, frame);
    gallery.append(fig);
    new LensView(frame, handlers, { autofocus: false }).render(f.vm);
  }
}
