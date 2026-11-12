<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Agent Status</title>
<style>
/* Terraform templatefile: never write a dollar sign followed by an open brace in this file. */
:root {
  --bg: #f4f6f8; --surface: #ffffff; --fg: #18202b; --muted: #5d6878; --line: #dfe3e9;
  --accent: #2f5bd3;
  --run: #2f5bd3; --run-soft: #e3ebfc;
  --ok: #1d7a4c; --ok-soft: #dcf1e5;
  --warn: #9a5a00; --warn-soft: #fbecd0;
  --bad: #b3261e; --bad-soft: #fbe2df;
  --idle: #6b7484; --idle-soft: #eceff3;
  --mono: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  --sans: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
  color-scheme: light;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #0e1218; --surface: #161c25; --fg: #e5e9f0; --muted: #98a2b3; --line: #273041;
    --accent: #7ea2ff;
    --run: #7ea2ff; --run-soft: #1b2744;
    --ok: #5ccf95; --ok-soft: #14301f;
    --warn: #f1b45a; --warn-soft: #33270f;
    --bad: #ff8a80; --bad-soft: #3a1a18;
    --idle: #98a2b3; --idle-soft: #222a36;
    color-scheme: dark;
  }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--fg); font: 15px/1.5 var(--sans); }
.wrap { max-width: 960px; margin: 0 auto; padding: 28px max(16px, env(safe-area-inset-right)) 60px max(16px, env(safe-area-inset-left)); display: grid; gap: 20px; }
header { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 12px; }
h1 { margin: 0; font-size: 1.4rem; }
.sub { color: var(--muted); font-size: 0.85rem; font-family: var(--mono); }
button { font: inherit; border: 1px solid var(--line); background: var(--surface); color: var(--fg); padding: 6px 14px; border-radius: 6px; cursor: pointer; }
button.primary { background: var(--accent); border-color: var(--accent); color: var(--surface); }
button:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
.actions { display: flex; gap: 8px; }
button[aria-pressed="true"] { background: var(--run-soft); border-color: var(--run); color: var(--run); }
.card { background: var(--surface); border: 1px solid var(--line); border-radius: 10px; padding: 18px 20px; display: grid; gap: 16px; min-width: 0; }
.card-head { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; justify-content: space-between; }
.agent { font-family: var(--mono); font-weight: 600; font-size: 1rem; }
.pill { font: 600 0.72rem var(--mono); letter-spacing: 0.04em; text-transform: uppercase; padding: 3px 10px; border-radius: 999px; white-space: nowrap; }
.s-running { background: var(--run-soft); color: var(--run); }
.s-sent { background: var(--ok-soft); color: var(--ok); }
.s-empty, .s-idle { background: var(--idle-soft); color: var(--idle); }
.s-failed, .s-timed_out, .s-unknown { background: var(--bad-soft); color: var(--bad); }
.s-limit { background: var(--warn-soft); color: var(--warn); }
.pulse::before { content: ""; display: inline-block; width: 7px; height: 7px; border-radius: 50%; background: currentColor; margin-right: 6px; vertical-align: 1px; animation: pulse 1.2s ease-in-out infinite; }
@keyframes pulse { 50% { opacity: 0.25; } }
.steps { display: grid; grid-template-columns: repeat(4, 1fr); gap: 8px; list-style: none; margin: 0; padding: 0; }
.step { border-top: 4px solid var(--line); padding-top: 8px; font-size: 0.85rem; color: var(--muted); }
.step.done { border-color: var(--ok); color: var(--fg); }
.step.active { border-color: var(--run); color: var(--run); font-weight: 600; animation: pulse 1.2s ease-in-out infinite; }
.step.failed { border-color: var(--bad); color: var(--bad); font-weight: 600; }
.step.skipped { border-style: dashed; }
.metrics { display: grid; grid-template-columns: repeat(auto-fit, minmax(130px, 1fr)); gap: 12px; margin: 0; }
.metrics div { display: grid; gap: 2px; }
.metrics dt { font-size: 0.72rem; text-transform: uppercase; letter-spacing: 0.06em; color: var(--muted); }
.metrics dd { margin: 0; font: 600 1.05rem var(--mono); font-variant-numeric: tabular-nums; }
.error { background: var(--bad-soft); color: var(--bad); border-radius: 6px; padding: 8px 12px; font-family: var(--mono); font-size: 0.85rem; overflow-wrap: anywhere; }
.history { overflow-x: auto; }
table { border-collapse: collapse; width: 100%; font-size: 0.85rem; font-variant-numeric: tabular-nums; }
th, td { text-align: left; padding: 6px 10px; border-bottom: 1px solid var(--line); white-space: nowrap; }
th { font-size: 0.7rem; text-transform: uppercase; letter-spacing: 0.06em; color: var(--muted); font-weight: 600; }
td.num, th.num { text-align: right; font-family: var(--mono); }
.empty-note { color: var(--muted); }
.signin { text-align: center; padding: 48px 20px; }
@media (max-width: 520px) { .steps { grid-template-columns: repeat(2, 1fr); } }
@media (prefers-reduced-motion: reduce) { .pulse::before, .step.active { animation: none; } }
</style>
</head>
<body>
<div class="wrap">
  <header>
    <div>
      <h1>Agent Status</h1>
      <div class="sub" id="updated">Loading…</div>
    </div>
    <div class="actions">
      <button id="watch" type="button" aria-pressed="false" hidden>Watch now</button>
      <button id="signout" type="button" hidden>Sign out</button>
    </div>
  </header>
  <main id="main"></main>
