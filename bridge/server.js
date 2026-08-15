import http from 'node:http';
import { readFileSync, existsSync } from 'node:fs';
import { readFile, stat } from 'node:fs/promises';
import { resolve, dirname, normalize, sep, extname } from 'node:path';
import crypto from 'node:crypto';
import { WebSocketServer, WebSocket } from 'ws';
import { createPairing } from './lib/pairing.js';

const DEFAULTS = {
  host: '0.0.0.0',
  port: 8787,
  dshBaseUrl: 'http://127.0.0.1:3080',
  token: '',
  allowedIps: [],
  trustProxy: false,
  rateLimit: {
    windowMs: 60000,
    max: 120,
  },
  // Pairing: one-time code, desktop confirmation, per-device tokens.
  pairTtlMs: 180000,
  pairPendingTtlMs: 600000,
  pairRequireApproval: true,
  devicesFile: '',
  webRoot: '',
};

/**
 * Only the methods the phone app actually needs. Everything else, including
 * credentials/settings/host-filesystem methods, is denied by default so new
 * DSH methods can never be exposed by accident.
 */
const ALLOWED_METHODS = new Set([
  'session.list',
  'session.create',
  'session.prompt',
  'session.cancel',
  'session.history',
  'respond',
]);

function loadConfig() {
  const configPath = process.env.BRIDGE_CONFIG || resolve(process.cwd(), 'config.json');
  let fileConfig = {};
  if (existsSync(configPath)) {
    try {
      fileConfig = JSON.parse(readFileSync(configPath, 'utf8'));
    } catch (err) {
      console.error(`[bridge] failed to parse config file ${configPath}:`, err.message);
      process.exit(1);
    }
  }
  const config = {
    ...DEFAULTS,
    ...fileConfig,
    token: process.env.BRIDGE_TOKEN || fileConfig.token || DEFAULTS.token,
    port: Number(process.env.BRIDGE_PORT || fileConfig.port || DEFAULTS.port),
    host: process.env.BRIDGE_HOST || fileConfig.host || DEFAULTS.host,
    dshBaseUrl: process.env.DSH_BASE_URL || fileConfig.dshBaseUrl || DEFAULTS.dshBaseUrl,
    allowedIps: fileConfig.allowedIps ?? DEFAULTS.allowedIps,
    trustProxy: fileConfig.trustProxy ?? DEFAULTS.trustProxy,
    pairTtlMs: Number(fileConfig.pairTtlMs || DEFAULTS.pairTtlMs),
    pairPendingTtlMs: Number(fileConfig.pairPendingTtlMs || DEFAULTS.pairPendingTtlMs),
    pairRequireApproval: fileConfig.pairRequireApproval ?? DEFAULTS.pairRequireApproval,
    devicesFile: process.env.BRIDGE_DEVICES_FILE || fileConfig.devicesFile || DEFAULTS.devicesFile,
    webRoot: process.env.BRIDGE_WEB_ROOT || fileConfig.webRoot || DEFAULTS.webRoot,
    rateLimit: {
      ...DEFAULTS.rateLimit,
      ...(fileConfig.rateLimit ?? {}),
    },
  };
  if (!config.token) {
    console.error('[bridge] ERROR: no BRIDGE_TOKEN set and no "token" in config.json.');
    console.error('[bridge] Generate one with: openssl rand -hex 32');
    process.exit(1);
  }
  return config;
}

const configPath = process.env.BRIDGE_CONFIG || resolve(process.cwd(), 'config.json');
const config = loadConfig();
const pairing = createPairing({ config, configDir: dirname(configPath) });

function resolveWebRoot() {
  const configDir = dirname(configPath);
  const candidates = [];
  if (config.webRoot) candidates.push(resolve(configDir, config.webRoot));
  candidates.push(
    resolve(configDir, 'webapp'),
    resolve(configDir, '../app/build/web'),
    resolve(process.cwd(), 'webapp'),
    resolve(process.cwd(), '../app/build/web'),
  );
  for (const candidate of candidates) {
    if (existsSync(resolve(candidate, 'index.html'))) return candidate;
  }
  return '';
}

const webRoot = resolveWebRoot();

function safeEqual(a, b) {
  const ba = Buffer.from(String(a));
  const bb = Buffer.from(String(b));
  if (ba.length !== bb.length) return false;
  return crypto.timingSafeEqual(ba, bb);
}

