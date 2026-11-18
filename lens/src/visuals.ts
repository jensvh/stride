import type { Stats, Visual } from '../../protocol/schema.ts';
import { h } from './dom.ts';

const compact = (n: number) => (Math.abs(n) >= 10_000 ? `${Math.round(n / 1000)}k` : Number.isInteger(n) ? String(n) : n.toFixed(1));

export function renderVisual(v: Visual, caption?: string): HTMLElement {
  const box = h('div', { class: 'visual' }, caption ? h('p', { class: 'caption' }, caption) : null);
  switch (v.type) {
    case 'checklist':
      box.append(
        h(
          'ul',
          { class: 'checklist' },
          ...v.items.map((it) => h('li', { 'data-done': String(it.done) }, h('span', { class: 'box' }), h('span', null, it.text))),
        ),
      );
      break;
    case 'bars': {
      const max = Math.max(...v.items.map((it) => it.max ?? it.value), 1);
      const grid = h('div', { class: 'bars' });
      for (const it of v.items) {
        const pct = Math.max(0, Math.min(100, (it.value / (it.max ?? max)) * 100));
        grid.append(
          h('span', { class: 'label' }, it.label),
          h('span', { class: 'track' }, h('span', { class: 'fill', style: `display:block;width:${pct}%` })),
          h('span', { class: 'value' }, `${compact(it.value)}${v.unit ? ` ${v.unit}` : ''}`),
        );
      }
      box.append(grid);
      break;
    }
    case 'table': {
      const cols = Math.max(v.head?.length ?? 0, ...v.rows.map((r) => r.length), 1);
      const grid = h('div', { class: 'table', style: `grid-template-columns: 1fr repeat(${cols - 1}, max-content)` });
      if (v.head) for (let c = 0; c < cols; c++) grid.append(h('span', { class: 'head' }, v.head[c] ?? ''));
      v.rows.forEach((row, r) => {
        for (let c = 0; c < cols; c++) grid.append(h('span', { class: r === v.rows.length - 1 ? 'last' : '' }, row[c] ?? ''));
      });
      box.append(grid);
      break;
    }
    case 'code':
      box.append(h('pre', { class: 'code' }, v.text));
      break;
  }
  return box;
}

const duration = (s: number) => (s < 90 ? `${s}s` : `${Math.round(s / 60)}m`);

/** The measured numbers under a result: a five-cell diff bar, lines, files, time. */
export function renderStats(s: Stats): HTMLElement | null {
  const parts: (Node | string)[] = [];
  const added = s.added ?? 0;
  const removed = s.removed ?? 0;
  if (added + removed > 0) {
    const cells = 5;
    const a = Math.max(added > 0 ? 1 : 0, Math.min(cells - (removed > 0 ? 1 : 0), Math.round((added / (added + removed)) * cells)));
    const bar = h('span', { class: 'diffbar' });
    for (let i = 0; i < cells; i++) bar.append(h('i', { class: i < a ? 'a' : 'd' }));
    parts.push(bar, h('span', { class: 'add' }, `+${compact(added)}`), h('span', { class: 'del' }, `−${compact(removed)}`));
  }
  if (s.files) parts.push(`${s.files} ${s.files === 1 ? 'file' : 'files'}`);
  if (s.durationS !== undefined) parts.push(duration(s.durationS));
  if (parts.length === 0) return null;
  const row = h('div', { class: 'stats' });
  for (const p of parts) row.append(typeof p === 'string' ? h('span', null, p) : p);
  return row;
}
