// Spectrum 3847 Vision Training — shared runtime.
// Loads chapter partials, runs each chapter's init once it's near the screen, and
// provides small helpers (canvas setup, animation loops that pause off-screen, AprilTags).
(() => {
  const inits = {};
  const Site = (window.Site = {});

  // A chapter script calls Site.chapter('apriltags', root => {...}).
  Site.chapter = (id, fn) => { inits[id] = fn; };

  const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  Site.css = css;
  Site.clamp = (v, a, b) => Math.min(b, Math.max(a, v));
  Site.lerp = (a, b, t) => a + (b - a) * t;
  Site.ease = (t) => (t < .5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
  Site.reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;

  // Retina canvas. Returns a state object whose w/h are CSS pixels; re-sizes with the element.
  // Pass aspect (h/w) to keep a fixed shape.
  Site.canvas = (cv, aspect, onResize) => {
    const st = { cv, ctx: cv.getContext('2d'), w: 0, h: 0, dpr: 1 };
    const fit = () => {
      const w = cv.clientWidth || cv.parentElement.clientWidth;
      const h = aspect ? w * aspect : cv.clientHeight;
      st.dpr = Math.min(devicePixelRatio || 1, 2);
      st.w = w; st.h = h;
      cv.width = Math.round(w * st.dpr); cv.height = Math.round(h * st.dpr);
      if (aspect) cv.style.height = h + 'px';
      st.ctx.setTransform(st.dpr, 0, 0, st.dpr, 0, 0);
      onResize && onResize(st);
    };
    new ResizeObserver(fit).observe(cv.parentElement);
    fit();
    return st;
  };

  // Calls cb(visible) whenever el enters/leaves the viewport.
  Site.onVisible = (el, cb, margin = '100px') => {
    new IntersectionObserver((es) => es.forEach((e) => cb(e.isIntersecting)), { rootMargin: margin }).observe(el);
  };

  // requestAnimationFrame loop that only runs while el is on screen. fn(t seconds, dt).
  Site.loop = (el, fn) => {
    let on = false, last = 0, raf = 0;
    const tick = (ms) => {
      const t = ms / 1000, dt = Math.min(.05, last ? t - last : 0);
      last = t; fn(t, dt);
      if (on) raf = requestAnimationFrame(tick);
    };
    Site.onVisible(el, (v) => {
      if (v && !on) { on = true; last = 0; raf = requestAnimationFrame(tick); }
      if (!v) { on = false; cancelAnimationFrame(raf); }
    });
  };

  // 0 when el's top reaches the bottom of the screen, 1 when its bottom leaves the top.
  Site.progress = (el) => {
    const r = el.getBoundingClientRect(), vh = innerHeight;
    return Site.clamp((vh - r.top) / (vh + r.height), 0, 1);
  };

  // Scrollytelling: calls cb(index, stepEl) as each .step crosses the middle of the screen.
  // The active step is the visible step whose text box is closest to the middle of the screen,
  // recomputed on every scroll, so it can't get stuck in either direction (a thin
  // IntersectionObserver band could miss a step entirely on a fast or reversed scroll).
  Site.scrolly = (root, cb) => {
    const steps = [...root.querySelectorAll('.step')];
    const prog = scrollyProgress(root, steps);
    let cur = -1, on = false, queued = false;
    const vis = root.querySelector('.vis');
    const pick = () => {
      queued = false;
      // Desktop: the middle of the screen. Phones (visual pinned above the steps): the middle
      // of the open area below the visual, where the step boxes snap.
      let mid = innerHeight / 2;
      if (vis) {
        const v = vis.getBoundingClientRect();
        root.style.setProperty('--vis-h', Math.round(v.height) + 'px');
        if (v.width > root.clientWidth * .7) mid = (Math.max(0, v.bottom) + innerHeight) / 2;
      }
      let best = -1, bd = Infinity;
      steps.forEach((s, j) => {
        if (!s.getClientRects().length) return; // hidden in this mode
        const r = (s.querySelector('.box') || s).getBoundingClientRect();
        const d = Math.abs((r.top + r.bottom) / 2 - mid);
        if (d < bd) { bd = d; best = j; }
      });
      if (best < 0 || best === cur) return;
      cur = best;
      steps.forEach((s, j) => s.classList.toggle('active', j === best));
      prog.set(best);
      cb(best, steps[best]);
    };
    const req = () => { if (on && !queued) { queued = true; requestAnimationFrame(pick); } };
    // only track while the block is near the screen
    new IntersectionObserver((es) => { on = es[0].isIntersecting; if (on) req(); }, { rootMargin: '50% 0px' }).observe(root);
    addEventListener('scroll', req, { passive: true });
    addEventListener('resize', req);
    new ResizeObserver(req).observe(root); // the layout can shift without a scroll (a visual resizing)
    addEventListener('site:mode', () => { cur = -1; req(); });
    return steps;
  };

  // Progress rail for a scrollytelling block: one dot per visible step, click to jump.
  // Shared by every Site.scrolly call on the same root (some chapters register two callbacks).
  function scrollyProgress(root, steps) {
    if (root._prog) return root._prog;
    const vis = root.querySelector('.vis') || root;
    const rail = document.createElement('div');
    rail.className = 'sc-prog';
    rail.setAttribute('aria-label', 'Steps');
    const title = (st) => (st.querySelector('h4, h5, .step-title')?.textContent || '').trim();
    let active = 0;
    const build = () => {
      const shown = steps.filter((st) => st.offsetParent !== null || st.getClientRects().length);
      rail.innerHTML = shown.map((st) => `<button type="button" data-i="${steps.indexOf(st)}" title="${title(st).replace(/"/g, '&quot;')}" aria-label="Go to step: ${title(st).replace(/"/g, '&quot;')}"></button>`).join('') + '<span class="n"></span>';
      set(active);
    };
    const set = (i) => {
      active = i;
      const btns = [...rail.querySelectorAll('button')];
      const k = btns.findIndex((b) => +b.dataset.i === i);
      btns.forEach((b, j) => { b.classList.toggle('on', j === k); b.classList.toggle('done', j < k); });
      rail.querySelector('.n').textContent = `${Math.max(1, k + 1)} / ${btns.length}`;
    };
    rail.addEventListener('click', (e) => {
      const b = e.target.closest('button');
      if (b) steps[+b.dataset.i].scrollIntoView({ behavior: Site.reduced ? 'auto' : 'smooth', block: 'center' });
    });
    vis.appendChild(rail);
    // sit in the gap on whichever side the step text is
    const side = () => { const st = root.querySelector('.steps'); rail.classList.toggle('right', !!st && st.getBoundingClientRect().left > vis.getBoundingClientRect().left); };
    new ResizeObserver(side).observe(root);
    build();
    addEventListener('site:mode', build);
    return (root._prog = { set });
  }

  // Binds a range input to an <output>, calling fn(value) now and on every change.
  Site.range = (input, fn, fmt = (v) => v) => {
    const out = input.closest('.ctl')?.querySelector('output');
    const run = () => { const v = +input.value; if (out) out.textContent = fmt(v); fn(v); };
    input.addEventListener('input', run);
    run();
  };

  // Segmented buttons: <div class="seg"><button data-v="a">. fn(value) on click.
  Site.seg = (el, fn) => {
    el.addEventListener('click', (e) => {
      const b = e.target.closest('button');
      if (!b) return;
      el.querySelectorAll('button').forEach((x) => x.classList.toggle('on', x === b));
      fn(b.dataset.v, b);
    });
    const on = el.querySelector('.on') || el.querySelector('button');
    on.classList.add('on');
    fn(on.dataset.v, on);
  };

  /* ── AprilTags (tag36h11) ─────────────────────────────────
     Codes and bit positions from AprilRobotics/apriltag tag36h11.c; checked pixel for pixel
     against the official tag images. Grid is 10x10: white ring, black ring, 6x6 data. */
  const CODES = [0xd7e00984b,0xdda664ca7,0xdc4a1c821,0xe17b470e9,0xef91d01b1,0xf429cdd73,0x5da29225,0x1106cba43,0x223bed79d,0x21f51213c,0x33eb19ca6,0x3f76eb0f8,0x469a97414,0x45dcfe0b0,0x4a6465f72,0x51801db96,0x5eb946b4e,0x68a7cc2ec,0x6f0ba2652,0x78765559d,0x87b83d129,0x86cc4a5c5,0x8b64df90f,0x9c577b611,0xa3810f2f5,0xaf4d75b83,0xb59a03fef,0xbb1096f85,0xd1b92fc76,0xd0dd509d2,0xe2cfda160,0x2ff497c63,0x47240671b,0x5047a2e55,0x635ca87c7,0x691254166,0x68f43d94a,0x6ef24bdb6,0x8cdd8f886,0x9de96b718,0xaff6e5a8a,0xbae46f029,0xd225b6d59,0xdf8ba8c01,0xe3744a22f,0xfbb59375d,0x18a916828,0x22f29c1ba];
  const BX = [1,2,3,4,5,2,3,4,3,6,6,6,6,6,5,5,5,4,6,5,4,3,2,5,4,3,4,1,1,1,1,1,2,2,2,3];
  const BY = [1,1,1,1,1,2,2,2,3,1,2,3,4,5,2,3,4,3,6,6,6,6,6,5,5,5,4,6,5,4,3,2,5,4,3,4];
  Site.TAG_COUNT = CODES.length;
  Site.tagCode = (id) => CODES[id];
  // 10x10 array of rows, 1 = white. bitOf lets callers see which data bit each cell holds.
  Site.tagGrid = (id) => {
    const g = Array.from({ length: 10 }, (_, y) => Array.from({ length: 10 }, (_, x) => (x === 0 || y === 0 || x === 9 || y === 9 ? 1 : 0)));
    const code = CODES[id];
    for (let i = 0; i < 36; i++) if (Math.floor(code / 2 ** (35 - i)) % 2) g[BY[i] + 1][BX[i] + 1] = 1;
    return g;
  };
  Site.tagBitIndex = (x, y) => { for (let i = 0; i < 36; i++) if (BX[i] + 1 === x && BY[i] + 1 === y) return i; return -1; };
  // Draw tag id with its outer black border filling size px (the white ring is outside it
  // when quiet=true, as on a real field tag).
  Site.drawTag = (ctx, id, x, y, size, { quiet = false, white = '#fff', black = '#000' } = {}) => {
    const g = Site.tagGrid(id), c = size / 8, o = quiet ? 0 : 1;
    ctx.fillStyle = white;
    if (quiet) ctx.fillRect(x - c, y - c, size + 2 * c, size + 2 * c);
    for (let r = 1; r < 9; r++) for (let q = 1; q < 9; q++) {
      ctx.fillStyle = g[r][q] ? white : black;
      ctx.fillRect(x + (q - 1) * c - .25, y + (r - 1) * c - .25, c + .5, c + .5);
    }
    return o;
  };
  // Tag as an SVG string (for inline figures). Includes the white quiet ring.
  Site.tagSVG = (id, px = 100) => {
    const g = Site.tagGrid(id);
    let r = '';
    for (let y = 0; y < 10; y++) for (let x = 0; x < 10; x++) if (!g[y][x]) r += `<rect x="${x}" y="${y}" width="1.02" height="1.02"/>`;
    return `<svg viewBox="0 0 10 10" width="${px}" height="${px}" shape-rendering="crispEdges"><rect width="10" height="10" fill="#fff"/><g fill="#000">${r}</g></svg>`;
  };

  // Projective warp: draw a unit-square image (source canvas) into 4 destination corners
  // by splitting into small triangles. Good enough for teaching visuals.
  Site.drawQuad = (ctx, img, pts, n = 10) => {
    const sw = img.width, sh = img.height;
    const at = (u, v) => {
      // bilinear-in-homography: use proper projective mapping via corner homography
      return Site._homog(pts, u, v);
    };
    for (let i = 0; i < n; i++) for (let j = 0; j < n; j++) {
      const u0 = i / n, u1 = (i + 1) / n, v0 = j / n, v1 = (j + 1) / n;
      const p00 = at(u0, v0), p10 = at(u1, v0), p01 = at(u0, v1), p11 = at(u1, v1);
      tri(ctx, img, [u0 * sw, v0 * sh, u1 * sw, v0 * sh, u0 * sw, v1 * sh], [p00, p10, p01]);
      tri(ctx, img, [u1 * sw, v0 * sh, u1 * sw, v1 * sh, u0 * sw, v1 * sh], [p10, p11, p01]);
    }
  };
  function tri(ctx, img, s, d) {
    const [x0, y0, x1, y1, x2, y2] = s;
    const [[X0, Y0], [X1, Y1], [X2, Y2]] = d;
    ctx.save();
    ctx.beginPath();
    // expand the clip triangle a hair to hide seams
    const cx = (X0 + X1 + X2) / 3, cy = (Y0 + Y1 + Y2) / 3, k = 1.02;
    ctx.moveTo(cx + (X0 - cx) * k, cy + (Y0 - cy) * k);
    ctx.lineTo(cx + (X1 - cx) * k, cy + (Y1 - cy) * k);
    ctx.lineTo(cx + (X2 - cx) * k, cy + (Y2 - cy) * k);
    ctx.closePath(); ctx.clip();
    const den = x0 * (y2 - y1) - x1 * y2 + x2 * y1 + (x1 - x2) * y0;
    if (den) {
      const a = -(y0 * (X2 - X1) - y1 * X2 + y2 * X1 + (y1 - y2) * X0) / den;
      const b = (y1 * Y2 + y0 * (Y1 - Y2) - y2 * Y1 + (y2 - y1) * Y0) / den;
      const c = (x0 * (X2 - X1) - x1 * X2 + x2 * X1 + (x1 - x2) * X0) / den;
      const d2 = -(x1 * Y2 + x0 * (Y1 - Y2) - x2 * Y1 + (x2 - x1) * Y0) / den;
      const e = (x0 * (y2 * X1 - y1 * X2) + y0 * (x1 * X2 - x2 * X1) + (x2 * y1 - x1 * y2) * X0) / den;
      const f = (x0 * (y2 * Y1 - y1 * Y2) + y0 * (x1 * Y2 - x2 * Y1) + (x2 * y1 - x1 * y2) * Y0) / den;
      ctx.transform(a, b, c, d2, e, f);
      ctx.drawImage(img, 0, 0);
    }
    ctx.restore();
  }
  // Maps (u,v) in the unit square to the quad pts=[[x,y] TL, TR, BR, BL] with a true homography.
  Site._homog = (pts, u, v) => {
    const [[x0, y0], [x1, y1], [x2, y2], [x3, y3]] = pts;
    const dx1 = x1 - x2, dx2 = x3 - x2, dy1 = y1 - y2, dy2 = y3 - y2;
    const sx = x0 - x1 + x2 - x3, sy = y0 - y1 + y2 - y3;
    let g = 0, h = 0;
    const den = dx1 * dy2 - dx2 * dy1;
    if (den) { g = (sx * dy2 - dx2 * sy) / den; h = (dx1 * sy - sx * dy1) / den; }
    const a = x1 - x0 + g * x1, b = x3 - x0 + h * x3, c = x0;
    const d = y1 - y0 + g * y1, e = y3 - y0 + h * y3, f = y0;
    const w = g * u + h * v + 1;
    return [(a * u + b * v + c) / w, (d * u + e * v + f) / w];
  };
  // Offscreen canvas holding tag id (with quiet ring), px pixels square.
  const tagCache = {};
  Site.tagCanvas = (id, px = 200) => {
    const k = id + ':' + px;
    if (tagCache[k]) return tagCache[k];
    const c = document.createElement('canvas');
    c.width = c.height = px;
    const x = c.getContext('2d');
    x.imageSmoothingEnabled = false;
    const g = Site.tagGrid(id), s = px / 10;
    for (let r = 0; r < 10; r++) for (let q = 0; q < 10; q++) { x.fillStyle = g[r][q] ? '#fff' : '#000'; x.fillRect(Math.floor(q * s), Math.floor(r * s), Math.ceil(s), Math.ceil(s)); }
    return (tagCache[k] = c);
  };

  /* ── Glossary tooltips: <span class="term" data-term="GPU">GPUs</span> ── */
  Site.glossary = {};
  let tip;
  document.addEventListener('mouseover', (e) => {
    const t = e.target.closest('.term');
    if (!t) { tip && tip.remove(); tip = null; return; }
    const key = t.dataset.term || t.textContent.trim();
    const def = t.dataset.def || Site.glossary[key] || Site.glossary[key.toLowerCase()];
    if (!def) return;
    tip && tip.remove();
    tip = document.createElement('div');
    tip.className = 'term-tip';
    tip.innerHTML = `<b>${key}</b> — ${def}`;
    document.body.appendChild(tip);
    const r = t.getBoundingClientRect();
    const x = Site.clamp(r.left + scrollX, 8, scrollX + innerWidth - tip.offsetWidth - 8);
    tip.style.left = x + 'px';
    tip.style.top = r.bottom + scrollY + 8 + 'px';
  });

  /* ── Page chrome ───────────────────────────────────────── */
  const reveal = new IntersectionObserver((es) => es.forEach((e) => { if (e.isIntersecting) { e.target.classList.add('in'); reveal.unobserve(e.target); } }), { rootMargin: '0px 0px -8% 0px' });
  Site.watchReveals = (root) => root.querySelectorAll('.reveal').forEach((el) => reveal.observe(el));

  async function load() {
    const secs = [...document.querySelectorAll('section[data-src]')];
    // Fetch every partial in parallel, insert in order.
    const htmls = await Promise.all(secs.map((s) => fetch(s.dataset.src).then((r) => (r.ok ? r.text() : `<div class="shell"><p>Missing ${s.dataset.src}</p></div>`)).catch(() => `<div class="shell"><p>Could not load ${s.dataset.src}. Open this site through a web server (see training/README.md).</p></div>`)));
    secs.forEach((s, i) => { s.innerHTML = htmls[i]; });
    measureTimes();
    buildToc();
    showTimes();
    Site.watchReveals(document);
    // Initialise each chapter's interactive parts when it gets near the screen.
    secs.forEach((s) => {
      const io = new IntersectionObserver((es) => {
        if (!es[0].isIntersecting) return;
        io.disconnect();
        const fn = inits[s.id];
        if (fn) { try { fn(s); } catch (err) { console.error('chapter', s.id, err); } }
      }, { rootMargin: '600px 0px' });
      io.observe(s);
    });
    restorePlace();
  }

  function buildToc() {
    const toc = document.querySelector('.toc nav');
    const road = document.querySelector('.roadmap-grid');
    let html = '', roadHtml = '', part = null;
    document.querySelectorAll('section.part, section.chapter').forEach((s) => {
      if (s.classList.contains('part')) {
        if (part) roadHtml += '</div>';
        part = s;
        html += `<h4>Part ${s.dataset.num} · ${s.dataset.title}</h4>`;
        roadHtml += `<div class="road-part reveal"><h4><span>${s.dataset.num}</span>${s.dataset.title}</h4><p>${s.querySelector('p')?.innerHTML || ''}</p>`;
      } else {
        const t = s.dataset.title, n = s.dataset.n, cls = s.classList.contains('full') ? ' class="full"' : '';
        const tm = `<i data-ts="${s.dataset.tshort}" data-tf="${s.dataset.tfull}"></i>`;
        html += `<a href="#${s.id}"${cls}><b>${n}</b>${t}${tm}</a>`;
        roadHtml += `<a href="#${s.id}"${cls}><b>${n}</b>${t}${tm}</a>`;
      }
    });
    toc.innerHTML = html;
    if (road) road.innerHTML = roadHtml + '</div>';
  }

  /* ── Short / Full mode ──────────────────────────────────
     body.mode-short hides .full and details.deep; body.mode-full hides .short.
     Chosen with ?mode=short|full, the switches, or the last choice (localStorage). */
  const getSaved = () => { try { return localStorage.getItem('vt-mode'); } catch (e) { return null; } };
  Site.mode = new URLSearchParams(location.search).get('mode') || getSaved() || 'short';
  if (Site.mode !== 'full') Site.mode = 'short';
  const applyClass = (m) => { document.body.classList.toggle('mode-short', m === 'short'); document.body.classList.toggle('mode-full', m === 'full'); };
  // The address always says which version you're on, so a copied or shared link opens the same one.
  const baseTitle = document.title;
  const showInUrl = (m) => {
    const u = new URL(location.href);
    u.searchParams.set('mode', m);
    history.replaceState(history.state, '', u);
    document.title = `${baseTitle} (${m === 'short' ? 'Short tour' : 'Full course'})`;
  };
  Site.setMode = (m, keepPlace = true) => {
    if (m !== 'short' && m !== 'full') return;
    // keep the reader's place: remember what's at the top of the screen, restore it after the switch
    let anchor = null, top = 0;
    if (keepPlace && scrollY > innerHeight) {
      const el = document.elementFromPoint(innerWidth / 2, 90);
      anchor = el && (el.closest('.full, .short, details.deep') ? el.closest('section') : el);
      top = anchor ? anchor.getBoundingClientRect().top : 0;
    }
    Site.mode = m;
    applyClass(m);
    try { localStorage.setItem('vt-mode', m); } catch (e) {}
    showInUrl(m);
    document.querySelectorAll('[data-mode]').forEach((b) => b.classList.toggle('on', b.dataset.mode === m));
    showTimes();
    if (anchor) scrollBy({ top: anchor.getBoundingClientRect().top - top, behavior: 'instant' });
    dispatchEvent(new CustomEvent('site:mode', { detail: m }));
  };
  // Reading time per chapter and mode: visible words at ~220 wpm plus ~1 min per lab.
  function measureTimes() {
    const chapters = [...document.querySelectorAll('section.chapter')];
    const measure = (m) => {
      applyClass(m);
      let total = 0;
      chapters.forEach((c) => {
        const hidden = m === 'short' && c.classList.contains('full');
        const words = hidden ? 0 : (c.innerText.match(/\S+/g) || []).length;
        const labs = hidden ? 0 : [...c.querySelectorAll('.lab')].filter((l) => l.offsetParent).length;
        const min = hidden ? 0 : Math.max(1, Math.round(words / 220 + labs));
        // content a chapter builds with JS after load (e.g. the quiz) isn't in the DOM yet: data-extra-short / data-extra-full add minutes for it
        const t = min + (hidden ? 0 : +(c.dataset['extra' + m[0].toUpperCase() + m.slice(1)] || 0));
        c.dataset['t' + m] = t;
        total += t;
      });
      return total;
    };
    Site.totals = { short: measure('short'), full: measure('full') };
    applyClass(Site.mode);
  }
  const fmt = (min) => (min < 60 ? `${min} min` : `${Math.floor(min / 60)} h ${String(min % 60).padStart(2, '0')}`);
  function showTimes() {
    if (!Site.totals) return;
    document.querySelectorAll('.t-short').forEach((e) => (e.textContent = '~' + fmt(Site.totals.short)));
    document.querySelectorAll('.t-full').forEach((e) => (e.textContent = '~' + fmt(Site.totals.full)));
    document.querySelectorAll('.modesw [data-mode] small').forEach((e) => (e.textContent = fmt(Site.totals[e.parentElement.dataset.mode])));
    document.querySelectorAll('i[data-ts]').forEach((e) => (e.textContent = (Site.mode === 'short' ? e.dataset.ts : e.dataset.tf) + ' min'));
  }

  function chrome() {
    applyClass(Site.mode);
    showInUrl(Site.mode);
    document.querySelectorAll('[data-mode]').forEach((b) => { b.classList.toggle('on', b.dataset.mode === Site.mode); b.addEventListener('click', () => Site.setMode(b.dataset.mode)); });
    const nav = document.querySelector('.topnav');
    const bar = nav.querySelector('.progress');
    const now = nav.querySelector('.now');
    const toc = document.querySelector('.toc'), scrim = document.querySelector('.scrim');
    const open = (v) => { toc.classList.toggle('open', v); scrim.classList.toggle('open', v); };
    nav.querySelector('.menu').onclick = () => open(true);
    toc.querySelector('.close').onclick = () => open(false);
    scrim.onclick = () => open(false);
    toc.addEventListener('click', (e) => { if (e.target.closest('a')) open(false); });
    addEventListener('keydown', (e) => { if (e.key === 'Escape') open(false); });
    let ticking = false;
    addEventListener('scroll', () => {
      if (ticking) return;
      ticking = true;
      requestAnimationFrame(() => {
        ticking = false;
        const h = document.documentElement;
        bar.style.width = (100 * h.scrollTop) / (h.scrollHeight - innerHeight) + '%';
        // which chapter is at the top?
        let cur = null;
        for (const s of document.querySelectorAll('section.chapter')) { if (!s.offsetParent) continue; /* hidden in this mode */ if (s.getBoundingClientRect().top < innerHeight * .3) cur = s; else break; }
        const label = cur ? `<b>${cur.dataset.n}</b>${cur.dataset.title}` : '';
        if (now.innerHTML !== label) {
          now.innerHTML = label;
          toc.querySelectorAll('a').forEach((a) => a.classList.toggle('active', cur && a.getAttribute('href') === '#' + cur.id));
        }
      });
    }, { passive: true });
  }

  /* ── Keep the reader's place across refresh, zoom and resize ─────────────
     The chapters load after the page and the labs resize as they start, so the browser's
     own pixel-based restore lands in the wrong place. Instead we remember which element is
     at the top of the screen (as a path from its top-level section) and how far into it
     you were, then hold you there while the page settles, until you scroll yourself. */
  if ('scrollRestoration' in history) history.scrollRestoration = 'manual';
  const LINE = () => (parseFloat(css('--nav-h')) || 60) + 12; // the reading line, just under the top bar
  const tops = () => [...document.querySelectorAll('body > section')];
  const pathOf = (el, root) => { const p = []; while (el && el !== root) { p.unshift([...el.parentElement.children].indexOf(el)); el = el.parentElement; } return el === root ? p : null; };
  const fromPath = (root, p) => p.reduce((el, i) => el && el.children[i], root);
  let anchor = null, pinUntil = 0, pinning = false;
  function takeAnchor() {
    if (scrollY < 40) return { top: true };
    const y = LINE();
    let el = document.elementFromPoint(innerWidth / 2, y);
    if (!el || el.closest('.topnav, .toc, .scrim')) return anchor;
    // sticky visuals move with the scroll, so anchor to their scrolly block instead
    const sticky = el.closest('.scrolly .vis');
    if (sticky) el = sticky.closest('.scrolly');
    const sec = el.closest('body > section');
    if (!sec) return anchor;
    const r = el.getBoundingClientRect();
    return { el, sec: tops().indexOf(sec), path: pathOf(el, sec), frac: r.height ? (y - r.top) / r.height : 0 };
  }
  function applyAnchor(a) {
    if (!a) return;
    if (a.top) { scrollTo({ top: 0, behavior: 'instant' }); return; }
    let el = a.el && a.el.isConnected ? a.el : null;
    if (!el) { const sec = tops()[a.sec]; el = sec && a.path ? fromPath(sec, a.path) : null; if (!el) el = sec; }
    if (!el || !el.getClientRects().length) return;
    const r = el.getBoundingClientRect();
    const d = r.top + (a.frac || 0) * r.height - LINE();
    if (Math.abs(d) > 1) { pinning = true; scrollBy({ top: d, behavior: 'instant' }); pinning = false; }
  }
  // Hold the anchor for a while (layout still settling); any input from the reader releases it.
  function pin(a, ms) { anchor = a; pinUntil = performance.now() + ms; applyAnchor(a); }
  const release = () => { pinUntil = 0; };
  ['wheel', 'touchstart', 'keydown', 'pointerdown'].forEach((t) => addEventListener(t, release, { passive: true }));
  new ResizeObserver(() => { if (performance.now() < pinUntil) applyAnchor(anchor); }).observe(document.body);
  addEventListener('scroll', () => { if (!pinning && performance.now() >= pinUntil) anchor = takeAnchor(); }, { passive: true });
  // zoom or window resize: go back to the element you were reading. Only when the width
  // changes: phones resize the height every time the address bar shows or hides.
  let lastW = innerWidth;
  addEventListener('resize', () => {
    if (innerWidth === lastW) return;
    lastW = innerWidth;
    const a = anchor; if (a) { pin(a, 1500); requestAnimationFrame(() => applyAnchor(a)); }
  });
  // In-page links (menu, course map, "chapter 14" in the text, the preview steps): jump there
  // instantly and hold the target under the top bar while nearby chapters start up and resize.
  Site.goTo = (id, push = true) => {
    const t = id && document.getElementById(id);
    if (!t || !t.getClientRects().length) return false;
    if (push) {
      // remember where you were, so Back returns there
      const here = takeAnchor();
      history.replaceState({ ...(history.state || {}), place: here && (here.top ? { top: true } : { sec: here.sec, path: here.path, frac: here.frac }) }, '');
      history.pushState({}, '', location.search + '#' + id);
    }
    const a = { el: t, frac: 0 };
    anchor = a; pinUntil = performance.now() + 3000;
    applyAnchor(a);
    return true;
  };
  document.addEventListener('click', (e) => {
    const link = e.target.closest('a[href^="#"]');
    if (!link || e.defaultPrevented || e.button || e.metaKey || e.ctrlKey || e.shiftKey) return;
    const id = decodeURIComponent(link.getAttribute('href').slice(1));
    if (id === 'top') { e.preventDefault(); history.pushState(history.state, '', location.search + '#top'); pin({ top: true }, 500); return; }
    if (Site.goTo(id)) e.preventDefault();
  });
  addEventListener('popstate', (e) => {
    if (e.state && e.state.place) { pin(e.state.place, 2500); return; }
    const id = location.hash.slice(1); if (id) Site.goTo(id, false);
  });
  const KEY = 'vt-place:' + location.pathname;
  addEventListener('pagehide', () => {
    const a = takeAnchor();
    try { sessionStorage.setItem(KEY, JSON.stringify(a && (a.top ? { top: true } : { sec: a.sec, path: a.path, frac: a.frac }))); } catch (e) {}
  });
  function restorePlace() {
    let saved = null;
    try { saved = JSON.parse(sessionStorage.getItem(KEY) || 'null'); } catch (e) {}
    // A reload (or Back) returns to where you were; a link you opened goes to its #target.
    const nav = performance.getEntriesByType('navigation')[0];
    const returning = nav && (nav.type === 'reload' || nav.type === 'back_forward');
    const id = location.hash.slice(1);
    if (returning && saved) pin(saved, 6000);
    else if (id && Site.goTo(id, false)) pinUntil = performance.now() + 5000;
    anchor = anchor || takeAnchor();
  }

  /* ── Phones: pin a lab's picture while you scroll its controls ──────────────
     In a .lab-grid whose first column is a visual (no controls) and whose second column has
     the controls, keep the visual stuck under the top bar on narrow screens, but only when it
     takes less than half the screen, so the controls always have room. */
  function stickVisuals() {
    document.querySelectorAll('.lab-grid').forEach((g) => {
      const [a, b] = g.children;
      const ok = innerWidth <= 860 && a && b && !a.querySelector('input, select, button') && b.querySelector('input, select, button') && a.offsetHeight > 60 && a.offsetHeight < innerHeight * 0.5;
      g.classList.toggle('stick-vis', !!ok);
      if (!g._ro) { g._ro = new ResizeObserver(() => requestAnimationFrame(stickVisuals)); g._ro.observe(a || g); }
    });
  }
  addEventListener('resize', () => requestAnimationFrame(stickVisuals));
  addEventListener('site:mode', () => requestAnimationFrame(stickVisuals));
  Site.stickVisuals = stickVisuals;

  document.addEventListener('DOMContentLoaded', () => { chrome(); load().then(stickVisuals); });
})();