function authTokenFromRequest(req) {
  const header = req.headers['authorization'] || '';
  if (header.toLowerCase().startsWith('bearer ')) return header.slice(7).trim();
  const url = new URL(req.url, 'http://localhost');
  const q = url.searchParams.get('token');
  return q || '';
}

function authInfoFromRequest(req) {
  const token = authTokenFromRequest(req);
  if (token.length === 0) return { ok: false };
  if (safeEqual(token, config.token)) return { ok: true, kind: 'master' };
  const device = pairing.verifyDeviceToken(token);
  if (device) return { ok: true, kind: 'device', device };
  return { ok: false };
}

function normalizeIp(ip) {
  if (!ip) return '';
  return ip.replace(/^::ffff:/, '').replace(/^::1$/, '127.0.0.1');
}

function clientIp(req) {
  if (config.trustProxy) {
    const forwarded = req.headers['x-forwarded-for'];
    if (typeof forwarded === 'string' && forwarded.length > 0) {
      return normalizeIp(forwarded.split(',')[0].trim());
    }
  }
  return normalizeIp(req.socket.remoteAddress);
}

function isIpAllowed(ip) {
  const allowed = config.allowedIps;
  if (!Array.isArray(allowed) || allowed.length === 0) return true;
  return allowed.some((entry) => {
    const item = String(entry).trim();
    if (!item) return false;
    if (item.includes('/')) {
      const [base, bitsStr] = item.split('/');
      const bits = Number(bitsStr);
      if (!Number.isInteger(bits) || bits < 0 || bits > 128) return false;
      return ipInCidr(ip, base, bits);
    }
    return ip === normalizeIp(item);
  });
}

function ipInCidr(ip, base, bits) {
  const ipBytes = ipToBytes(ip);
  const baseBytes = ipToBytes(base);
  if (!ipBytes || !baseBytes || ipBytes.length !== baseBytes.length) return false;
  const fullBytes = Math.floor(bits / 8);
  const remainderBits = bits % 8;
  for (let i = 0; i < fullBytes; i++) {
    if (ipBytes[i] !== baseBytes[i]) return false;
  }
  if (remainderBits > 0 && fullBytes < ipBytes.length) {
    const mask = 0xff << (8 - remainderBits) & 0xff;
    if ((ipBytes[fullBytes] & mask) !== (baseBytes[fullBytes] & mask)) return false;
  }
  return true;
}

function ipToBytes(ip) {
  const normalized = normalizeIp(ip);
  if (!normalized) return null;
  const v4 = normalized.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  if (v4) {
    return v4.slice(1).map((n) => Number(n));
  }
  // IPv6 not implemented for CIDR; exact string matching still works above.
  return null;
}

const rateBuckets = new Map();

function checkRateLimit(ip) {
  const { windowMs, max } = config.rateLimit;
  if (!windowMs || !max) return true;
  const now = Date.now();
  const bucket = rateBuckets.get(ip);
  if (!bucket || bucket.resetAt <= now) {
    rateBuckets.set(ip, { count: 1, resetAt: now + windowMs });
    return true;
  }
  bucket.count += 1;
  if (bucket.count > max) return false;
  return true;
}

const claimBuckets = new Map();

function checkClaimRateLimit(ip) {
  const now = Date.now();
  const bucket = claimBuckets.get(ip);
  if (!bucket || bucket.resetAt <= now) {
    claimBuckets.set(ip, { count: 1, resetAt: now + 60000 });
    return true;
  }
  bucket.count += 1;
  return bucket.count <= 20;
}

setInterval(() => {
  const now = Date.now();
  for (const [ip, bucket] of rateBuckets) {
    if (bucket.resetAt <= now) rateBuckets.delete(ip);
  }
  for (const [ip, bucket] of claimBuckets) {
    if (bucket.resetAt <= now) claimBuckets.delete(ip);
  }
}, Math.max(config.rateLimit.windowMs || 60000, 60000)).unref?.();

function sendJson(res, status, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(body),
    'access-control-allow-origin': '*',
    'access-control-allow-headers': 'content-type, authorization',
    'access-control-allow-methods': 'GET, POST, OPTIONS',
    'access-control-allow-private-network': 'true',
  });
  res.end(body);
}

