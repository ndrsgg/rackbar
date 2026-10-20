const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');

// Copy buttons ---------------------------------------------------------------

const status = document.getElementById('copy-status');
const resetTimers = new WeakMap<HTMLElement, number>();

function copyFallback(text: string) {
  const area = document.createElement('textarea');
  area.value = text;
  area.setAttribute('readonly', '');
  area.style.position = 'fixed';
  area.style.opacity = '0';
  document.body.append(area);
  area.select();
  document.execCommand('copy');
  area.remove();
}

document.addEventListener('click', async (event) => {
  const button = (event.target as Element).closest<HTMLButtonElement>('button[data-copy]');
  if (!button) return;
  const text = button.dataset.copy ?? '';
  try {
    await navigator.clipboard.writeText(text);
  } catch {
    copyFallback(text);
  }
  button.classList.add('copied');
  if (status) {
    // Cleared first, so a second copy of the same thing is announced again.
    status.textContent = '';
    requestAnimationFrame(() => (status.textContent = 'Copied to the clipboard'));
  }
  clearTimeout(resetTimers.get(button));
  resetTimers.set(button, window.setTimeout(() => button.classList.remove('copied'), 1600));
});

// Fade in on scroll ------------------------------------------------------------

const revealed = document.querySelectorAll('[data-reveal]');
if (reducedMotion.matches || !('IntersectionObserver' in window)) {
  revealed.forEach((el) => el.classList.add('in'));
} else {
  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        entry.target.classList.add('in');
        observer.unobserve(entry.target);
      }
    },
    { rootMargin: '0px 0px -8% 0px', threshold: 0.1 },
  );
  revealed.forEach((el) => observer.observe(el));
}

// The terminal -------------------------------------------------------------------

const terminal = document.querySelector<HTMLElement>('[data-terminal]');
const replay = document.querySelector<HTMLButtonElement>('[data-replay]');

if (terminal && !reducedMotion.matches && 'IntersectionObserver' in window) {
  const listAll = terminal.dataset.completeAll ?? '';
  const listWeb = terminal.dataset.completeWeb ?? '';
  const prompt = '<span class="p">~ %</span> ';
  const caret = '<span class="caret"></span>';
  const escape = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');
  const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
  let run = 0;

  const press = (key: string) => {
    const cap = terminal.parentElement?.querySelector(`[data-key="${key}"]`);
    cap?.classList.add('down');
    setTimeout(() => cap?.classList.remove('down'), 260);
  };

  const play = async () => {
    const id = ++run;
    const live = () => id === run;
    let line = '';
    let list = '';
    const draw = (after = caret) => {
      terminal.innerHTML =
        prompt + escape(line) + after + (list ? `\n<span class="c">${escape(list)}</span>` : '');
    };
    const type = async (text: string) => {
      for (const ch of text) {
        if (!live()) return;
        line += ch;
        draw();
        await sleep(55 + Math.random() * 70);
      }
    };

    if (replay) replay.hidden = true;
    draw();
    await sleep(600);
    await type('ssh acme/');
    await sleep(420);
    if (!live()) return;
    press('tab');
    list = listAll;
    draw();
    await sleep(1500);
    await type('w');
    await sleep(320);
    if (!live()) return;
    press('tab');
    line = 'ssh acme/web-';
    list = listWeb;
    draw();
    await sleep(1100);
    await type('1');
    await sleep(650);
    if (!live()) return;
    press('return');
    list = '';
    draw('');
    terminal.innerHTML += '\n';
    await sleep(700);
    if (!live()) return;
    terminal.innerHTML += `<span class="p">root@web-1:~#</span> ${caret}`;
    if (replay) replay.hidden = false;
  };

  const observer = new IntersectionObserver(
    (entries) => {
      if (entries.some((e) => e.isIntersecting)) {
        observer.disconnect();
        play();
      }
    },
    { threshold: 0.6 },
  );
  observer.observe(terminal);
  replay?.addEventListener('click', () => {
    play();
    // The button hides while it plays; keep focus somewhere sensible.
    terminal.closest('figure')?.focus();
  });
}
