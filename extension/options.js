const $ = (id) => document.getElementById(id);
const KEYS = ["layaUrl", "layaKey", "supabaseUrl", "supabaseKey", "workerToken", "syncEnabled"];
const DEFAULTS = { layaUrl: "http://127.0.0.1:8000", supabaseUrl: "https://fkmutmzuwexfyqvanmlg.supabase.co" };

(async () => {
  const s = await chrome.storage.local.get(KEYS);
  for (const k of KEYS) {
    if (k === "syncEnabled") $(k).checked = !!s[k];
    else $(k).value = s[k] ?? DEFAULTS[k] ?? "";
  }
})();

async function save() {
  const v = {};
  for (const k of KEYS) v[k] = k === "syncEnabled" ? $(k).checked : $(k).value.trim();
  if (v.layaUrl && !/^https?:\/\//.test(v.layaUrl)) { $("saveMsg").textContent = "Laya address must start with http://"; return false; }
  await chrome.storage.local.set(v);
  return true;
}

$("save").addEventListener("click", async () => {
  if (!(await save())) return;
  $("saveMsg").textContent = "Saved.";
  if ($("syncEnabled").checked) chrome.runtime.sendMessage({ type: "flushNow" }, () => void chrome.runtime.lastError);
});

$("test").addEventListener("click", async () => {
  if (!(await save())) return;
  $("testMsg").textContent = "Testing…";
  chrome.runtime.sendMessage({ type: "testLaya" }, (res) => {
    if (res?.ok) $("testMsg").textContent = `Laya works. Sample post: slop ${Math.round(res.scores.slop * 100)}%, specificity ${res.scores.specificity?.toFixed(1)}/3.`;
    else $("testMsg").textContent = "Can't reach Laya: " + (res?.error || "no answer") + ". Is laya-serve running?";
  });
});