function sendText(res, status, text) {
  res.writeHead(status, {
    'content-type': 'text/plain; charset=utf-8',
    'content-length': Buffer.byteLength(text),
  });
  res.end(text);
}

function handleOptions(req, res) {
  res.writeHead(204, {
    'access-control-allow-origin': '*',
    'access-control-allow-headers': 'content-type, authorization',
    'access-control-allow-methods': 'GET, POST, OPTIONS',
    'access-control-allow-private-network': 'true',
  });
  res.end();
}

async function proxyToDsh(req, res) {
  const url = new URL(req.url, 'http://localhost');
  const target = new URL(url.pathname + url.search, config.dshBaseUrl);

  const headers = {
    'content-type': req.headers['content-type'] || 'application/json',
    accept: req.headers['accept'] || 'application/json',
  };
  // Do not forward browser-only or auth headers to DSH. Host will be set by
  // undici to 127.0.0.1:3080, which satisfies DSH's loopback trust fence.
  const body = req.method === 'GET' || req.method === 'HEAD' ? undefined : await readBody(req);

  let upstream;
  try {
    upstream = await fetch(target, {
      method: req.method,
      headers,
      body,
      redirect: 'manual',
    });
  } catch (err) {
    console.error('[bridge] upstream request failed:', err.message);
    sendJson(res, 502, { error: 'bridge_upstream_error', message: err.message });
    return;
  }

  const responseHeaders = {};
  for (const [key, value] of upstream.headers) {
    if (key.toLowerCase() === 'content-encoding' || key.toLowerCase() === 'transfer-encoding') continue;
    responseHeaders[key] = value;
  }
  responseHeaders['access-control-allow-origin'] = '*';

  res.writeHead(upstream.status, responseHeaders);
  if (upstream.body) {
    for await (const chunk of upstream.body) {
      if (!res.write(chunk)) await new Promise((resolve) => res.once('drain', resolve));
    }
  }
  res.end();
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function isStreamPath(pathname) {
  return pathname === '/api/events.mux' || pathname === '/api/events.host';
}

const WEB_MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.wasm': 'application/wasm',
  '.otf': 'font/otf',
  '.ttf': 'font/ttf',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.txt': 'text/plain; charset=utf-8',
  '.map': 'application/json',
};

async function serveWebApp(req, res, pathname) {
  if (!webRoot) {
    sendText(res, 404, 'web app not built; run: flutter build web --release');
    return;
  }
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    sendText(res, 405, 'method not allowed');
    return;
  }
  const rel = pathname === '/app' || pathname === '/app/' ? 'index.html' : pathname.slice('/app/'.length);
  const filePath = normalize(resolve(webRoot, rel));
  if (filePath !== webRoot && !filePath.startsWith(webRoot + sep)) {
    sendText(res, 403, 'forbidden');
    return;
  }
  try {
    let target = filePath;
    const info = await stat(target);
    if (info.isDirectory()) target = resolve(target, 'index.html');
    const body = await readFile(target);
    const type = WEB_MIME[extname(target).toLowerCase()] ?? 'application/octet-stream';
    res.writeHead(200, {
      'content-type': type,
      'content-length': body.length,
      'cache-control': 'no-cache',
    });
    if (req.method === 'HEAD') res.end();
    else res.end(body);
  } catch (err) {
    if (err?.code === 'ENOENT') sendText(res, 404, 'not found');
    else sendText(res, 500, 'static file error');
  }
}

