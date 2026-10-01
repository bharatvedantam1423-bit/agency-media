const $ = (id) => document.getElementById(id);
const ago = (t) => { const s = (Date.now() - t) / 1000; return s < 90 ? "just now" : s < 3600 ? Math.round(s / 60) + " min ago" : Math.round(s / 3600) + " h ago"; };

async function init() {
  const s = await chrome.storage.local.get(["lensEnabled", "designOnly", "layaStatus", "syncStatus", "syncEnabled", "stats", "scrollOpts"]);
  $("lensEnabled").checked = s.lensEnabled !== false;
  $("designOnly").checked = !!s.designOnly;
  const o = s.scrollOpts || {};
  for (const k of ["minutes", "sets", "breakMin", "speed"]) if (o[k] != null) $(k).value = o[k];

  $("lensEnabled").addEventListener("change", (e) => chrome.storage.local.set({ lensEnabled: e.target.checked }));
  $("designOnly").addEventListener("change", (e) => chrome.storage.local.set({ designOnly: e.target.checked }));

  // Laya status: test live
  chrome.runtime.sendMessage({ type: "testLaya" }, (res) => {
    if (res && res.ok) { $("layaDot").className = "dot ok"; $("layaText").textContent = "Laya is running on this computer"; }
    else { $("layaDot").className = "dot bad"; $("layaText").innerHTML = 'Laya not running. Using quick rules. <a href="options.html" target="_blank">How to start it</a>'; }
  });

  const st = s.stats || {};
  if (!s.syncEnabled) { $("syncText").innerHTML = `Seen ${st.seen || 0} posts. Dashboard sync is off. <a href="options.html" target="_blank">Turn on</a>`; }
  else if (s.syncStatus && !s.syncStatus.ok) { $("syncDot").className = "dot bad"; $("syncText").textContent = "Sync problem: " + s.syncStatus.error; }
  else { $("syncDot").className = "dot ok"; $("syncText").textContent = `${st.synced || 0} posts sent to dashboard${s.syncStatus ? " · " + ago(s.syncStatus.at) : ""}`; }

  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  const send = (msg) => new Promise((r) => chrome.tabs.sendMessage(tab.id, msg, (res) => { void chrome.runtime.lastError; r(res); }));
  const status = await send({ type: "scrollStatus" });
  if (status?.running) $("scrollMsg").textContent = "Auto-scroll is running on this tab.";
  else if (status === undefined) $("scrollMsg").textContent = "Reload this tab once to enable auto-scroll here (Chrome pages like the Web Store can't be scrolled).";

  $("start").addEventListener("click", async () => {
    const opts = { minutes: $("minutes").value, sets: $("sets").value, breakMin: $("breakMin").value, speed: $("speed").value };
    await chrome.storage.local.set({ scrollOpts: opts });
    const r = await send({ type: "scrollStart", opts });
    $("scrollMsg").textContent = r?.ok ? `Scrolling for ${opts.minutes} min × ${opts.sets} set(s).` : "Couldn't start here. Reload the tab and try again.";
    if (r?.ok) setTimeout(() => window.close(), 700);
  });
  $("stop").addEventListener("click", async () => { await send({ type: "scrollStop" }); $("scrollMsg").textContent = "Stopped."; });
}
init();
