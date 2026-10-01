// Contra: label project cards (Discover, search, profiles) and project pages.
// Contra's markup has no stable test ids, so cards are found through their project links.
(() => {
  const C = window.SignalCommon;
  const PROJECT_RE = /^\/p\/([A-Za-z0-9_-]{4,})/;
  const RESERVED = new Set(["p", "discover", "search", "jobs", "login", "signup", "settings", "messages", "inbox", "explore", "about", "pricing", "blog", "help", "hire", "notifications"]);

  const num = (text, re) => { const m = (text || "").match(re); return m ? C.parseCount(m[1]) : 0; };

  // The card is the nearest ancestor that also holds an image and a profile link, but not a second project.
  function cardFor(a) {
    let el = a;
    for (let i = 0; i < 6 && el.parentElement; i++) {
      el = el.parentElement;
      const projects = new Set([...el.querySelectorAll('a[href^="/p/"]')].map((x) => x.getAttribute("href").split("?")[0]));
      if (projects.size > 1) return null;
      if (el.querySelector("img, video") && el.innerText && el.innerText.length > 10) return el;
    }
    return null;
  }

  function findItems() {
    const out = new Set();
    if (PROJECT_RE.test(location.pathname)) {
      const main = document.querySelector("main");
      if (main) out.add(main);
      return [...out];
    }
    for (const a of document.querySelectorAll('a[href^="/p/"]')) {
      const card = cardFor(a);
      if (card) out.add(card);
    }
    return [...out];
  }

  function profileHandle(el) {
    for (const a of el.querySelectorAll('a[href^="/"]')) {
      const h = (a.getAttribute("href") || "").split("?")[0].replace(/\/$/, "");
      const m = h.match(/^\/([A-Za-z0-9_.-]{2,40})$/);
      if (m && !RESERVED.has(m[1].toLowerCase())) return m[1];
    }
    const m = location.pathname.match(/^\/([A-Za-z0-9_.-]{2,40})\/?$/);
    return m && !RESERVED.has(m[1].toLowerCase()) ? m[1] : "";
  }

  window.SignalLens.run({
    platform: "contra",
    findItems,
    anchor: (el) => el,
    extract(el) {
      const onProject = el.tagName === "MAIN" && PROJECT_RE.test(location.pathname);
      const href = onProject ? location.pathname : el.querySelector('a[href^="/p/"]')?.getAttribute("href") || "";
      const m = href.match(PROJECT_RE);
      if (!m) return null;
      const title = el.querySelector("h1, h2, h3")?.innerText?.trim() || "";
      const body = (el.innerText || "").replace(/\n{2,}/g, "\n").trim();
      const text = onProject ? body.slice(0, 2500) : (title && !body.startsWith(title) ? title + "\n" : "") + body.slice(0, 800);
      const likeLabel = [...el.querySelectorAll("[aria-label]")].map((x) => x.getAttribute("aria-label")).find((l) => /like|appreciat|heart/i.test(l)) || "";
      const handle = profileHandle(el);
      const timeEl = el.querySelector("time[datetime]");
      return {
        post_id: m[1],
        handle: handle || "unknown",
        name: handle,
        url: `https://contra.com/p/${m[1]}`,
        text,
        posted_at: timeEl?.getAttribute("datetime") || null,
        likes: C.parseCount(likeLabel) || num(body, /([\d.,]+\s*[KkMm]?)\s+(likes?|appreciations?)\b/i),
        replies: num(body, /([\d.,]+\s*[KkMm]?)\s+comments?\b/i),
        reposts: 0,
        views: num(body, /([\d.,]+\s*[KkMm]?)\s+views?\b/i) || null,
        media_count: el.querySelectorAll("img, video").length,
        format: el.querySelector("video") ? "video" : el.querySelectorAll("img").length > 2 ? "carousel" : "image",
      };
    },
  });
})();