const server = http.createServer(async (req, res) => {
  if (req.method === 'OPTIONS') {
    handleOptions(req, res);
    return;
  }

  const pathname = new URL(req.url, 'http://localhost').pathname;
  const ip = clientIp(req);

  if (!isIpAllowed(ip)) {
    sendText(res, 403, 'forbidden');
    return;
  }
  if (!checkRateLimit(ip)) {
    sendText(res, 429, 'too many requests');
    return;
  }

  // Health endpoint for checking the bridge is alive.
  if (pathname === '/health' || pathname === '/') {
    sendJson(res, 200, { ok: true, service: 'dsh-remote-bridge' });
    return;
  }

  // Mobile web app (Flutter web build) served by the bridge itself.
  if (pathname === '/app' || pathname.startsWith('/app/')) {
    await serveWebApp(req, res, pathname);
    return;
  }

  // Pairing surface (QR admin page, one-time codes, device management).
  if (pathname.startsWith('/pair/')) {
    if (pathname === '/pair/claim' && !checkClaimRateLimit(ip)) {
      sendText(res, 429, 'too many pairing attempts');
      return;
    }
    if (await pairing.handlePairRoutes(req, res, pathname, ip)) return;
  }

  if (!pathname.startsWith('/api/')) {
    sendJson(res, 404, { error: 'not_found' });
    return;
  }

  const auth = authInfoFromRequest(req);
  if (!auth.ok) {
    sendText(res, 401, 'unauthorized');
    return;
  }
  if (auth.device) pairing.touchDevice(auth.device);

  const method = pathname.slice(5);
  if (!ALLOWED_METHODS.has(method)) {
    sendText(res, 403, 'method not allowed on remote bridge');
    return;
  }

  // Streaming endpoints are handled by WebSocket at /ws/events.mux.
  if (isStreamPath(pathname)) {
    sendText(res, 426, 'use WebSocket: /ws/events.mux?token=...');
    return;
  }

  await proxyToDsh(req, res);
});

const wss = new WebSocketServer({ noServer: true });

async function pipeDshEventsToWebSocket(socket, dshWsUrl) {
  let upstream;
  try {
    upstream = new WebSocket(dshWsUrl);
  } catch (err) {
    console.error('[bridge] DSH WebSocket connect failed:', err.message);
    socket.close(1011, 'upstream failed');
    return;
  }

  upstream.on('open', () => {
    if (socket.readyState === WebSocket.OPEN) {
      socket.send(JSON.stringify({ type: 'bridge/connected', dsh: config.dshBaseUrl }));
    }
  });

  upstream.on('message', (data) => {
    if (socket.readyState === WebSocket.OPEN) {
      socket.send(data.toString());
    }
  });

  upstream.on('error', (err) => {
    console.error('[bridge] DSH WebSocket error:', err.message);
    if (socket.readyState === WebSocket.OPEN) socket.close(1011, 'upstream error');
  });

  upstream.on('close', (code, reason) => {
    if (socket.readyState === WebSocket.OPEN) socket.close(1000, 'upstream closed');
  });

  socket.on('close', () => {
    try {
      upstream.close();
    } catch {}
  });

  socket.on('error', () => {
    try {
      upstream.close();
    } catch {}
  });
}

server.on('upgrade', (req, socket, head) => {
  const url = new URL(req.url, 'http://localhost');
  if (url.pathname !== '/ws/events.mux') {
    socket.destroy();
    return;
  }

  const ip = clientIp(req);
  if (!isIpAllowed(ip)) {
    socket.write('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n');
    socket.destroy();
    return;
  }
  if (!checkRateLimit(ip)) {
    socket.write('HTTP/1.1 429 Too Many Requests\r\nConnection: close\r\n\r\n');
    socket.destroy();
    return;
  }
  const auth = authInfoFromRequest(req);
  if (!auth.ok) {
    socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
    socket.destroy();
    return;
  }
  if (auth.device) pairing.touchDevice(auth.device);

  wss.handleUpgrade(req, socket, head, (ws) => {
    const dshWsUrl = config.dshBaseUrl.replace(/^http/, 'ws') + '/api/events.mux';
    pipeDshEventsToWebSocket(ws, dshWsUrl);
  });
});

server.listen(config.port, config.host, () => {
  console.log(`[bridge] dsh-remote-bridge listening on http://${config.host}:${config.port}`);
  console.log(`[bridge] forwarding to DSH at ${config.dshBaseUrl}`);
  console.log(`[bridge] REST API: http://<host>:${config.port}/api/*`);
  console.log(`[bridge] WebSocket stream: ws://<host>:${config.port}/ws/events.mux?token=<token>`);
  console.log(`[bridge] pairing page: http://127.0.0.1:${config.port}/pair/qr (desktop only)`);
  console.log(`[bridge] mobile web app: ${webRoot ? `http://<host>:${config.port}/app/` : 'not built (flutter build web --release)'}`);
  console.log(`[bridge] API allowlist: ${[...ALLOWED_METHODS].join(', ')}`);
  console.log('[bridge] keep your token secret; never expose DSH 3080 directly.');
});