</div>
<script>
var CONFIG = { api: "${api_url}", auth: "https://${cognito_domain}", clientId: "${client_id}" };
var REDIRECT = location.origin + "/";
var IDLE_MS = 30000, RUNNING_MS = 2000;
var STEPS = [["started", "Started"], ["feeds_fetched", "Feeds fetched"], ["writing", "Claude writing"], ["published", "Email sent"]];
var STATUS_LABEL = { running: "Running", sent: "Sent", empty: "No news", failed: "Failed", timed_out: "Timed out", idle: "Idle", unknown: "Unknown" };
var WATCH = { tz: "${watch_timezone}", start: "${watch_start}", end: "${watch_end}" };
var WATCH_NOW_MS = 120000;
var watchUntil = 0;
var timer = null;

// True during the scheduled run's window, in the schedule's time zone.
// "HH:MM" strings compare correctly as text.
function inWatchWindow() {
  var now = new Intl.DateTimeFormat("en-GB", { timeZone: WATCH.tz, hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).format(new Date());
  return now >= WATCH.start && now <= WATCH.end;
}

// Watch now: check every 2 s for the next 2 minutes, e.g. while you start a manual run.
function watchNow() {
  watchUntil = Date.now() + WATCH_NOW_MS;
  poll();
}

// ---------- storage (session only; tokens are gone when the tab closes) ----------
function load(k) { try { return JSON.parse(sessionStorage.getItem(k)); } catch (e) { return null; } }
function save(k, v) { try { sessionStorage.setItem(k, JSON.stringify(v)); } catch (e) {} }
function drop(k) { try { sessionStorage.removeItem(k); } catch (e) {} }

// ---------- Cognito hosted login: authorization code + PKCE ----------
function b64url(buf) {
  return btoa(String.fromCharCode.apply(null, new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
async function signIn() {
  var verifier = b64url(crypto.getRandomValues(new Uint8Array(32)));
  var state = b64url(crypto.getRandomValues(new Uint8Array(16)));
  var challenge = b64url(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier)));
  save("pkce", { verifier: verifier, state: state });
  location.assign(CONFIG.auth + "/oauth2/authorize?" + new URLSearchParams({
    response_type: "code", client_id: CONFIG.clientId, redirect_uri: REDIRECT,
    scope: "openid email", code_challenge_method: "S256", code_challenge: challenge, state: state
  }));
}
async function tokenRequest(params) {
  var r = await fetch(CONFIG.auth + "/oauth2/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(params)
  });
  if (!r.ok) throw new Error("Token request failed (" + r.status + ")");
  var t = await r.json();
  var old = load("session") || {};
  save("session", { access: t.access_token, refresh: t.refresh_token || old.refresh, expires: Date.now() + t.expires_in * 1000 });
}
async function finishSignIn() {
  var q = new URLSearchParams(location.search);
  var pkce = load("pkce");
  history.replaceState(null, "", "/");
  drop("pkce");
  if (!pkce || q.get("state") !== pkce.state) throw new Error("Sign-in state did not match. Sign in again.");
  await tokenRequest({ grant_type: "authorization_code", client_id: CONFIG.clientId, code: q.get("code"), redirect_uri: REDIRECT, code_verifier: pkce.verifier });
}
async function accessToken() {
  var s = load("session");
  if (!s) return null;
  if (s.expires - Date.now() > 60000) return s.access;
  if (!s.refresh) return null;
  try { await tokenRequest({ grant_type: "refresh_token", client_id: CONFIG.clientId, refresh_token: s.refresh }); }
  catch (e) { drop("session"); return null; }
  return load("session").access;
}
function signOut() {
  drop("session");
  location.assign(CONFIG.auth + "/logout?" + new URLSearchParams({ client_id: CONFIG.clientId, logout_uri: REDIRECT }));
}

// ---------- rendering ----------
function el(tag, cls, text) {
  var n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text !== undefined && text !== null) n.textContent = text;
  return n;
}
function pill(status, pulse) {
  return el("span", "pill s-" + status + (pulse ? " pulse" : ""), STATUS_LABEL[status] || status);
}
function fmtNum(n) { return n === null || n === undefined ? "–" : n.toLocaleString(); }
function fmtSecs(ms) { return ms === null || ms === undefined ? "–" : (ms / 1000).toFixed(1) + " s"; }
function fmtTime(iso) {
  var d = new Date(iso);
  return d.toLocaleDateString(undefined, { month: "short", day: "numeric" }) + " " + d.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
}

