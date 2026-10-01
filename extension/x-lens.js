// X / Twitter: label posts in the timeline, search, profiles and threads.
(() => {
  const C = window.SignalCommon;
  window.SignalLens.run({
    platform: "x",
    findItems: () => document.querySelectorAll('article[data-testid="tweet"]'),
    anchor: (a) => a.querySelector('[data-testid="User-Name"]')?.closest("div[dir]")?.parentElement,
    extract(article) {
      if (article.querySelector('[data-testid="placementTracking"]')) return null; // ad
      const timeEl = article.querySelector("time[datetime]");
      const link = timeEl?.closest("a[href*='/status/']");
      const m = link?.getAttribute("href")?.match(/^\/([A-Za-z0-9_]{1,30})\/status\/(\d+)/);
      if (!m) return null;
      const aria = (id) => article.querySelector(`[data-testid="${id}"]`)?.getAttribute("aria-label") || "";
      const photos = article.querySelectorAll('[data-testid="tweetPhoto"]').length;
      const video = !!article.querySelector('[data-testid="videoPlayer"], video');
      const text = article.querySelector('[data-testid="tweetText"]')?.innerText || "";
      return {
        post_id: m[2],
        handle: m[1],
        name: article.querySelector('[data-testid="User-Name"]')?.innerText?.split("\n")[0] || "",
        url: `https://x.com/${m[1]}/status/${m[2]}`,
        text,
        posted_at: timeEl.getAttribute("datetime"),
        replies: C.parseCount(aria("reply")),
        reposts: C.parseCount(aria("retweet") || aria("unretweet")),
        likes: C.parseCount(aria("like") || aria("unlike")),
        views: C.parseCount(article.querySelector('a[href$="/analytics"]')?.getAttribute("aria-label") || ""),
        media_count: photos + (video ? 1 : 0),
        format: video ? "video" : photos > 1 ? "carousel" : photos === 1 ? "image" : /🧵|\bthread\b|^\s*1\//i.test(text) ? "thread" : "text",
      };
    },
  });
})();
