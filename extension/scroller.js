// Auto-scroll for any website: runs in timed sets (default 30 minutes), with optional breaks between sets.
(() => {
  if (window.__signalScroller) return;
  window.__signalScroller = true;

  let state = null; // { endsAt, setsLeft, speed, breakMin, setMin, phase: 'scroll'|'break', phaseEnds }
  let raf = 0, last = 0, stuckFor = 0, lastY = -1, badge = null;

  function scroller() {
    const se = document.scrollingElement || document.documentElement;
    if (se.scrollHeight > innerHeight + 50) return se;
    // Pages that scroll an inner panel instead of the window: pick the biggest scrollable element.
    let best = null, bestArea = 0;
    for (const el of document.querySelectorAll("body *")) {
      const cs = getComputedStyle(el);
      if (!/(auto|scroll)/.test(cs.overflowY) || el.scrollHeight <= el.clientHeight + 50) continue;
      const area = el.clientWidth * el.clientHeight;
      if (area > bestArea) { best = el; bestArea = area; }
    }
    return best || se;
  }

  function showBadge() {
    if (!badge) {
      badge = document.createElement("div");
      badge.style.cssText = "position:fixed;right:14px;bottom:14px;z-index:2147483647;background:#161a2e;color:#fff;font:600 12px/1.3 -apple-system,Segoe UI,Roboto,Arial,sans-serif;padding:8px 12px;border-radius:10px;box-shadow:0 4px 14px rgba(0,0,0,.3);cursor:pointer;user-select:none";
      badge.title = "Click to stop auto-scroll";
      badge.addEventListener("click", stop);
      document.documentElement.appendChild(badge);
    }
    const left = Math.max(0, state.phaseEnds - Date.now());
    const mm = Math.floor(left / 60000), ss = Math.floor((left % 60000) / 1000);
    const setNo = state.totalSets - state.setsLeft + 1;
    badge.textContent = state.phase === "scroll"
      ? `Auto-scroll · set ${setNo}/${state.totalSets} · ${mm}:${String(ss).padStart(2, "0")} left · click to stop`
      : `Break · next set in ${mm}:${String(ss).padStart(2, "0")} · click to stop`;
  }

  function tick(t) {
    if (!state) return;
    const now = Date.now();
    if (now >= state.phaseEnds) {
      if (state.phase === "scroll") {
        state.setsLeft--;
        if (state.setsLeft <= 0) return stop("done");
        state.phase = "break";
        state.phaseEnds = now + state.breakMin * 60000;
      } else {
        state.phase = "scroll";
        state.phaseEnds = now + state.setMin * 60000;
      }
      save();
    }
    if (state.phase === "scroll") {
      const dt = last ? Math.min(100, t - last) : 16;
      const el = scroller();
      const px = (state.speed * dt) / 1000; // speed = pixels per second
      if (el === document.scrollingElement || el === document.documentElement) window.scrollBy(0, px);
      else el.scrollTop += px;
      const y = el === document.scrollingElement || el === document.documentElement ? scrollY : el.scrollTop;
      // At the bottom and nothing new loading for 8s: jump back up so long sessions keep going.
      if (Math.abs(y - lastY) < 0.5) { stuckFor += dt; if (stuckFor > 8000) { el.scrollTo ? el.scrollTo(0, 0) : window.scrollTo(0, 0); stuckFor = 0; } }
      else stuckFor = 0;
      lastY = y;
    }
    last = t;
    if (Math.floor(now / 1000) !== Math.floor((now - 16) / 1000)) showBadge();
    raf = requestAnimationFrame(tick);
  }

  function save() {
    try { sessionStorage.setItem("signalScroll", JSON.stringify(state)); } catch (_) {}
  }

  function start(opts) {
    stop();
    const setMin = Math.max(1, Math.min(240, Number(opts.minutes) || 30));
    const sets = Math.max(1, Math.min(20, Number(opts.sets) || 1));
    state = {
      setMin, totalSets: sets, setsLeft: sets,
      breakMin: Math.max(0, Math.min(120, Number(opts.breakMin) || 0)),
      speed: Math.max(10, Math.min(2000, Number(opts.speed) || 120)),
      phase: "scroll", phaseEnds: Date.now() + setMin * 60000,
    };
    save(); last = 0; stuckFor = 0; lastY = -1;
    showBadge();
    raf = requestAnimationFrame(tick);
  }

  function stop(reason) {
    cancelAnimationFrame(raf);
    state = null;
    try { sessionStorage.removeItem("signalScroll"); } catch (_) {}
    if (badge) {
      if (reason === "done") { badge.textContent = "Auto-scroll finished ✓"; setTimeout(() => { badge?.remove(); badge = null; }, 4000); }
      else { badge.remove(); badge = null; }
    }
  }

  chrome.runtime.onMessage.addListener((msg, _s, reply) => {
    if (msg.type === "scrollStart") { start(msg.opts || {}); reply({ ok: true }); }
    else if (msg.type === "scrollStop") { stop(); reply({ ok: true }); }
    else if (msg.type === "scrollStatus") { reply({ running: !!state, state }); }
    return false;
  });

  // Keep going after a full page reload in the same tab (for sites that reload while scrolling).
  try {
    const saved = JSON.parse(sessionStorage.getItem("signalScroll") || "null");
    if (saved && saved.phaseEnds > Date.now()) { state = saved; showBadge(); raf = requestAnimationFrame(tick); }
  } catch (_) {}

  // Stop instantly with Esc.
  addEventListener("keydown", (e) => { if (e.key === "Escape" && state) stop(); }, true);
})();
