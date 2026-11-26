// Browser tests for agw-routing-simulator.html (zero dependencies). Run: node --test tests/
// They start headless Chrome (set CHROME_PATH if it is not found) and drive the page over the DevTools protocol.
// Without Chrome the tests are skipped.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import http from "node:http";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const PAGE = pathToFileURL(path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "agw-routing-simulator.html")).href;

function findChrome() {
  const candidates = [
    process.env.CHROME_PATH,
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
  ].filter(Boolean);
  for (const c of candidates) if (existsSync(c)) return c;
  for (const name of ["google-chrome", "google-chrome-stable", "chromium", "chromium-browser"]) {
    const r = spawnSync("which", [name], { encoding: "utf8" });
    if (r.status === 0 && r.stdout.trim()) return r.stdout.trim();
  }
  return null;
}
const CHROME = findChrome();
// Locally a missing Chrome skips the tests; in CI it fails them, so a broken runner cannot pass silently.
const skip = CHROME || process.env.CI ? false : "Chrome not found (set CHROME_PATH)";

let chrome, profile, ws, gateway, gatewayUrl;
let msgId = 0;
const pending = new Map();
const pageErrors = [];
let received = []; // requests the stand-in gateway got

function cdp(method, params = {}) {
  return new Promise((resolve, reject) => {
    const id = ++msgId;
    pending.set(id, { resolve, reject });
    ws.send(JSON.stringify({ id, method, params }));
  });
}
async function evaluate(expression) {
  const r = await cdp("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || r.exceptionDetails.text);
  return r.result.value;
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// In-page helpers: fill the form the way a user does (input / change events) and read the prediction.
const HELPERS = `window.__t = {
  $: (id) => document.getElementById(id),
  wait: (ms) => new Promise((r) => setTimeout(r, ms)),
  preset(re) { const b = [...document.querySelectorAll("#presets button")].find((x) => new RegExp(re).test(x.textContent)); if (!b) throw new Error("no preset " + re); b.click(); },
  set(id, value) { const e = this.$(id); e.value = value; e.dispatchEvent(new Event("input")); e.dispatchEvent(new Event("change")); },
  addHeader(name, value) { this.$("addHeader").click(); const ins = document.querySelectorAll("#headers input"); const n = ins[ins.length - 2], v = ins[ins.length - 1];
    n.value = name; n.dispatchEvent(new Event("input")); v.value = value; v.dispatchEvent(new Event("input")); },
  removeHeader(name) { for (const n of document.querySelectorAll("#headers input")) if (n.value === name) { n.value = ""; n.dispatchEvent(new Event("input")); } },
  async send() { this.$("sendBtn").click(); await this.wait(200); },
  async testRequests(n) { this.$("testN").value = n; this.$("testBtn").click();
    for (let i = 0; i < 100 && !/完了|Done/.test(this.$("testState").textContent); i++) await this.wait(100); },
  summary() { return this.$("summary").textContent; },
  prediction() { return this.$("simOut").textContent; },
};`;

async function open(lang, { config } = {}) {
  await cdp("Page.navigate", { url: `${PAGE}?lang=${lang}` });
  await sleep(500);
  // Start from the sample settings (or the given ones) so earlier tests do not leak into this one.
  await evaluate(`(() => { localStorage.clear(); ${config ? `localStorage.setItem("agw-routing-simulator:v1", ${JSON.stringify(JSON.stringify({ config }))});` : ""} })()`);
  await cdp("Page.reload");
  await sleep(500);
  await evaluate(HELPERS);
}
const page = (body) => evaluate(`(async () => { const t = window.__t; ${body} })()`);

before(async () => {
  if (skip) return;
  // Stand-in gateway: answers pool-partner when X-Partner-Id is present, else pool-web, and records each request.
  gateway = http.createServer((req, res) => {
    res.setHeader("access-control-allow-origin", "*");
    res.setHeader("access-control-allow-methods", "GET, HEAD, POST, PUT, DELETE, PATCH, OPTIONS");
    res.setHeader("access-control-allow-headers", "*");
    res.setHeader("access-control-expose-headers", "x-backend-pool");
    if (req.method === "OPTIONS") { res.writeHead(204); res.end(); return; }
    received.push({ method: req.method, url: req.url, partner: req.headers["x-partner-id"] || null });
    res.setHeader("x-backend-pool", req.headers["x-partner-id"] ? "pool-partner" : "pool-web");
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ headers: { "x-forwarded-for": "192.0.2.41:50000" } }));
  });
  await new Promise((r) => gateway.listen(0, "127.0.0.1", r));
  gatewayUrl = `http://127.0.0.1:${gateway.address().port}`;

  profile = mkdtempSync(path.join(tmpdir(), "agw-sim-test-"));
  if (!CHROME) throw new Error("Chrome not found (set CHROME_PATH)");
  // CI runners (Ubuntu 24.04) can refuse Chrome's sandbox, so it is turned off there only.
  const args = ["--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check", `--user-data-dir=${profile}`, "--remote-debugging-port=0"];
  if (process.env.CI) args.push("--no-sandbox");
  chrome = spawn(CHROME, [...args, "about:blank"], { stdio: "ignore" });
  const portFile = path.join(profile, "DevToolsActivePort");
  for (let i = 0; i < 100 && !existsSync(portFile); i++) await sleep(100);
  const port = readFileSync(portFile, "utf8").split("\n")[0];
  const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  ws = new WebSocket(targets.find((t) => t.type === "page").webSocketDebuggerUrl);
  ws.onmessage = (m) => {
    const d = JSON.parse(m.data);
    if (d.id && pending.has(d.id)) { const p = pending.get(d.id); pending.delete(d.id); d.error ? p.reject(new Error(d.error.message)) : p.resolve(d.result); }
    if (d.method === "Runtime.exceptionThrown") pageErrors.push(d.params.exceptionDetails.exception?.description || "error");
  };
  await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
  await cdp("Runtime.enable");
  await cdp("Page.enable");
});

