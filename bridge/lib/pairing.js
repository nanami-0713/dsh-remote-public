import crypto from 'node:crypto';
import { existsSync, readFileSync, writeFileSync, chmodSync, renameSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import os from 'node:os';
import QRCode from 'qrcode';

const DEVICE_NAME_MAX = 64;
const CODE_BYTES = 32;
const TOKEN_BYTES = 32;
const DEVICE_SAVE_INTERVAL_MS = 60_000;

function now() {
  return Date.now();
}

function hashToken(token) {
  return crypto.createHash('sha256').update(String(token)).digest('hex');
}

function sanitizeDeviceName(raw) {
  const name = String(raw ?? '').replace(/[\u0000-\u001f\u007f]/g, '').trim();
  if (!name) return null;
  return name.slice(0, DEVICE_NAME_MAX);
}

function isJsonRequest(req) {
  const type = req.headers['content-type'] || '';
  return type.toLowerCase().includes('application/json');
}

/**
 * Browser requests to the loopback-only admin surface must come from a
 * localhost origin (the bridge admin page itself, or the DSH web UI on
 * 127.0.0.1:3080). Requests without an Origin header (curl, native phone
 * apps) are treated as non-browser callers and pass; browser cross-site
 * attacks against 127.0.0.1 are rejected before the handler runs.
 */
export function isTrustedLocalOrigin(req) {
  const origin = req.headers['origin'];
  if (!origin) return true;
  try {
    const host = new URL(origin).hostname;
    return host === '127.0.0.1' || host === 'localhost' || host === '::1' || host === '[::1]';
  } catch {
    return false;
  }
}

export function isLoopbackIp(ip) {
  return ip === '127.0.0.1';
}

export function detectReachableBases(port) {
  const bases = [];
  const seen = new Set();
  for (const addrs of Object.values(os.networkInterfaces())) {
    for (const addr of addrs ?? []) {
      if (addr.internal || addr.family !== 'IPv4') continue;
      const ip = addr.address;
      if (ip.startsWith('169.254.') || seen.has(ip)) continue;
      let kind = 'other';
      if (ip.startsWith('100.')) kind = 'tailscale';
      else if (/^192\.168\./.test(ip)) kind = 'lan';
      else if (/^10\./.test(ip)) kind = 'lan';
      else if (/^172\.(1[6-9]|2\d|3[01])\./.test(ip)) kind = 'lan';
      else continue;
      seen.add(ip);
      bases.push({ ip, url: `http://${ip}:${port}`, kind });
    }
  }
  const rank = { tailscale: 0, lan: 1, other: 2 };
  bases.sort((a, b) => rank[a.kind] - rank[b.kind] || a.ip.localeCompare(b.ip));
  return bases;
}

function loadDevices(file) {
  if (!file) return [];
  try {
    if (!existsSync(file)) return [];
    const raw = JSON.parse(readFileSync(file, 'utf8'));
    const items = Array.isArray(raw?.devices) ? raw.devices : [];
    return items
      .filter((d) => d && typeof d.id === 'string' && typeof d.tokenHash === 'string')
      .map((d) => ({
        id: d.id,
        name: String(d.name ?? 'unknown').slice(0, DEVICE_NAME_MAX),
        tokenHash: d.tokenHash,
        ip: d.ip ?? '',
        createdAt: d.createdAt ?? now(),
        lastSeenAt: d.lastSeenAt ?? d.createdAt ?? now(),
      }));
  } catch (err) {
    console.error('[pairing] failed to load devices file, starting with empty registry:', err.message);
    return [];
  }
}

function saveDevices(file, devices) {
  if (!file) return;
  try {
    const tmp = `${file}.tmp`;
    writeFileSync(tmp, JSON.stringify({ version: 1, devices }, null, 2) + '\n', { mode: 0o600 });
    chmodSync(tmp, 0o600);
    renameSync(tmp, file);
  } catch (err) {
    console.error('[pairing] failed to save devices file:', err.message);
  }
}

export function createPairing({ config, configDir }) {
  const deviceFile = config.devicesFile
    ? resolve(configDir, config.devicesFile)
    : resolve(configDir, 'devices.json');
  const codeTtlMs = config.pairTtlMs;
  const pendingTtlMs = config.pairPendingTtlMs;
  const requireApproval = config.pairRequireApproval !== false;

  const codes = new Map(); // codeHash -> { code, id, createdAt, expiresAt }
  const pending = new Map(); // id -> { id, deviceName, ip, createdAt, expiresAt, status, tokenHash?, deviceId? }
  let devices = loadDevices(deviceFile);
  let dirty = false;
  let lastSavedAt = now();

  const timer = setInterval(() => {
    const t = now();
    for (const [hash, entry] of codes) if (entry.expiresAt <= t) codes.delete(hash);
    for (const [id, entry] of pending) {
      if (entry.status !== 'pending' && entry.expiresAt <= t) pending.delete(id);
      else if (entry.status === 'pending' && entry.expiresAt <= t) entry.status = 'rejected';
    }
    if (dirty && t - lastSavedAt >= DEVICE_SAVE_INTERVAL_MS) flushDevices();
  }, 10_000);
  timer.unref?.();

  function flushDevices() {
    if (!dirty) return;
    saveDevices(deviceFile, devices);
    dirty = false;
    lastSavedAt = now();
  }

  function issueToken(pairEntry) {
    const token = crypto.randomBytes(TOKEN_BYTES).toString('hex');
    const device = {
      id: crypto.randomUUID(),
      name: pairEntry.deviceName,
      tokenHash: hashToken(token),
      ip: pairEntry.ip,
      createdAt: now(),
      lastSeenAt: now(),
    };
    devices.push(device);
    dirty = true;
    flushDevices();
    return { token, device: publicDevice(device) };
  }

  function publicDevice(device) {
    return {
      id: device.id,
      name: device.name,
      ip: device.ip,
      createdAt: device.createdAt,
      lastSeenAt: device.lastSeenAt,
    };
  }

  function verifyDeviceToken(token) {
    if (typeof token !== 'string' || token.length === 0) return null;
    const digest = hashToken(token);
    for (const device of devices) {
      if (device.tokenHash.length !== digest.length) continue;
      if (crypto.timingSafeEqual(Buffer.from(device.tokenHash), Buffer.from(digest))) return device;
    }
    return null;
  }

  function touchDevice(device) {
    const t = now();
    if (t - device.lastSeenAt < DEVICE_SAVE_INTERVAL_MS) return;
    device.lastSeenAt = t;
    dirty = true;
  }

  function publicState() {
    return {
      requireApproval,
      pairTtlMs: codeTtlMs,
      bridgeName: config.bridgeName || os.hostname(),
      bases: detectReachableBases(config.port),
      pending: [...pending.values()]
        .filter((entry) => entry.status === 'pending')
        .map((entry) => ({
          id: entry.id,
          deviceName: entry.deviceName,
          ip: entry.ip,
          createdAt: entry.createdAt,
          expiresAt: entry.expiresAt,
        })),
      devices: devices.map(publicDevice).sort((a, b) => b.lastSeenAt - a.lastSeenAt),
    };
  }

  function startPairingCode() {
    const code = crypto.randomBytes(CODE_BYTES).toString('base64url');
    const id = crypto.randomUUID();
    const createdAt = now();
    codes.set(hashToken(code), { code, id, createdAt, expiresAt: createdAt + codeTtlMs });
    return { code, id, createdAt, expiresAt: createdAt + codeTtlMs };
  }

  function sendJson(res, status, obj) {
    const body = JSON.stringify(obj);
    res.writeHead(status, {
      'content-type': 'application/json; charset=utf-8',
      'content-length': Buffer.byteLength(body),
      'cache-control': 'no-store',
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
      'cache-control': 'no-store',
    });
    res.end(text);
  }

  async function readJsonBody(req) {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const body = Buffer.concat(chunks).toString('utf8');
    if (!body.trim()) return {};
    try {
      return JSON.parse(body);
    } catch {
      return null;
    }
  }

  async function handlePairRoutes(req, res, pathname, ip) {
    if (!pathname.startsWith('/pair/')) return false;
    const method = req.method ?? 'GET';

    // QR admin page (loopback only; serves the browser UI that owns codes).
    if (pathname === '/pair/qr' && method === 'GET') {
      if (!isLoopbackIp(ip) || !isTrustedLocalOrigin(req)) {
        sendText(res, 403, 'forbidden');
        return true;
      }
      res.writeHead(200, {
        'content-type': 'text/html; charset=utf-8',
        'cache-control': 'no-store',
      });
      res.end(adminPageHtml());
      return true;
    }

    if (pathname === '/pair/qr.svg' && method === 'GET') {
      if (!isLoopbackIp(ip) || !isTrustedLocalOrigin(req)) {
        sendText(res, 403, 'forbidden');
        return true;
      }
      const url = new URL(req.url, 'http://localhost');
      const code = url.searchParams.get('code') ?? '';
      const base = url.searchParams.get('base') ?? '';
      if (code.length < 20 || code.length > 128 || !/^https?:\/\//.test(base)) {
        sendText(res, 400, 'bad request');
        return true;
      }
      const target = `dshremote://pair?base=${encodeURIComponent(base)}&code=${encodeURIComponent(code)}&v=1`;
      try {
        const svg = await QRCode.toString(target, { type: 'svg', margin: 1, errorCorrectionLevel: 'M' });
        res.writeHead(200, {
          'content-type': 'image/svg+xml; charset=utf-8',
          'cache-control': 'no-store',
          'content-length': Buffer.byteLength(svg),
        });
        res.end(svg);
      } catch (err) {
        sendText(res, 500, 'qr generation failed');
      }
      return true;
    }

    // ---- loopback-only admin API ----------------------------------------
    if (['/pair/start', '/pair/approve', '/pair/reject', '/pair/revoke', '/pair/admin/state'].includes(pathname)) {
      if (!isLoopbackIp(ip) || !isTrustedLocalOrigin(req)) {
        sendText(res, 403, 'forbidden');
        return true;
      }
      if (method === 'OPTIONS') {
        res.writeHead(204, {
          'access-control-allow-origin': '*',
          'access-control-allow-headers': 'content-type',
          'access-control-allow-methods': 'POST, OPTIONS',
          'access-control-allow-private-network': 'true',
        });
        res.end();
        return true;
      }
      if (method === 'POST') {
        if (!isJsonRequest(req)) {
          sendText(res, 415, 'json required');
          return true;
        }
        const body = await readJsonBody(req);
        if (body === null) {
          sendText(res, 400, 'invalid json');
          return true;
        }
        if (pathname === '/pair/start') {
          const entry = startPairingCode();
          sendJson(res, 200, {
            ok: true,
            code: entry.code,
            expiresAt: entry.expiresAt,
            requireApproval,
          });
          return true;
        }
        if (pathname === '/pair/approve') {
          const entry = pending.get(String(body.id ?? ''));
          if (!entry || entry.status !== 'pending') {
            sendJson(res, 404, { ok: false, error: 'pairing request not found' });
            return true;
          }
          if (entry.expiresAt <= now()) {
            entry.status = 'rejected';
            sendJson(res, 410, { ok: false, error: 'pairing request expired' });
            return true;
          }
          const issued = issueToken(entry);
          entry.status = 'approved';
          entry.token = issued.token;
          entry.tokenHash = hashToken(issued.token);
          entry.deviceId = issued.device.id;
          entry.expiresAt = now() + 60_000; // device polls status within this window
          console.log(`[pairing] approved device "${entry.deviceName}" from ${entry.ip}`);
          sendJson(res, 200, { ok: true, device: issued.device });
          return true;
        }
        if (pathname === '/pair/reject') {
          const entry = pending.get(String(body.id ?? ''));
          if (!entry || entry.status !== 'pending') {
            sendJson(res, 404, { ok: false, error: 'pairing request not found' });
            return true;
          }
          entry.status = 'rejected';
          entry.expiresAt = now() + 60_000;
          console.log(`[pairing] rejected device "${entry.deviceName}" from ${entry.ip}`);
          sendJson(res, 200, { ok: true });
          return true;
        }
        if (pathname === '/pair/revoke') {
          const id = String(body.deviceId ?? '');
          const before = devices.length;
          devices = devices.filter((device) => device.id !== id);
          if (devices.length === before) {
            sendJson(res, 404, { ok: false, error: 'device not found' });
            return true;
          }
          dirty = true;
          flushDevices();
          console.log(`[pairing] revoked device ${id}`);
          sendJson(res, 200, { ok: true });
          return true;
        }
      }
      if (pathname === '/pair/admin/state' && method === 'GET') {
        sendJson(res, 200, { ok: true, ...publicState() });
        return true;
      }
      sendText(res, 405, 'method not allowed');
      return true;
    }

    // ---- phone-facing pairing API ---------------------------------------
    if (pathname === '/pair/claim' && method === 'POST') {
      if (!isJsonRequest(req)) {
        sendText(res, 415, 'json required');
        return true;
      }
      const body = await readJsonBody(req);
      if (body === null) {
        sendText(res, 400, 'invalid json');
        return true;
      }
      const code = String(body.code ?? '');
      if (code.length > 256) {
        sendText(res, 400, 'invalid code');
        return true;
      }
      const deviceName = sanitizeDeviceName(body.deviceName);
      if (!code || !deviceName) {
        sendText(res, 400, 'code and deviceName are required');
        return true;
      }
      const digest = hashToken(code);
      const codeEntry = codes.get(digest);
      if (!codeEntry) {
        sendJson(res, 404, { ok: false, error: 'pairing code is invalid or already used' });
        return true;
      }
      if (codeEntry.expiresAt <= now()) {
        codes.delete(digest);
        sendJson(res, 410, { ok: false, error: 'pairing code expired' });
        return true;
      }
      // Single use: the first valid claim consumes the code.
      codes.delete(digest);
      const entry = {
        id: crypto.randomUUID(),
        deviceName,
        ip,
        createdAt: now(),
        expiresAt: now() + pendingTtlMs,
        status: 'pending',
      };
      pending.set(entry.id, entry);
      console.log(`[pairing] pairing claim from "${deviceName}" at ${ip} (code ${codeEntry.id.slice(0, 8)}…)`);
      if (!requireApproval) {
        const issued = issueToken(entry);
        entry.status = 'approved';
        entry.tokenHash = hashToken(issued.token);
        entry.deviceId = issued.device.id;
        entry.expiresAt = now() + 60_000;
        sendJson(res, 200, {
          ok: true,
          status: 'approved',
          token: issued.token,
          device: issued.device,
          bridgeName: config.bridgeName || os.hostname(),
        });
        return true;
      }
      sendJson(res, 200, {
        ok: true,
        status: 'pending',
        pairId: entry.id,
        expiresAt: entry.expiresAt,
        bridgeName: config.bridgeName || os.hostname(),
        message: 'waiting for desktop approval',
      });
      return true;
    }

    if (pathname === '/pair/status' && method === 'GET') {
      const url = new URL(req.url, 'http://localhost');
      const entry = pending.get(url.searchParams.get('id') ?? '');
      if (!entry) {
        sendJson(res, 404, { ok: false, error: 'pairing request not found' });
        return true;
      }
      // The token is only handed to the same network peer that claimed the code.
      if (entry.ip !== ip) {
        sendJson(res, 403, { ok: false, error: 'forbidden' });
        return true;
      }
      if (entry.status === 'pending' && entry.expiresAt <= now()) {
        entry.status = 'rejected';
      }
      if (entry.status === 'pending') {
        sendJson(res, 200, { ok: true, status: 'pending', expiresAt: entry.expiresAt });
      } else if (entry.status === 'approved') {
        const device = devices.find((candidate) => candidate.id === entry.deviceId);
        if (!device) {
          sendJson(res, 410, { ok: false, error: 'device was revoked' });
          return true;
        }
        sendJson(res, 200, {
          ok: true,
          status: 'approved',
          token: entry.token ?? null,
          device: device ? publicDevice(device) : null,
          bridgeName: config.bridgeName || os.hostname(),
        });
        // Return the token exactly once, then drop it from memory.
        if (entry.token) entry.token = null;
      } else {
        sendJson(res, 403, { ok: false, status: 'rejected', error: 'pairing was rejected' });
        pending.delete(entry.id);
      }
      return true;
    }

    return false;
  }

  return {
    handlePairRoutes,
    verifyDeviceToken,
    touchDevice,
    publicState,
    flushDevices,
    deviceFile,
  };
}

function adminPageHtml() {
  return `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>DSH-Remote 配对</title>
<style>
:root { color-scheme: light; --blue:#4D6BFE; --bg:#F9FAFB; --surface:#fff; --border:#E5E7EB; --text:#111827; --muted:#6B7280; --red:#DC2626; --green:#16A34A; }
* { box-sizing: border-box; }
body { margin:0; font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Hiragino Sans GB","Microsoft YaHei",sans-serif; background:var(--bg); color:var(--text); }
.wrap { max-width:760px; margin:0 auto; padding:24px 16px 64px; }
h1 { font-size:20px; margin:0 0 4px; }
.sub { color:var(--muted); margin:0 0 20px; }
.card { background:var(--surface); border:1px solid var(--border); border-radius:16px; padding:20px; margin-bottom:16px; }
.row { display:flex; align-items:center; gap:12px; flex-wrap:wrap; }
.row label { color:var(--muted); }
select, button { font:inherit; }
select { padding:8px 12px; border:1px solid var(--border); border-radius:10px; background:#fff; }
button { padding:8px 14px; border-radius:10px; border:1px solid var(--border); background:#fff; cursor:pointer; }
button.primary { background:var(--blue); border-color:var(--blue); color:#fff; }
button.danger { color:var(--red); border-color:#FECACA; }
button.ghost { color:var(--blue); border-color:transparent; }
button:disabled { opacity:.5; cursor:not-allowed; }
.qr-box { display:flex; flex-direction:column; align-items:center; gap:12px; }
.qr-box img { width:260px; height:260px; border:1px solid var(--border); border-radius:14px; padding:8px; background:#fff; }
.countdown { color:var(--muted); font-size:13px; }
.badge { display:inline-block; padding:2px 10px; border-radius:999px; font-size:12px; background:#EEF2FF; color:var(--blue); }
table { width:100%; border-collapse:collapse; }
th, td { text-align:left; padding:10px 8px; border-bottom:1px solid var(--border); vertical-align:middle; }
th { color:var(--muted); font-weight:500; font-size:13px; }
.empty { color:var(--muted); text-align:center; padding:18px 0; }
.status { display:flex; align-items:center; gap:8px; font-size:13px; color:var(--muted); }
.dot { width:8px; height:8px; border-radius:50%; background:var(--green); }
.dot.off { background:#D1D5DB; }
#pairUrl { flex:1; min-width:240px; font:12px/1.4 ui-monospace,Menlo,monospace; word-break:break-all; color:var(--muted); }
</style>
</head>
<body>
<div class="wrap">
  <h1>DSH-Remote 设备配对</h1>
  <p class="sub">在手机 DSH-Remote App 里扫码绑定；二维码不含永久 Token，且只生效一次。</p>

  <div class="card">
    <div class="status">
      <span class="dot" id="bridgeDot"></span><span id="bridgeStatus">bridge 连接中…</span>
      <span class="badge" id="pcBadge">电脑: —</span>
      <span class="badge" id="modeBadge">桌面确认: —</span>
    </div>
  </div>

  <div class="card">
    <div class="row" style="margin-bottom:12px">
      <label for="baseSelect">手机访问地址</label>
      <select id="baseSelect"></select>
      <button id="refreshBases">刷新地址</button>
    </div>
    <div class="qr-box">
      <img id="qrImg" alt="配对二维码" style="display:none">
      <div id="qrEmpty" class="empty">点击「生成配对二维码」开始</div>
      <div class="row">
        <button class="primary" id="startPair">生成配对二维码</button>
        <button class="ghost" id="copyUrl">复制 App 配对链接</button>
        <button class="ghost" id="copyWebUrl">复制网页版链接</button>
      </div>
      <div id="pairUrl"></div>
      <div id="webUrl"></div>
      <div class="countdown" id="countdown"></div>
    </div>
  </div>

  <div class="card">
    <h2 style="font-size:15px;margin:0 0 12px">待确认的设备</h2>
    <div id="pendingList"><div class="empty">暂无</div></div>
  </div>

  <div class="card">
    <h2 style="font-size:15px;margin:0 0 12px">已绑定设备</h2>
    <div id="deviceList"><div class="empty">暂无</div></div>
  </div>
</div>

<script>
const state = { code:null, expiresAt:0, bases:[], selectedBase:'', pending:[], devices:[], requireApproval:true, bridgeName:'', timer:null };

async function api(path, options = {}) {
  const res = await fetch(path, {
    ...options,
    headers: { 'content-type':'application/json', ...(options.headers||{}) },
  });
  if (!res.ok) throw new Error(path + ' HTTP ' + res.status);
  return res.json();
}

function pairPayload(base, code) {
  return 'dshremote://pair?base=' + encodeURIComponent(base) + '&code=' + encodeURIComponent(code) + '&v=1';
}

function webPayload(base, code) {
  const u = new URL('/app/', base);
  u.searchParams.set('code', code);
  return u.toString();
}

function renderBases() {
  const sel = document.getElementById('baseSelect');
  const prev = state.selectedBase;
  sel.innerHTML = '';
  for (const b of state.bases) {
    const opt = document.createElement('option');
    opt.value = b.url;
    opt.textContent = (b.kind === 'tailscale' ? 'Tailscale · ' : b.kind === 'lan' ? '局域网 · ' : '') + b.url;
    sel.appendChild(opt);
  }
  if (state.bases.length === 0) {
    const opt = document.createElement('option');
    opt.value = '';
    opt.textContent = '未检测到可用地址（检查 Tailscale / Wi-Fi）';
    sel.appendChild(opt);
  }
  const found = [...sel.options].some((o) => o.value === prev);
  state.selectedBase = found ? prev : (sel.value || '');
}

function renderQr() {
  const img = document.getElementById('qrImg');
  const empty = document.getElementById('qrEmpty');
  const countdown = document.getElementById('countdown');
  const pairUrl = document.getElementById('pairUrl');
  const webUrl = document.getElementById('webUrl');
  if (!state.code || !state.selectedBase) {
    img.style.display = 'none';
    empty.style.display = 'block';
    countdown.textContent = '';
    pairUrl.textContent = '';
    webUrl.textContent = '';
    return;
  }
  img.src = '/pair/qr.svg?code=' + encodeURIComponent(state.code) + '&base=' + encodeURIComponent(state.selectedBase);
  img.style.display = 'block';
  empty.style.display = 'none';
  pairUrl.textContent = pairPayload(state.selectedBase, state.code);
  webUrl.textContent = '网页版（未装 App 时用）：' + webPayload(state.selectedBase, state.code);
}

function tick() {
  if (!state.code) return;
  const left = Math.max(0, Math.floor((state.expiresAt - Date.now()) / 1000));
  document.getElementById('countdown').textContent = left > 0 ? ('二维码剩余 ' + left + ' 秒，过期自动失效') : '二维码已过期';
  if (left === 0 && state.code) {
    state.code = null;
    renderQr();
  }
}

function renderPending() {
  const box = document.getElementById('pendingList');
  if (!state.pending.length) { box.innerHTML = '<div class="empty">暂无待确认设备</div>'; return; }
  box.innerHTML = '<table><tr><th>设备</th><th>来源 IP</th><th></th></tr>' + state.pending.map((p) =>
    '<tr><td>' + escapeHtml(p.deviceName) + '</td><td>' + escapeHtml(p.ip) + '</td>' +
    '<td style="text-align:right"><button class="primary" onclick="decide(\\'' + p.id + '\\', \\'approve\\')">允许</button> ' +
    '<button class="danger" onclick="decide(\\'' + p.id + '\\', \\'reject\\')">拒绝</button></td></tr>'
  ).join('') + '</table>';
}

function renderDevices() {
  const box = document.getElementById('deviceList');
  if (!state.devices.length) { box.innerHTML = '<div class="empty">暂无已绑定设备</div>'; return; }
  box.innerHTML = '<table><tr><th>设备</th><th>绑定时间</th><th>最近活跃</th><th></th></tr>' + state.devices.map((d) =>
    '<tr><td>' + escapeHtml(d.name) + '</td><td>' + escapeHtml(new Date(d.createdAt).toLocaleString()) + '</td>' +
    '<td>' + escapeHtml(new Date(d.lastSeenAt).toLocaleString()) + '</td>' +
    '<td style="text-align:right"><button class="danger" onclick="revoke(\\'' + d.id + '\\')">吊销</button></td></tr>'
  ).join('') + '</table>';
}

async function refreshState() {
  try {
    const s = await api('/pair/admin/state');
    state.bases = s.bases || [];
    state.pending = s.pending || [];
    state.devices = s.devices || [];
    state.requireApproval = s.requireApproval !== false;
    state.bridgeName = s.bridgeName || '';
    document.getElementById('bridgeDot').className = 'dot';
    document.getElementById('bridgeStatus').textContent = 'bridge 正常';
    document.getElementById('pcBadge').textContent = '电脑: ' + (state.bridgeName || '未知');
    document.getElementById('modeBadge').textContent = '桌面确认: ' + (state.requireApproval ? '开启' : '关闭');
    renderBases();
    renderPending();
    renderDevices();
    if (state.code) renderQr();
  } catch (e) {
    document.getElementById('bridgeDot').className = 'dot off';
    document.getElementById('bridgeStatus').textContent = 'bridge 未连接';
  }
}

async function startPair() {
  const s = await api('/pair/start', { method:'POST', body:'{}' });
  state.code = s.code;
  state.expiresAt = s.expiresAt;
  renderQr();
}

async function decide(id, action) {
  await api('/pair/' + action, { method:'POST', body: JSON.stringify({ id }) });
  await refreshState();
}

async function revoke(deviceId) {
  if (!confirm('确定吊销这台设备？吊销后它需要重新扫码绑定。')) return;
  await api('/pair/revoke', { method:'POST', body: JSON.stringify({ deviceId }) });
  await refreshState();
}

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (c) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}

document.getElementById('startPair').addEventListener('click', startPair);
document.getElementById('refreshBases').addEventListener('click', refreshState);
document.getElementById('copyUrl').addEventListener('click', async () => {
  const text = document.getElementById('pairUrl').textContent;
  if (!text) return;
  try { await navigator.clipboard.writeText(text); } catch (e) {
    window.prompt('复制配对链接:', text);
  }
});
document.getElementById('copyWebUrl').addEventListener('click', async () => {
  const raw = document.getElementById('webUrl').textContent;
  const text = raw.replace(/^网页版（未装 App 时用）：/, '');
  if (!text) return;
  try { await navigator.clipboard.writeText(text); } catch (e) {
    window.prompt('复制网页版链接:', text);
  }
});
document.getElementById('baseSelect').addEventListener('change', (e) => {
  state.selectedBase = e.target.value;
  renderQr();
});

refreshState();
setInterval(refreshState, 2000);
setInterval(tick, 1000);
</script>
</body>
</html>`;
}
