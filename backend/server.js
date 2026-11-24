// Demo backend for Azure Application Gateway Advanced Routing.
// Zero dependencies (Node.js 18+). One process = one backend pool.
//   POOL_NAME=pool-tenant POOL_LABEL="Tenant" POOL_COLOR="#0f766e" PORT=8082 node server.js
// GET /healthz          -> 200 "ok" (App Gateway health probe)
// GET /...?format=json  -> JSON echo (or Accept: application/json)
// GET /...              -> HTML page showing which pool answered and what it received
// OPTIONS (CORS preflight) -> 204 with CORS headers (ALLOW_ORIGIN, default "*")
"use strict";
const http = require("http");
const os = require("os");

const POOL_NAME = process.env.POOL_NAME || "pool-web";
const POOL_LABEL = process.env.POOL_LABEL || POOL_NAME;
const POOL_COLOR = /^#[0-9a-fA-F]{6}$/.test(process.env.POOL_COLOR || "") ? process.env.POOL_COLOR : "#334155";
const PORT = Number(process.env.PORT || 8080);
const HOST = os.hostname();
// CORS so the standalone simulator (agw-routing-simulator.html) can call the gateway directly.
// Default "*" (demo backend, no credentials). Set ALLOW_ORIGIN="" to disable, or to one origin.
const ALLOW_ORIGIN = process.env.ALLOW_ORIGIN === undefined ? "*" : process.env.ALLOW_ORIGIN;

function cors(res) {
  if (!ALLOW_ORIGIN) return;
  res.setHeader("access-control-allow-origin", ALLOW_ORIGIN);
  res.setHeader("access-control-allow-methods", "GET, HEAD, POST, PUT, DELETE, PATCH, OPTIONS");
  res.setHeader("access-control-allow-headers", "*");
  res.setHeader("access-control-expose-headers", "x-backend-pool");
  res.setHeader("access-control-max-age", "0"); // preflight is routed too; do not cache it
}

// Headers Application Gateway adds or rewrites before forwarding (highlighted on the page).
const GATEWAY_HEADERS = new Set([
  "x-forwarded-for",
  "x-forwarded-proto",
  "x-forwarded-port",
  "x-original-host",
  "x-original-url",
  "x-appgw-trace-id",
]);

const esc = (s) =>
  String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

function snapshot(req) {
  const url = new URL(req.url, "http://backend.local");
  return {
    pool: POOL_NAME,
    poolLabel: POOL_LABEL,
    instance: `${HOST}:${PORT}`,
    receivedAt: new Date().toISOString(),
    method: req.method,
    path: url.pathname,
    query: Object.fromEntries(url.searchParams),
    rawUrl: req.url,
    peer: req.socket.remoteAddress,
    headers: req.headers,
  };
}

function page(s) {
  const rows = Object.entries(s.headers)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(
      ([k, v]) =>
        `<tr${GATEWAY_HEADERS.has(k) ? ' class="gw"' : ""}><th scope="row">${esc(k)}</th><td>${esc(
          Array.isArray(v) ? v.join(", ") : v
        )}</td></tr>`
    )
    .join("");
  const query = Object.keys(s.query).length ? esc(new URLSearchParams(s.query).toString()) : "(none)";
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(s.pool)}  answered</title>
<style>
  :root{--pool:${POOL_COLOR}}
  body{margin:0;font-family:system-ui,"Segoe UI","Yu Gothic UI",sans-serif;color:#0f172a;background:#f8fafc}
  header{background:var(--pool);color:#fff;padding:28px 32px}
  header p{margin:0;font-size:14px}
  header h1{margin:6px 0 0;font-size:40px;font-family:ui-monospace,Consolas,monospace}
  header h2{margin:4px 0 0;font-size:18px;font-weight:500}
  main{padding:24px 32px;max-width:1000px}
  dl{display:grid;grid-template-columns:max-content 1fr;gap:6px 20px;margin:0 0 24px}
  dt{font-weight:600} dd{margin:0;font-family:ui-monospace,Consolas,monospace;word-break:break-all}
  table{border-collapse:collapse;width:100%;background:#fff}
  caption{text-align:left;font-weight:600;padding:0 0 8px}
  th,td{border:1px solid #cbd5e1;padding:6px 10px;text-align:left;vertical-align:top;font-family:ui-monospace,Consolas,monospace;font-size:13px;word-break:break-all}
  th{width:220px;font-weight:600}
  tr.gw{background:#fef3c7}
  .note{font-size:13px;margin-top:8px}
</style></head>
<body>
<header><p>Backend pool that answered this request</p><h1>${esc(s.pool)}</h1><h2>${esc(s.poolLabel)}</h2></header>
<main>
<dl>
  <dt>Instance</dt><dd>${esc(s.instance)}</dd>
  <dt>Received at (UTC)</dt><dd>${esc(s.receivedAt)}</dd>
  <dt>Method</dt><dd>${esc(s.method)}</dd>
  <dt>Path</dt><dd>${esc(s.path)}</dd>
  <dt>Query string</dt><dd>${query}</dd>
  <dt>Peer (gateway)</dt><dd>${esc(s.peer)}</dd>
</dl>
<table><caption>Request headers received</caption><tbody>${rows}</tbody></table>
<p class="note">Highlighted rows are headers that Application Gateway added or rewrote.</p>
</main></body></html>`;
}

http
  .createServer((req, res) => {
    cors(res);
    if (req.method === "OPTIONS" && req.headers["access-control-request-method"]) {
      res.setHeader("x-backend-pool", POOL_NAME);
      res.writeHead(204);
      return res.end();
    }
    if (req.url === "/healthz") {
      res.writeHead(200, { "content-type": "text/plain" });
      return res.end("ok");
    }
    const s = snapshot(req);
    const wantsJson = s.query.format === "json" || /application\/json/.test(req.headers.accept || "");
    res.setHeader("x-backend-pool", POOL_NAME);
    res.setHeader("cache-control", "no-store");
    if (wantsJson) {
      res.writeHead(200, { "content-type": "application/json; charset=utf-8" });
      return res.end(JSON.stringify(s, null, 2));
    }
    res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    res.end(page(s));
  })
  .listen(PORT, () => console.log(`${POOL_NAME} listening on :${PORT}`));
