// Background worker: talks to Laya (running on your computer) and sends posts to Supabase.
const DEFAULTS = {
  layaUrl: "http://127.0.0.1:8000",
  layaKey: "",
  supabaseUrl: "https://fkmutmzuwexfyqvanmlg.supabase.co",
  supabaseKey: "",
  workerToken: "",
  syncEnabled: false,
};

const QUESTIONS = {
  relevant: { type: "noul", instructions: "Is `post` by or about a design agency, design studio, freelance designer or personal-brand designer talking about their work, clients or craft?" },
  slop: { type: "noul", instructions: "Does `post` read like generic AI-written filler with no real specifics or personal voice?" },
  specificity: { type: "score", instructions: "How specific and concrete is `post`?", criteria: ["vague and generic", "a little specific", "specific with real details", "very specific with numbers, names or examples"] },
  has_cta: { type: "noul", instructions: "Does `post` ask the reader to act, like DM, book a call, visit a link, comment or follow?" },
  hook: {
    type: "choice", instructions: "How does the first line of `post` grab attention?",
    criteria: {
      number_list: "promises a numbered list", question: "opens with a question", bold_claim: "opens with a bold claim",
      contrarian: "goes against common advice", result_first: "leads with a result or number", story: "opens a personal story",
      before_after: "shows a before and after", how_to: "promises a how-to", announcement: "announces something new", plain: "no clear hook",
    },
  },
};

async function settings() {
  const s = await chrome.storage.local.get(Object.keys(DEFAULTS));
  return { ...DEFAULTS, ...Object.fromEntries(Object.entries(s).filter(([, v]) => v !== undefined && v !== "")) };
}

// ---------- Laya ----------
const cache = new Map();   // tweet_id -> scores (memory); persisted copy in storage
let queue = [];
let running = false;
let layaDown = 0;          // timestamp until which we skip Laya after a failure

async function cachedScores(id) {
  if (cache.has(id)) return cache.get(id);
  const k = "laya:" + id;
  const s = (await chrome.storage.local.get(k))[k];
  if (s) cache.set(id, s);
  return s;
}

async function callLaya(text) {
  const s = await settings();
  const res = await fetch(s.layaUrl.replace(/\/$/, "") + "/v1/systemone", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...(s.layaKey ? { Authorization: "Bearer " + s.layaKey } : {}) },
    body: JSON.stringify({ state: { post: text.slice(0, 3000) }, questions: QUESTIONS }),
  });
  if (!res.ok) throw new Error("Laya answered " + res.status);
  const a = (await res.json()).answers || {};
  return {
    relevant: a.relevant?.noul ?? null,
    slop: a.slop?.noul ?? null,
    specificity: a.specificity?.score ?? null,
    has_cta: a.has_cta?.noul ?? null,
    hook: a.hook?.choice ?? null,
  };
}

async function pump() {
  if (running) return;
  running = true;
  while (queue.length) {
    // newest first: what's on screen now matters most
    const job = queue.pop();
    if (queue.length > 60) queue = queue.slice(-60);
    try {
      const key = job.post.cache_key || (job.post.platform || "x") + ":" + job.post.post_id;
      const hit = await cachedScores(key);
      if (hit) { job.reply({ ok: true, scores: hit }); continue; }
      if (Date.now() < layaDown) { job.reply({ ok: false, error: "laya_offline" }); continue; }
      const scores = await callLaya(job.post.text);
      cache.set(key, scores);
      await chrome.storage.local.set({ ["laya:" + key]: scores, layaStatus: { ok: true, at: Date.now() } });
      job.reply({ ok: true, scores });
    } catch (e) {
      layaDown = Date.now() + 30_000; // retry Laya in 30s
      await chrome.storage.local.set({ layaStatus: { ok: false, at: Date.now(), error: String(e.message || e) } });
      job.reply({ ok: false, error: String(e.message || e) });
    }
  }
  running = false;
}

// ---------- Supabase sync ----------
let outbox = [];
async function flush() {
  const s = await settings();
  if (!s.syncEnabled || !s.supabaseKey || !s.workerToken || !outbox.length) return;
  const batch = outbox.splice(0, 100);
  try {
    const headers = { apikey: s.supabaseKey, "Content-Type": "application/json" };
    if (!s.supabaseKey.startsWith("sb_")) headers.Authorization = "Bearer " + s.supabaseKey;
    const res = await fetch(s.supabaseUrl.replace(/\/$/, "") + "/rest/v1/rpc/extension_ingest", {
      method: "POST", headers, body: JSON.stringify({ p_token: s.workerToken, p_rows: batch }),
    });
    if (!res.ok) throw new Error("Supabase answered " + res.status + " " + (await res.text()).slice(0, 160));
    const st = (await chrome.storage.local.get("stats")).stats || {};
    await chrome.storage.local.set({ syncStatus: { ok: true, at: Date.now() }, stats: { ...st, synced: (st.synced || 0) + batch.length } });
  } catch (e) {
    outbox = batch.concat(outbox).slice(0, 1000);
    await chrome.storage.local.set({ syncStatus: { ok: false, at: Date.now(), error: String(e.message || e) } });
  }
}

chrome.alarms.create("flush", { periodInMinutes: 1 });
chrome.alarms.onAlarm.addListener((a) => { if (a.name === "flush") flush(); });

chrome.runtime.onMessage.addListener((msg, sender, reply) => {
  if (msg.type === "laya") {
    queue.push({ post: msg.post, reply });
    pump();
    return true; // async reply
  }
  if (msg.type === "collect") {
    const p = msg.post;
    if (p && !outbox.find((x) => x.platform === p.platform && x.post_id === p.post_id)) {
      outbox.push(p);
      chrome.storage.local.get("stats").then(({ stats = {} }) =>
        chrome.storage.local.set({ stats: { ...stats, seen: (stats.seen || 0) + 1 } }));
      if (outbox.length >= 40) flush();
    }
    reply({ ok: true });
    return false;
  }
  if (msg.type === "testLaya") {
    callLaya("We rebranded a coffee roaster and sales went up 22% in 3 months. Here's the before and after.")
      .then((s) => reply({ ok: true, scores: s }))
      .catch((e) => reply({ ok: false, error: String(e.message || e) }));
    return true;
  }
  if (msg.type === "flushNow") { flush().then(() => reply({ ok: true })); return true; }
  return false;
});
