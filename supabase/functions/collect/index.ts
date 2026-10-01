// Social Signal collector — runs inside Supabase on a schedule.
// Fetches recent posts from watched accounts and hashtags, then hands them to the
// `ingest` database function, which stores posts, tracks growth and finds new accounts.
import { createClient } from "jsr:@supabase/supabase-js@2";

const sb = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
);

const UA =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36";
const BUDGET_MS = 110_000;

type Post = {
  id: string; platform: string; handle: string; url?: string; text?: string;
  posted_at?: string; format?: string; media_count?: number;
  likes?: number; reposts?: number; replies?: number; views?: number | null; saves?: number | null;
  lang?: string | null; via?: string;
};
type Candidate = {
  platform: string; handle: string; display_name?: string; bio?: string;
  followers?: number; discovered_from?: string;
};
type Result = {
  account: Record<string, unknown> | null;
  posts: Post[];
  candidates: Candidate[];
};

async function get(url: string, headers: Record<string, string> = {}, timeoutMs = 20_000) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const res = await fetch(url, {
      headers: { "User-Agent": UA, "Accept-Language": "en-US,en;q=0.9", ...headers },
      signal: ctrl.signal,
      redirect: "follow",
    });
    return { status: res.status, body: await res.text() };
  } finally {
    clearTimeout(timer);
  }
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const iso = (d: string | number | Date) => {
  const t = new Date(d);
  return isNaN(t.getTime()) ? undefined : t.toISOString();
};
const stripHtml = (h: string) =>
  (h || "")
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/p>\s*<p>/gi, "\n\n")
    .replace(/<[^>]+>/g, "")
    .replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&nbsp;/g, " ")
    .trim();
const decodeXml = (s: string) =>
  (s || "").replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'").trim();
const mentionsIn = (text: string, re: RegExp) =>
  [...new Set([...(text || "").matchAll(re)].map((m) => m[1]))];

// ---------------- X (public embed timeline) ----------------
async function collectX(handle: string): Promise<Result> {
  const { status, body } = await get(
    `https://syndication.twitter.com/srv/timeline-profile/screen-name/${encodeURIComponent(handle)}`,
  );
  if (status !== 200) throw new Error(`X answered ${status}`);
  const m = body.match(/<script id="__NEXT_DATA__" type="application\/json">([\s\S]*?)<\/script>/);
  if (!m) throw new Error("X page had no data block");
  const data = JSON.parse(m[1]);
  // deno-lint-ignore no-explicit-any
  const entries: any[] = data?.props?.pageProps?.timeline?.entries ?? [];
  // deno-lint-ignore no-explicit-any
  const tweets: any[] = entries.filter((e) => e?.type === "tweet").map((e) => e.content?.tweet).filter(Boolean);
  if (!tweets.length) throw new Error("No public posts (wrong handle, private or suspended)");

  const lower = handle.toLowerCase();
  const own = tweets.filter((t) => (t.user?.screen_name || "").toLowerCase() === lower);
  const user = own[0]?.user ?? tweets[0]?.user ?? {};
  const posts: Post[] = [];
  const cands = new Map<string, Candidate>();

  for (const t of own) {
    const text: string = t.full_text ?? t.text ?? "";
    if (t.retweeted_status || text.startsWith("RT @")) continue;
    if (t.in_reply_to_status_id_str && (t.in_reply_to_screen_name || "").toLowerCase() !== lower) continue;
    const media = t.extended_entities?.media ?? t.entities?.media ?? [];
    // deno-lint-ignore no-explicit-any
    let format = media.some((v: any) => v.type === "video" || v.type === "animated_gif")
      ? "video"
      : media.length > 1 ? "carousel" : media.length === 1 ? "image" : (t.entities?.urls?.length ? "link" : "text");
    if (/🧵|\bthread\b|^\s*1\/|\(1\/\d+\)/i.test(text)) format = "thread";
    const clean = text.replace(/\s*https:\/\/t\.co\/\w+\s*$/, "").trim();
    posts.push({
      id: `x:${t.id_str}`,
      platform: "x",
      handle,
      url: t.permalink ? `https://x.com${t.permalink}` : `https://x.com/${handle}/status/${t.id_str}`,
      text: clean,
      posted_at: iso(t.created_at),
      format,
      media_count: media.length,
      likes: t.favorite_count ?? 0,
      reposts: (t.retweet_count ?? 0) + (t.quote_count ?? 0),
      replies: t.reply_count ?? 0,
      lang: t.lang ?? null,
    });
    for (const um of t.entities?.user_mentions ?? []) {
      const sn = um.screen_name;
      if (sn && sn.toLowerCase() !== lower) cands.set(sn.toLowerCase(), { platform: "x", handle: sn, display_name: um.name, discovered_from: `x:@${handle}` });
    }
    const q = t.quoted_status?.user;
    if (q?.screen_name && q.screen_name.toLowerCase() !== lower) {
      cands.set(q.screen_name.toLowerCase(), {
        platform: "x", handle: q.screen_name, display_name: q.name, bio: q.description,
        followers: q.followers_count, discovered_from: `x:@${handle}`,
      });
    }
  }
  // Retweeted/other authors that appear in the timeline
  for (const t of tweets) {
    const u = t.user;
    if (u?.screen_name && u.screen_name.toLowerCase() !== lower) {
      cands.set(u.screen_name.toLowerCase(), {
        platform: "x", handle: u.screen_name, display_name: u.name, bio: u.description,
        followers: u.followers_count, discovered_from: `x:@${handle}`,
      });
    }
  }

  return {
    account: {
      platform: "x", handle, ok: true,
      display_name: user.name, bio: user.description, followers: user.followers_count,
      url: `https://x.com/${handle}`,
    },
    posts,
    candidates: [...cands.values()].slice(0, 15),
  };
}