function stepStates(run) {
  var seen = {};
  run.steps.forEach(function (s) { seen[s] = true; });
  var live = run.status === "running", broken = run.status === "failed" || run.status === "timed_out";
  var flagged = false;
  return STEPS.map(function (pair) {
    var key = pair[0], state = "pending";
    if (key === "writing" && run.status === "empty") state = "skipped";
    else if (key === "writing" && seen.writing) state = seen.published ? "done" : live ? "active" : broken ? "failed" : "done";
    else if (seen[key]) state = "done";
    else if (!flagged && (live || broken) && !(seen.writing && !seen.published)) { state = live ? "active" : "failed"; flagged = true; }
    if (state === "active" || state === "failed") flagged = true;
    return [pair[1], state];
  });
}

function renderAgent(agent, maxTokens) {
  var card = el("section", "card");
  var head = el("div", "card-head");
  head.appendChild(el("span", "agent", agent.agent));
  head.appendChild(pill(agent.state, agent.state === "running"));
  card.appendChild(head);

  if (agent.error) { card.appendChild(el("div", "error", agent.error)); return card; }
  var run = agent.runs[0];
  if (!run) { card.appendChild(el("p", "empty-note", "No runs recorded yet.")); return card; }

  var latest = el("div", "card-head");
  latest.appendChild(el("span", "sub", "Latest run · " + fmtTime(run.started_at)));
  var chips = el("span");
  chips.appendChild(pill(run.status, run.status === "running"));
  if (maxTokens && run.output_tokens >= maxTokens) {
    chips.appendChild(document.createTextNode(" "));
    chips.appendChild(el("span", "pill s-limit", "Hit max_tokens"));
  }
  latest.appendChild(chips);
  card.appendChild(latest);

  var steps = el("ol", "steps");
  stepStates(run).forEach(function (s) { steps.appendChild(el("li", "step " + s[1], s[0])); });
  card.appendChild(steps);

  var elapsed = run.status === "running" ? Date.now() - new Date(run.started_at).getTime() : run.duration_ms;
  var metrics = el("dl", "metrics");
  [["Articles", fmtNum(run.articles)], ["Input tokens", fmtNum(run.input_tokens)],
   ["Output tokens", fmtNum(run.output_tokens)], [run.status === "running" ? "Elapsed" : "Duration", fmtSecs(elapsed)]
  ].forEach(function (m) {
    var d = el("div"); d.appendChild(el("dt", null, m[0])); d.appendChild(el("dd", null, m[1])); metrics.appendChild(d);
  });
  card.appendChild(metrics);
  if (run.error) card.appendChild(el("div", "error", run.error));

  if (agent.runs.length > 1) {
    var wrap = el("div", "history"), table = el("table"), thead = el("tr");
    ["Started", "Status", "Articles", "In", "Out", "Duration"].forEach(function (h, i) { thead.appendChild(el("th", i > 1 ? "num" : null, h)); });
    table.appendChild(thead);
    agent.runs.slice(1, 9).forEach(function (r) {
      var tr = el("tr"), st = el("td");
      tr.appendChild(el("td", null, fmtTime(r.started_at)));
      st.appendChild(pill(r.status)); tr.appendChild(st);
      [fmtNum(r.articles), fmtNum(r.input_tokens), fmtNum(r.output_tokens), fmtSecs(r.duration_ms)].forEach(function (v) { tr.appendChild(el("td", "num", v)); });
      table.appendChild(tr);
    });
    wrap.appendChild(el("div", "sub", "Earlier runs"));
    wrap.appendChild(table);
    card.appendChild(wrap);
  }
  return card;
}

