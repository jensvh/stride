// On the glasses, Chromium's spatial navigation moves focus with the Neural
// Band (arrow keys). A desktop browser does not, so this fallback steps in only
// when an arrow key changed nothing: no focus move, no scroll.
const FOCUSABLE = 'button, input, [tabindex="0"]';

export function installArrowFallback(): void {
  document.addEventListener('keydown', (ev) => {
    const dir = ev.key === 'ArrowDown' || ev.key === 'ArrowRight' ? 1 : ev.key === 'ArrowUp' || ev.key === 'ArrowLeft' ? -1 : 0;
    if (!dir) return;
    const before = document.activeElement as HTMLElement | null;
    // Let the caret move inside a text field that has text.
    if (before instanceof HTMLInputElement && before.value && (ev.key === 'ArrowLeft' || ev.key === 'ArrowRight')) return;
    const scrollBefore = before?.scrollTop ?? 0;
    setTimeout(() => {
      if (ev.defaultPrevented) return;
      if (document.activeElement !== before) return; // native navigation handled it
      if (before && before.scrollTop !== scrollBefore) return; // it scrolled instead
      const scope = before?.closest('.lens') ?? document;
      const items = [...scope.querySelectorAll<HTMLElement>(FOCUSABLE)].filter((el) => el.offsetParent !== null);
      if (items.length === 0) return;
      const i = before ? items.indexOf(before) : -1;
      const next = items[i < 0 ? 0 : (i + dir + items.length) % items.length];
      next?.focus();
    }, 0);
  });
}