// ---------------- Instagram (public profile JSON) ----------------
async function collectInstagram(handle: string): Promise<Result> {
  const { status, body } = await get(
    `https://www.instagram.com/api/v1/users/web_profile_info/?username=${encodeURIComponent(handle)}`,
    { "x-ig-app-id": "936619743392459", Accept: "*/*" },
  );
  if (status === 404) throw new Error("Instagram account not found");
  if (status !== 200) throw new Error(`Instagram answered ${status}`);
  // deno-lint-ignore no-explicit-any
  let u: any;
  try { u = JSON.parse(body)?.data?.user; } catch { throw new Error("Instagram returned an unexpected page"); }
  if (!u) throw new Error("Instagram account not found");
  if (u.is_private) throw new Error("Instagram account is private");

  const posts: Post[] = [];
  const cands = new Map<string, Candidate>();
  for (const e of u.edge_owner_to_timeline_media?.edges ?? []) {
    const n = e.node;
    const text: string = n.edge_media_to_caption?.edges?.[0]?.node?.text ?? "";
    const format = n.__typename === "GraphVideo"
      ? (n.product_type === "clips" ? "reel" : "video")
      : n.__typename === "GraphSidecar" ? "carousel" : "image";
    posts.push({
      id: `ig:${n.shortcode}`,
      platform: "instagram",
      handle,
      url: `https://www.instagram.com/p/${n.shortcode}/`,
      text,
      posted_at: iso((n.taken_at_timestamp ?? 0) * 1000),
      format,
      media_count: n.edge_sidecar_to_children?.edges?.length ?? 1,
      likes: n.edge_liked_by?.count ?? n.edge_media_preview_like?.count ?? 0,
      replies: n.edge_media_to_comment?.count ?? 0,
      views: n.video_view_count ?? null,
    });
    for (const h of mentionsIn(text, /@([A-Za-z0-9_.]{3,30})/g)) {
      const clean = h.replace(/\.$/, "");
      if (clean.toLowerCase() !== handle.toLowerCase()) cands.set(clean.toLowerCase(), { platform: "instagram", handle: clean, discovered_from: `instagram:@${handle}` });
    }
  }
  for (const e of u.edge_related_profiles?.edges ?? []) {
    const n = e.node;
    if (n?.username) cands.set(n.username.toLowerCase(), { platform: "instagram", handle: n.username, display_name: n.full_name, discovered_from: `instagram:@${handle}` });
  }
  const bio = [u.category_name, u.biography].filter(Boolean).join(" — ");
  return {
    account: {
      platform: "instagram", handle, ok: true,
      display_name: u.full_name, bio, followers: u.edge_followed_by?.count,
      url: `https://www.instagram.com/${handle}/`,
    },
    posts,
    candidates: [...cands.values()].slice(0, 15),
  };
}

