// Shared scoring helpers (used by x-lens.js; pure functions so they can be tested).
(() => {
  const DESIGN_WORDS = /\b(design|designer|designs|branding|brand identity|rebrand|logo|logos|typograph\w*|ui|ux|figma|framer|webflow|landing page|website|studio|agency|agencies|creative director|art direction|portfolio|case study|clients?|freelanc\w*|personal brand|visual identity|packaging|motion design|illustrat\w*)\b/i;

  const SLOP_PHRASES = [
    /here'?s the thing/i, /let that sink in/i, /game[- ]?changer/i, /in today'?s (fast[- ]paced|digital|world)/i,
    /\bunlock(ing)? (your|the)\b/i, /\belevate (your|the)\b/i, /\bdelve\b/i, /\bnavigat(e|ing) the (world|landscape)\b/i,
    /\bit'?s not (just )?about .{1,40}, it'?s about\b/i, /\bthe secret (to|sauce)\b/i, /\bbuckle up\b/i,
    /\bin (a|this) world where\b/i, /\bembrace (the|your)\b/i, /\btapestry\b/i, /\blandscape\b/i,
    /\bstop scrolling\b/i, /\bnobody (is )?talk(s|ing) about\b/i, /\bhere'?s (why|how)\b.*\n.*\n.*\n/i,
  ];

  function parseCount(label) {
    if (!label) return 0;
    const m = String(label).replace(/,/g, "").match(/([\d.]+)\s*([KkMm])?/);
    if (!m) return 0;
    let n = parseFloat(m[1]);
    if (m[2]) n *= /k/i.test(m[2]) ? 1e3 : 1e6;
    return Math.round(n);
  }

  function heuristicSlop(text) {
    const t = text || "";
    let hits = SLOP_PHRASES.filter((re) => re.test(t)).length;
    const emojis = (t.match(/[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]/gu) || []).length;
    const dashes = (t.match(/—/g) || []).length;
    const tags = (t.match(/#\w+/g) || []).length;
    const lines = t.split("\n").filter((l) => l.trim());
    const staccato = lines.length >= 6 && lines.filter((l) => l.trim().split(/\s+/).length <= 6).length / lines.length > 0.7;
    if (emojis >= 4) hits++;
    if (dashes >= 3) hits++;
    if (tags >= 4) hits++;
    if (staccato) hits++;
    return Math.min(1, hits * 0.25);
  }

  function heuristicSpecificity(text) {
    const t = text || "";
    let s = 0;
    if (/\d/.test(t)) s += 0.8;
    if (/[$₹€£]\s?\d|\d+\s?(%|k\b|x\b)/i.test(t)) s += 0.7;
    if (/@\w+/.test(t)) s += 0.3;
    if (/\b(we|i) (built|designed|shipped|launched|made|redesigned|helped)\b/i.test(t)) s += 0.6;
    if (t.split(/\s+/).length > 25) s += 0.4;
    return Math.min(3, s);
  }

  function isDesignRelated(text, handle, name) {
    return DESIGN_WORDS.test(`${text || ""} ${name || ""}`);
  }

  // Engagement per hour, and the labels shown on screen.
  function velocity(p, now = Date.now()) {
    const eng = (p.likes || 0) + 2 * (p.reposts || 0) + 3 * (p.replies || 0);
    const ageH = Math.max(0.25, (now - new Date(p.posted_at).getTime()) / 3.6e6);
    return { eng, ageH, vel: eng / ageH, viewsPerH: (p.views || 0) / ageH };
  }

  function percentileRank(sorted, v) {
    if (!sorted.length) return 0;
    let lo = 0, hi = sorted.length;
    while (lo < hi) { const mid = (lo + hi) >> 1; if (sorted[mid] < v) lo = mid + 1; else hi = mid; }
    return lo / sorted.length;
  }

  function labelsFor(p, s, sortedVel) {
    // p: post; s: scores {slop, specificity, relevant, source}; sortedVel: velocities seen this session
    const { eng, ageH, vel, viewsPerH } = velocity(p);
    const pct = percentileRank(sortedVel, vel);
    const enough = sortedVel.length >= 20; // session comparisons only once we've seen enough posts
    const rel = enough ? `, top ${Math.max(1, Math.round((1 - pct) * 100))}% of the ${sortedVel.length} posts you've seen` : "";
    const out = [];
    if (vel >= 1000 || viewsPerH >= 50000 || (enough && pct >= 0.9 && eng >= 500)) {
      out.push({ k: "trend", t: "🔥 Trending", why: `${fmt(eng)} engagement in ${fmtAge(ageH)} (${fmt(vel)}/hour${rel})` });
    } else if (ageH <= 6 && eng >= 20 && (vel >= 150 || (enough && pct >= 0.75))) {
      out.push({ k: "next", t: "🚀 Next trend", why: `Only ${fmtAge(ageH)} old and already at ${fmt(vel)} engagement/hour${rel}` });
    }
    if (s.slop != null && s.slop >= 0.6) {
      out.push({ k: "slop", t: "🤖 AI slop", why: `Reads like generic AI filler (${Math.round(s.slop * 100)}% by ${s.source})` });
    } else if (s.specificity != null) {
      if (s.specificity >= 1.8) out.push({ k: "good", t: "✅ Good post", why: `Specific and concrete (${s.specificity.toFixed(1)}/3 by ${s.source})` });
      else if (s.specificity <= (s.source === "Laya" ? 0.8 : 0.5)) out.push({ k: "weak", t: "⚠️ Weak", why: `Vague, few specifics (${s.specificity.toFixed(1)}/3 by ${s.source})` });
    }
    if (s.relevant != null && s.relevant >= 0.6) out.push({ k: "design", t: "🎨 Design/agency", why: `Relevant to design agencies & personal-brand designers (${Math.round(s.relevant * 100)}%)` });
    return out;
  }

  function fmt(n) { n = Math.round(n); return n >= 1e6 ? (n / 1e6).toFixed(1) + "M" : n >= 1e4 ? (n / 1e3).toFixed(0) + "k" : n >= 1e3 ? (n / 1e3).toFixed(1) + "k" : String(n); }
  function fmtAge(h) { return h < 1 ? Math.round(h * 60) + " min" : h < 48 ? Math.round(h) + " h" : Math.round(h / 24) + " days"; }

  const api = { parseCount, heuristicSlop, heuristicSpecificity, isDesignRelated, velocity, percentileRank, labelsFor, fmt };
  if (typeof window !== "undefined") window.SignalCommon = api;
  if (typeof module !== "undefined") module.exports = api;
})();