after(async () => {
  ws?.close();
  chrome?.kill();
  gateway?.close();
  if (profile) { await sleep(300); rmSync(profile, { recursive: true, force: true }); }
});

test("the prediction stays on the last sent request until a button is pressed", { skip }, async () => {
  await open("en");
  const r = await page(`t.preset("^Default$"); await t.send(); const sent = t.summary();
    t.addHeader("X-Partner-Id", "fabrikam"); t.set("method", "POST"); await t.wait(200);
    return { sent, edited: t.summary() };`);
  assert.match(r.sent, /pool-web/);
  assert.equal(r.edited, r.sent);
});

test("Send request: a header change changes the prediction", { skip }, async () => {
  await open("en");
  const r = await page(`t.preset("^Default$"); await t.send(); const before = t.summary();
    t.addHeader("X-Tenant-Id", "customer-7"); await t.send(); const added = t.summary();
    t.removeHeader("X-Tenant-Id"); await t.send(); return { before, added, removed: t.summary() };`);
  assert.match(r.before, /pool-web/);
  assert.match(r.added, /pool-tenant/);
  assert.match(r.removed, /pool-web/);
});

test("Send request: a path change changes the prediction", { skip }, async () => {
  await open("en");
  const r = await page(`t.preset("^Tenant$"); await t.send(); const before = t.summary();
    t.set("path", "/api/orders"); await t.send(); return { before, after: t.summary() };`);
  assert.match(r.before, /pool-tenant/);
  assert.match(r.after, /pool-web/); // the tenant rule also needs a path under /app
});

test("Send request: a query change changes the prediction", { skip }, async () => {
  await open("en");
  const r = await page(`t.preset("^Default$"); t.set("query", "campaign=spring"); await t.send(); return { s: t.summary(), p: t.prediction() };`);
  assert.match(r.s + r.p, /campaign/i);
  assert.match(r.p, /302/);
});