// ---------------- Bluesky (open API) ----------------
const BSKY = "https://public.api.bsky.app/xrpc";
async function collectBluesky(handle: string): Promise<Result> {
  const prof = await get(`${BSKY}/app.bsky.actor.getProfile?actor=${encodeURIComponent(handle)}`);
  if (prof.status !== 200) throw new Error(`Bluesky profile answered ${prof.status}`);
  const p = JSON.parse(prof.body);
  const feed = await get(`${BSKY}/app.bsky.feed.getAuthorFeed?actor=${encodeURIComponent(handle)}&limit=60&filter=posts_no_replies`);
  if (feed.status !== 200) throw new Error(`Bluesky feed answered ${feed.status}`);
  const items = JSON.parse(feed.body).feed ?? [];
  const posts: Post[] = [];
  for (const it of items) {
    if (it.reason) continue; // a repost
    const post = it.post;
    if (!post || post.author?.did !== p.did) continue;
    const rkey = String(post.uri).split("/").pop();
    const et: string = post.embed?.$type ?? "";
    const media = post.embed?.media ?? post.embed;
    const imgs = media?.images?.length ?? 0;
    const format = et.includes("video") || media?.$type?.includes("video")
      ? "video" : imgs > 1 ? "carousel" : imgs === 1 ? "image" : et.includes("external") ? "link" : "text";
    posts.push({
      id: `bsky:${p.did}:${rkey}`,
      platform: "bluesky",
      handle,
      url: `https://bsky.app/profile/${p.handle}/post/${rkey}`,
      text: post.record?.text ?? "",
      posted_at: iso(post.record?.createdAt ?? post.indexedAt),
      format,
      media_count: imgs,
      likes: post.likeCount ?? 0,
      reposts: (post.repostCount ?? 0) + (post.quoteCount ?? 0),
      replies: post.replyCount ?? 0,
      lang: post.record?.langs?.[0] ?? null,
    });
  }
  const cands: Candidate[] = [];
  const sug = await get(`${BSKY}/app.bsky.graph.getSuggestedFollowsByActor?actor=${encodeURIComponent(handle)}`);
  if (sug.status === 200) {
    for (const s of (JSON.parse(sug.body).suggestions ?? []).slice(0, 12)) {
      cands.push({ platform: "bluesky", handle: s.handle, display_name: s.displayName, bio: s.description, followers: s.followersCount, discovered_from: `bluesky:@${handle}` });
    }
  }
  return {
    account: {
      platform: "bluesky", handle, ok: true, display_name: p.displayName, bio: p.description,
      followers: p.followersCount, url: `https://bsky.app/profile/${p.handle}`,
    },
    posts,
    candidates: cands,
  };
}

// ---------------- Mastodon (open API) ----------------
// deno-lint-ignore no-explicit-any
function mastoPost(s: any, handle: string, via: string): Post {
  const media = s.media_attachments ?? [];
  // deno-lint-ignore no-explicit-any
  const format = media.some((m: any) => m.type === "video" || m.type === "gifv")
    ? "video" : media.length > 1 ? "carousel" : media.length === 1 ? "image" : s.card ? "link" : "text";
  const host = new URL(s.uri ?? s.url).host;
  return {
    id: `masto:${host}:${String(s.uri ?? s.id).split("/").pop()}`,
    platform: "mastodon",
    handle,
    url: s.url ?? s.uri,
    text: stripHtml(s.content),
    posted_at: iso(s.created_at),
    format,
    media_count: media.length,
    likes: s.favourites_count ?? 0,
    reposts: s.reblogs_count ?? 0,
    replies: s.replies_count ?? 0,
    lang: s.language ?? null,
    via,
  };
}
const fullAcct = (acct: string, home: string) => (acct.includes("@") ? acct : `${acct}@${home}`);