function render(data) {
  var main = document.getElementById("main");
  main.replaceChildren();
  var list = el("div"); list.style.display = "grid"; list.style.gap = "16px";
  data.agents.forEach(function (a) { list.appendChild(renderAgent(a, data.max_tokens)); });
  main.appendChild(list);
}

function showSignIn(message) {
  clearTimeout(timer);
  document.getElementById("signout").hidden = true;
  document.getElementById("watch").hidden = true;
  document.getElementById("updated").textContent = "Signed out";
  var main = document.getElementById("main");
  main.replaceChildren();
  var box = el("section", "card signin");
  box.appendChild(el("p", null, message || "Sign in to see your agents."));
  var b = el("button", "primary", "Sign in"); b.type = "button"; b.addEventListener("click", signIn);
  var row = el("div"); row.appendChild(b); box.appendChild(row);
  main.appendChild(box);
}

// ---------- polling: 2 s while any agent runs, 30 s when idle ----------
async function poll() {
  clearTimeout(timer);
  if (document.hidden) return; // resumes on visibilitychange
  var delay = IDLE_MS;
  try {
    var token = await accessToken();
    if (!token) return showSignIn();
    var r = await fetch(CONFIG.api + "/status", { headers: { authorization: "Bearer " + token }, cache: "no-store" });
    if (r.status === 401) { drop("session"); return showSignIn("Your session expired. Sign in again."); }
    if (!r.ok) throw new Error("HTTP " + r.status);
    var data = await r.json();
    render(data);
    document.getElementById("signout").hidden = false;
    var running = data.agents.some(function (a) { return a.state === "running"; });
    var manual = Date.now() < watchUntil;
    var scheduled = inWatchWindow();
    if (running || manual || scheduled) delay = RUNNING_MS;

    var watchBtn = document.getElementById("watch");
    watchBtn.hidden = false;
    watchBtn.setAttribute("aria-pressed", manual ? "true" : "false");
    watchBtn.textContent = manual ? "Watching · " + Math.ceil((watchUntil - Date.now()) / 1000) + " s" : "Watch now";

    document.getElementById("updated").textContent = "Updated " + new Date().toLocaleTimeString() +
      (!running && !manual && scheduled ? " · watching for the scheduled run" : "") +
      " · next check in " + delay / 1000 + " s";
  } catch (e) {
    document.getElementById("updated").textContent = "Couldn't reach the status API (" + e.message + "). Retrying in 30 s.";
  }
  timer = setTimeout(poll, delay);
}

document.getElementById("signout").addEventListener("click", signOut);
document.getElementById("watch").addEventListener("click", watchNow);
document.addEventListener("visibilitychange", function () { if (!document.hidden) poll(); });

(async function start() {
  try {
    if (new URLSearchParams(location.search).has("code")) await finishSignIn();
  } catch (e) {
    return showSignIn(e.message);
  }
  poll();
})();
</script>
</body>
</html>
