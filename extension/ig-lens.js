// Instagram (logged in, in your browser): label posts in the home feed, on post pages and in reels.
// Instagram's class names change constantly, so this reads links, <time> and visible text instead.
(() => {
  const C = window.SignalCommon;
  const count = (el, re) => {
    const m = (el.innerText || "").match(re);
    return m ? C.parseCount(m[1]) : 0;
  };

  function postLink(el) {
    return el.querySelector('a[href*="/p/"], a[href*="/reel/"]');
  }

  window.SignalLens.run({
    platform: "instagram",
    findItems: () => {
      const items = [...document.querySelectorAll("article")];
      // A single post page (/p/… or /reel/…) may not wrap the post in <article>.
      if (!items.length && /^\/(p|reel)\//.test(location.pathname)) {
        const main = document.querySelector("main");
        if (main) items.push(main);
      }
      return items.filter((el) => el.querySelector("time[datetime]"));
    },
    anchor: (el) => el.querySelector("header") || el.firstElementChild,
    extract(el) {
      const link = postLink(el);
      const path = link?.getAttribute("href") || location.pathname;
      const m = path.match(/\/(p|reel)\/([A-Za-z0-9_-]{5,})/);
      if (!m) return null;
      const header = el.querySelector("header") || el;
      const userLink = [...header.querySelectorAll('a[href^="/"]')].find((a) => /^\/[A-Za-z0-9_.]{2,30}\/?$/.test(a.getAttribute("href")));
      const handle = userLink?.getAttribute("href").replaceAll("/", "") || "";
      if (!handle) return null;
      if (/\bSponsored\b/.test(header.innerText || "")) return null;

      // Caption: the longest text block that starts after the author name.
      const spans = [...el.querySelectorAll("h1, span[dir='auto'], div[dir='auto']")]
        .map((s) => s.innerText?.trim() || "")
        .filter((t) => t.length > 15 && !/^\d[\d,.]*\s*(likes?|comments?)$/i.test(t));
      const text = spans.sort((a, b) => b.length - a.length)[0] || "";
      const video = !!el.querySelector("video");
      const multi = !!el.querySelector('button[aria-label*="Next" i], [aria-label*="carousel" i]');
      return {
        post_id: m[2],
        handle,
        name: handle,
        url: `https://www.instagram.com/${m[1]}/${m[2]}/`,
        text,
        posted_at: el.querySelector("time[datetime]")?.getAttribute("datetime"),
        likes: count(el, /([\d.,]+\s*[KkMm]?)\s+likes?\b/) || count(el, /and\s+([\d.,]+\s*[KkMm]?)\s+others/),
        replies: count(el, /View all\s+([\d.,]+\s*[KkMm]?)\s+comments/) || count(el, /([\d.,]+\s*[KkMm]?)\s+comments?\b/),
        reposts: 0,
        views: count(el, /([\d.,]+\s*[KkMm]?)\s+(views|plays)\b/) || null,
        media_count: multi ? 2 : 1,
        format: m[1] === "reel" ? "reel" : video ? "video" : multi ? "carousel" : "image",
      };
    },
  });
})();