async function collectMastodon(handle: string): Promise<Result> {
  const [user, inst] = handle.replace(/^@/, "").split("@");
  if (!user || !inst) throw new Error("Mastodon handles look like name@server");
  // Ask the account's own server first; some handles live on a different domain than their server,
  // so fall back to mastodon.social's federated copy.
  let server = inst;
  let look = await get(`https://${inst}/api/v1/accounts/lookup?acct=${encodeURIComponent(user)}`).catch(() => ({ status: 0, body: "" }));
  if (look.status !== 200) {
    server = "mastodon.social";
    look = await get(`https://${server}/api/v1/accounts/lookup?acct=${encodeURIComponent(`${user}@${inst}`)}`);
  }
  if (look.status !== 200) throw new Error(`Mastodon lookup answered ${look.status}`);
  const a = JSON.parse(look.body);
  const st = await get(`https://${server}/api/v1/accounts/${a.id}/statuses?exclude_replies=true&exclude_reblogs=true&limit=40`);
  if (st.status !== 200) throw new Error(`Mastodon statuses answered ${st.status}`);
  // deno-lint-ignore no-explicit-any
  const posts = (JSON.parse(st.body) as any[]).map((s) => mastoPost(s, handle, "timeline"));
  return {
    account: {
      platform: "mastodon", handle, ok: true, display_name: a.display_name,
      bio: stripHtml(a.note), followers: a.followers_count, url: a.url,
    },
    posts,
    candidates: [],
  };
}

async function collectMastodonTag(tag: string): Promise<Result> {
  const home = "mastodon.social";
  const r = await get(`https://${home}/api/v1/timelines/tag/${encodeURIComponent(tag)}?limit=40`);
  if (r.status !== 200) throw new Error(`Mastodon tag answered ${r.status}`);
  // deno-lint-ignore no-explicit-any
  const statuses: any[] = JSON.parse(r.body);
  const posts: Post[] = [];
  const cands = new Map<string, Candidate>();
  for (const s of statuses) {
    if (s.reblog || s.in_reply_to_id) continue;
    const h = fullAcct(s.account.acct, home);
    cands.set(h.toLowerCase(), {
      platform: "mastodon", handle: h, display_name: s.account.display_name,
      bio: stripHtml(s.account.note), followers: s.account.followers_count, discovered_from: `mastodon:#${tag}`,
    });
    posts.push(mastoPost(s, h, "hashtag"));
  }
  return { account: null, posts, candidates: [...cands.values()] };
}

// ---------------- YouTube (channel RSS) ----------------
async function collectYouTube(handle: string, storedUrl?: string): Promise<Result> {
  let channelId = storedUrl?.match(/channel_id=(UC[\w-]{22})/)?.[1] ?? (handle.startsWith("UC") ? handle : undefined);
  let bio: string | undefined;
  if (!channelId) {
    const page = await get(`https://www.youtube.com/${handle.startsWith("@") ? handle : "@" + handle}`, { Cookie: "CONSENT=YES+1" });
    if (page.status !== 200) throw new Error(`YouTube channel page answered ${page.status}`);
    channelId = page.body.match(/<link rel="canonical" href="https:\/\/www\.youtube\.com\/channel\/(UC[\w-]{22})"/)?.[1]
      ?? page.body.match(/"(?:externalId|channelId)":"(UC[\w-]{22})"/)?.[1];
    bio = decodeXml(page.body.match(/<meta name="description" content="([^"]*)"/)?.[1] ?? "") || undefined;
    if (!channelId) throw new Error("Couldn't find the YouTube channel id");
  }
  const feedUrl = `https://www.youtube.com/feeds/videos.xml?channel_id=${channelId}`;
  const rss = await get(feedUrl);
  if (rss.status !== 200) throw new Error(`YouTube feed answered ${rss.status}`);
  const x = rss.body;
  const author = decodeXml(x.match(/<author>\s*<name>([^<]*)<\/name>/)?.[1] ?? "");
  const posts: Post[] = [];
  for (const block of x.split("<entry>").slice(1)) {
    const vid = block.match(/<yt:videoId>([^<]+)</)?.[1];
    if (!vid) continue;
    const title = decodeXml(block.match(/<title>([^<]*)<\/title>/)?.[1] ?? "");
    const link = block.match(/<link rel="alternate" href="([^"]+)"/)?.[1] ?? `https://www.youtube.com/watch?v=${vid}`;
    const desc = decodeXml(block.match(/<media:description>([\s\S]*?)<\/media:description>/)?.[1] ?? "");
    const views = Number(block.match(/<media:statistics views="(\d+)"/)?.[1] ?? 0);
    const likes = Number(block.match(/<media:starRating count="(\d+)"/)?.[1] ?? 0);
    posts.push({
      id: `yt:${vid}`,
      platform: "youtube",
      handle,
      url: link,
      text: `${title}\n\n${desc.slice(0, 600)}`,
      posted_at: iso(block.match(/<published>([^<]+)</)?.[1] ?? ""),
      format: link.includes("/shorts/") ? "short" : "video",
      media_count: 1,
      likes,
      views,
    });
  }
  return {
    account: { platform: "youtube", handle, ok: true, display_name: author, bio, url: feedUrl },
    posts,
    candidates: [],
  };
}

