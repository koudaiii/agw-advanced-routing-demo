// Tests for backend/server.js (zero dependencies). Run: node --test backend/server.test.js
"use strict";
const { test, after } = require("node:test");
const assert = require("node:assert");
const { spawn } = require("node:child_process");
const net = require("node:net");
const path = require("node:path");

const SERVER = path.join(__dirname, "server.js");
const children = [];
after(() => children.forEach((c) => c.kill()));

function freePort() {
  return new Promise((resolve, reject) => {
    const s = net.createServer().listen(0, "127.0.0.1", () => {
      const { port } = s.address();
      s.close(() => resolve(port));
    });
    s.on("error", reject);
  });
}

// Starts server.js with the given environment and resolves with its base URL once it listens.
async function start(env) {
  const port = await freePort();
  const child = spawn(process.execPath, [SERVER], { env: { ...process.env, SERVER_NAME: "srv-test", PORT: String(port), ...env } });
  children.push(child);
  await new Promise((resolve, reject) => {
    child.stdout.on("data", (d) => { if (String(d).includes("listening")) resolve(); });
    child.on("exit", (code) => reject(new Error(`server exited with ${code}`)));
  });
  return `http://127.0.0.1:${port}`;
}

async function timed(url, init) {
  const t0 = performance.now();
  const res = await fetch(url, init);
  const body = await res.text();
  return { res, body, ms: performance.now() - t0 };
}

test("DELAY_MS delays normal requests", async () => {
  const base = await start({ DELAY_MS: "300" });
  const { res, ms } = await timed(`${base}/`);
  assert.strictEqual(res.status, 200);
  assert.strictEqual(res.headers.get("x-backend-srv"), "srv-test");
  assert.ok(ms >= 280, `took ${ms} ms`);
});

test("healthz is not delayed", async () => {
  const base = await start({ DELAY_MS: "3000" });
  const { res, body, ms } = await timed(`${base}/healthz`);
  assert.strictEqual(res.status, 200);
  assert.strictEqual(body, "ok");
  assert.ok(ms < 500, `took ${ms} ms`);
});

test("CORS preflight is not delayed", async () => {
  const base = await start({ DELAY_MS: "3000" });
  const { res, ms } = await timed(`${base}/app/home`, { method: "OPTIONS", headers: { "access-control-request-method": "GET", origin: "http://example.test" } });
  assert.strictEqual(res.status, 204);
  assert.ok(ms < 500, `took ${ms} ms`);
});

test("invalid DELAY_MS is treated as 0", async () => {
  for (const value of ["abc", "-5"]) {
    const base = await start({ DELAY_MS: value });
    const { res, ms } = await timed(`${base}/`);
    assert.strictEqual(res.status, 200);
    assert.ok(ms < 500, `DELAY_MS=${value} took ${ms} ms`);
  }
});

test("normal responses and preflights name the server in x-backend-srv only", async () => {
  const base = await start({});
  const res = await fetch(`${base}/app?format=json`);
  assert.strictEqual(res.headers.get("x-backend-srv"), "srv-test");
  assert.strictEqual(res.headers.get("x-backend-pool"), null);
  assert.strictEqual(res.headers.get("access-control-expose-headers"), "x-backend-srv");
  const body = await res.json();
  assert.strictEqual(body.server, "srv-test");
  assert.strictEqual(body.serverLabel, "srv-test");
  assert.strictEqual(body.pool, undefined);
  const pre = await fetch(`${base}/app`, { method: "OPTIONS", headers: { "access-control-request-method": "GET", origin: "http://example.test" } });
  assert.strictEqual(pre.headers.get("x-backend-srv"), "srv-test");
});

test("the HTML page says which server answered", async () => {
  const base = await start({ SERVER_LABEL: "Slow server (3 s)" });
  const html = await (await fetch(`${base}/`)).text();
  assert.match(html, /Backend server that answered this request/);
  assert.match(html, /<h1>srv-test<\/h1>/);
  assert.doesNotMatch(html, /Backend pool/);
});
