// Shared lens engine: finds posts on a page, labels them (quick rules first, then Laya), and queues them for the dashboard.
// Each site script calls SignalLens.run({ platform, findItems, extract, anchor }).
(() => {
  const C = window.SignalCommon;

  function run({ platform, findItems, extract, anchor }) {
    const velocities = [];
    const seenIds = new Set();
    let settings = { enabled: true, designOnly: false };

    chrome.storage.local.get(["lensEnabled", "designOnly"], (s) => {
      settings.enabled = s.lensEnabled !== false;
      settings.designOnly = !!s.designOnly;
      scan();
    });
    chrome.storage.onChanged.addListener((ch) => {
      if (!ch.lensEnabled && !ch.designOnly) return;
      if (ch.lensEnabled) settings.enabled = ch.lensEnabled.newValue !== false;
      if (ch.designOnly) settings.designOnly = !!ch.designOnly.newValue;
      document.querySelectorAll("[data-signal-id]").forEach((el) => {
        el.removeAttribute("data-signal-id");
        el.querySelectorAll(":scope .signal-row").forEach((r) => r.remove());
        el.classList.remove("signal-dim");
      });
      scan();
    });

    function insertSorted(v) {
      let lo = 0, hi = velocities.length;
      while (lo < hi) { const mid = (lo + hi) >> 1; if (velocities[mid] < v) lo = mid + 1; else hi = mid; }
      velocities.splice(lo, 0, v);
    }

    function render(el, post, scores) {
      el.querySelectorAll(":scope .signal-row").forEach((r) => r.remove());
      const labels = post.posted_at ? C.labelsFor(post, scores, velocities)
        : C.labelsFor({ ...post, posted_at: new Date(Date.now() - 864e5 * 365).toISOString() }, scores, velocities).filter((l) => l.k !== "trend" && l.k !== "next");
      const isDesign = scores.relevant != null ? scores.relevant >= 0.6 : C.isDesignRelated(post.text, post.handle, post.name);
      el.classList.toggle("signal-dim", settings.designOnly && !isDesign);
      if (!labels.length && !scores.pending) return;
      const row = document.createElement("div");
      row.className = "signal-row";
      for (const l of labels) {
        const b = document.createElement("span");
        b.className = `signal-badge signal-${l.k}`;
        b.textContent = l.t;
        b.title = l.why;
        row.appendChild(b);
      }
      if (scores.pending) {
        const b = document.createElement("span");
        b.className = "signal-badge signal-pending";
        b.textContent = "Laya reading…";
        row.appendChild(b);
      }
      const host = (anchor && anchor(el)) || el.firstElementChild || el;
      host.prepend(row);
    }

    function send(post, laya) {
      chrome.runtime.sendMessage({ type: "collect", post: { ...post, platform, laya: laya || undefined } }, () => void chrome.runtime.lastError);
    }

    function handle(el) {
      let post;
      try { post = extract(el); } catch (_) { post = null; }
      if (!post || !post.post_id) return;
      const key = platform + ":" + post.post_id;
      if (el.getAttribute("data-signal-id") === key) return;
      el.setAttribute("data-signal-id", key);
      if (!seenIds.has(key)) {
        seenIds.add(key);
        if (post.posted_at) insertSorted(C.velocity(post).vel);
      }

      const text = post.text || "";
      const quick = {
        slop: C.heuristicSlop(text),
        specificity: text.length > 20 ? C.heuristicSpecificity(text) : null,
        relevant: null, source: "quick rules", pending: text.length > 20,
      };
      render(el, post, quick);
      if (text.length <= 20) { send(post, null); return; }

      chrome.runtime.sendMessage({ type: "laya", post: { ...post, cache_key: key } }, (res) => {
        if (chrome.runtime.lastError || !res || !res.ok) { render(el, post, { ...quick, pending: false }); send(post, null); return; }
        render(el, post, { ...res.scores, source: "Laya" });
        send(post, res.scores);
      });
    }

    function scan() {
      if (!settings.enabled) return;
      for (const el of findItems()) handle(el);
    }

    let queued = false;
    new MutationObserver(() => {
      if (queued) return;
      queued = true;
      setTimeout(() => { queued = false; scan(); }, 250);
    }).observe(document.body, { childList: true, subtree: true });
    scan();
  }

  window.SignalLens = { run };
})();