// ---------------- Runner ----------------
async function ingest(r: Result) {
  const { data, error } = await sb.rpc("ingest", { p: r });
  if (error) throw new Error(`ingest failed: ${error.message}`);
  return data;
}

Deno.serve(async (req) => {
  const { data: ok } = await sb.rpc("check_collect_secret", { p_secret: req.headers.get("x-collect-secret") ?? "" });
  if (ok !== true) return new Response("Not allowed", { status: 401 });

  const started = Date.now();
  const url = new URL(req.url);
  const nAcc = Math.min(Number(url.searchParams.get("accounts") ?? 10), 30);
  const nSrc = Math.min(Number(url.searchParams.get("sources") ?? 2), 10);

  const { data: run } = await sb.from("runs").insert({ job: "collect" }).select("id").single();
  const stats = { accounts_ok: 0, accounts_failed: 0, posts: 0, candidates: 0, sources: 0, errors: [] as string[] };

  const { data: jobs, error: jobErr } = await sb.rpc("next_jobs", { p_accounts: nAcc, p_sources: nSrc });
  if (jobErr) {
    await sb.from("runs").update({ finished_at: new Date().toISOString(), ok: false, error: jobErr.message }).eq("id", run?.id);
    return new Response(JSON.stringify({ error: jobErr.message }), { status: 500 });
  }

  const lastHit: Record<string, number> = {};
  for (const a of jobs.accounts ?? []) {
    if (Date.now() - started > BUDGET_MS) break;
    const gap = Date.now() - (lastHit[a.platform] ?? 0);
    if (gap < 1500) await sleep(1500 - gap); // be gentle with each platform
    lastHit[a.platform] = Date.now();
    try {
      let res: Result;
      switch (a.platform) {
        case "x": res = await collectX(a.handle); break;
        case "instagram": res = await collectInstagram(a.handle); break;
        case "bluesky": res = await collectBluesky(a.handle); break;
        case "mastodon": res = await collectMastodon(a.handle); break;
        case "youtube": res = await collectYouTube(a.handle, a.url); break;
        default: throw new Error(`No collector for ${a.platform} yet`);
      }
      const out = await ingest(res);
      stats.accounts_ok++;
      stats.posts += out?.posts ?? 0;
      stats.candidates += out?.candidates ?? 0;
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      // Rate limits, server errors and timeouts say nothing about the account: retry later.
      const transient = /answered (429|5\d\d)|abort|timed? ?out|network|connection/i.test(msg);
      stats.accounts_failed++;
      stats.errors.push(`${a.platform}:${a.handle} — ${msg}`.slice(0, 200));
      await ingest({ account: { platform: a.platform, handle: a.handle, ok: false, transient, error: msg }, posts: [], candidates: [] }).catch(() => {});
    }
  }

  for (const s of jobs.sources ?? []) {
    if (Date.now() - started > BUDGET_MS) break;
    try {
      if (s.platform === "mastodon" && s.kind === "hashtag") {
        const out = await ingest(await collectMastodonTag(s.value));
        stats.posts += out?.posts ?? 0;
        stats.candidates += out?.candidates ?? 0;
      }
      stats.sources++;
    } catch (e) {
      stats.errors.push(`source ${s.platform}#${s.value} — ${e instanceof Error ? e.message : e}`.slice(0, 200));
    }
    await sb.rpc("mark_source_done", { p_id: s.id });
  }

  await sb.from("runs").update({
    finished_at: new Date().toISOString(),
    ok: stats.accounts_failed === 0 || stats.accounts_ok > 0,
    stats,
  }).eq("id", run?.id);

  return new Response(JSON.stringify(stats), { headers: { "Content-Type": "application/json" } });
});