test("Send request: a method change changes the prediction", { skip }, async () => {
  // The sample has no Method condition, so load saved settings with one rule: POST goes to pool-api-v2.
  const config = {
    defaultPool: "pool-web",
    waf: { enabled: true, blocked: ["198.51.100.0/24"], blockedUA: ["agw-block-demo"] },
    rules: [{ name: "POST only", priority: 5, conditions: [{ type: "Method", values: ["POST"] }], target: { pool: "pool-api-v2" } }],
  };
  await open("en", { config });
  const r = await page(`t.preset("^Default$"); await t.send(); const get = t.summary();
    t.set("method", "POST"); await t.send(); return { get, post: t.summary() };`);
  // With the sample settings the Default request never reaches pool-api-v2, so pool-api-v2 also shows the saved rule was used.
  assert.doesNotMatch(r.get, /pool-api-v2/);
  assert.match(r.post, /pool-api-v2/);
});

test("Send request: client IP and User-Agent changes reach the WAF prediction", { skip }, async () => {
  await open("en");
  const r = await page(`t.preset("^Default$"); t.set("clientIp", "198.51.100.7"); await t.send(); const ip = t.prediction();
    t.set("clientIp", "192.0.2.41"); await t.send(); const ok = t.prediction();
    t.removeHeader("User-Agent"); t.addHeader("User-Agent", "agw-block-demo"); await t.send(); return { ip, ok, ua: t.prediction() };`);
  assert.match(r.ip, /403/);
  assert.doesNotMatch(r.ok, /403/);
  assert.match(r.ua, /403/);
});

test("Send test requests: the prediction and the requests follow the form", { skip }, async () => {
  await open("en");
  await page(`t.set("backendUrl", ${JSON.stringify(gatewayUrl)}); await t.wait(500);`);
  received = [];
  const first = await page(`t.preset("^Default$"); t.addHeader("X-Partner-Id", "fabrikam"); await t.testRequests(6);
    return { s: t.summary(), result: t.$("testResult").textContent };`);
  const firstSent = [...new Set(received.map((x) => `${x.method} ${x.url} ${x.partner}`))];
  received = [];
  const second = await page(`t.set("method", "POST"); t.set("query", "x=1"); await t.testRequests(6); return { s: t.summary() };`);
  const secondSent = [...new Set(received.map((x) => `${x.method} ${x.url} ${x.partner}`))];
  assert.match(first.s, /pool-partner/);
  assert.match(first.result, /pool-partner/);
  assert.deepEqual(firstSent, ["GET /app/home fabrikam"]);
  assert.deepEqual(secondSent, ["POST /app/home?x=1 fabrikam"]);
  assert.match(second.s, /pool-partner/);
});

for (const lang of ["en", "ja"]) {
  test(`ports that ignore the request say so, and a header change does not change their prediction (${lang})`, { skip }, async () => {
    await open(lang);
    const note = lang === "ja" ? /ヘッダー、メソッド、パス、クエリでは振り分けません/ : /does not route by header, method, path, or query/;
    for (const port of [8080, 8090, 8110, 8120, 8130]) {
      const r = await page(`t.preset("ポート ${port}|port ${port}"); await t.send(); const before = t.prediction();
        t.addHeader("X-Partner-Id", "fabrikam"); t.set("method", "POST"); await t.send(); return { before, after: t.prediction() };`);
      assert.match(r.before, note, `note on ${port}`);
      assert.equal(r.after, r.before, `prediction on ${port}`);
    }
    const r80 = await page(`t.preset("^(Partner|パートナー)$"); await t.send(); return t.prediction();`);
    assert.doesNotMatch(r80, note);
  });
}

test("no JavaScript errors", { skip }, () => {
  assert.deepEqual(pageErrors, []);
});
