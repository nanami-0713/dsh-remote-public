#!/usr/bin/env node
// Self-contained test for bridge notify.push fan-out. Does NOT need a real DSH:
// a fake DSH WebSocket server stands in for the upstream event stream.
// Usage: node test_notify.mjs
import { spawn } from 'node:child_process';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import crypto from 'node:crypto';
import { WebSocketServer, WebSocket } from 'ws';

const here = dirname(fileURLToPath(import.meta.url));
const BRIDGE_PORT = 8799;
const FAKE_DSH_PORT = 8798;
const MASTER = crypto.randomBytes(16).toString('hex');
const DEVICE_TOKEN = 'device-token-' + crypto.randomBytes(8).toString('hex');

const dir = mkdtempSync(join(tmpdir(), 'dsh-bridge-notify-'));
const configFile = join(dir, 'config.json');
const hash = (t) => crypto.createHash('sha256').update(String(t)).digest('hex');
writeFileSync(configFile, JSON.stringify({
  host: '127.0.0.1',
  port: BRIDGE_PORT,
  dshBaseUrl: `http://127.0.0.1:${FAKE_DSH_PORT}`,
  token: MASTER,
  allowedIps: ['127.0.0.1'],
  devicesFile: 'devices.json',
  bridgeName: 'notify-test',
}, null, 2));
writeFileSync(join(dir, 'devices.json'), JSON.stringify({ version: 1, devices: [
  { id: 'dev-1', name: 'test-phone', tokenHash: hash(DEVICE_TOKEN), ip: '127.0.0.1', createdAt: Date.now(), lastSeenAt: Date.now() },
] }));

const fakeDsh = new WebSocketServer({ port: FAKE_DSH_PORT });
fakeDsh.on('connection', (ws) => {
  // Accept the upstream pipe and keep it open; no frames needed for this test.
  ws.on('error', () => {});
});

const child = spawn(process.execPath, ['server.js'], {
  cwd: here,
  env: { ...process.env, BRIDGE_CONFIG: configFile },
  stdio: ['ignore', 'inherit', 'inherit'],
});

const base = `http://127.0.0.1:${BRIDGE_PORT}`;
let failed = false;
const fail = (message) => {
  failed = true;
  console.error('FAIL:', message);
};

async function waitHealth() {
  for (let i = 0; i < 50; i += 1) {
    try {
      const res = await fetch(`${base}/health`);
      if (res.ok) return true;
    } catch {
      /* not up yet */
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  return false;
}

function waitFrame(ws, type, timeoutMs = 5000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      ws.off('message', onMessage);
      reject(new Error(`timeout waiting for ${type}`));
    }, timeoutMs);
    const onMessage = (data) => {
      let frame;
      try {
        frame = JSON.parse(data.toString());
      } catch {
        return;
      }
      if (frame.type === type) {
        clearTimeout(timer);
        ws.off('message', onMessage);
        resolve(frame);
      }
    };
    ws.on('message', onMessage);
  });
}

async function postNotify(token, body) {
  return fetch(`${base}/api/notify.push`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    body: JSON.stringify(body),
  });
}

try {
  if (!(await waitHealth())) {
    fail('bridge did not become healthy');
  } else {
    const ws = new WebSocket(`ws://127.0.0.1:${BRIDGE_PORT}/ws/events.mux?token=${encodeURIComponent(MASTER)}`);
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('ws connect timeout')), 5000);
      ws.on('open', () => {
        clearTimeout(timer);
        resolve();
      });
      ws.on('error', reject);
    });

    // 1. Master push reaches the connected phone socket.
    const framePromise = waitFrame(ws, 'bridge/notify');
    const res = await postNotify(MASTER, { kind: 'done', title: 'DSH 任务完成', message: '会话已运行结束', sessionId: 'sess-123' });
    const json = await res.json();
    if (res.status !== 200 || json.delivered !== 1) {
      fail(`master push expected 200 delivered=1, got ${res.status} ${JSON.stringify(json)}`);
    }
    const frame = await framePromise;
    const payload = frame.payload ?? {};
    if (payload.kind !== 'done' || payload.title !== 'DSH 任务完成' || payload.sessionId !== 'sess-123' || !payload.at) {
      fail(`bridge/notify payload mismatch: ${JSON.stringify(payload)}`);
    } else {
      console.log('PASS master push → bridge/notify frame delivered (kind=done, sessionId carried)');
    }

    // 2. Device tokens may receive but never push.
    const resDevice = await postNotify(DEVICE_TOKEN, { kind: 'done', title: 'x', message: 'y' });
    if (resDevice.status !== 403) fail(`device token push expected 403, got ${resDevice.status}`);
    else console.log('PASS device token push rejected (403)');

    // 3. Anonymous push is rejected at auth.
    const resNone = await postNotify('', { kind: 'done', title: 'x', message: 'y' });
    if (resNone.status !== 401) fail(`anonymous push expected 401, got ${resNone.status}`);
    else console.log('PASS anonymous push rejected (401)');

    // 4. Unknown kind is a 400.
    const resKind = await postNotify(MASTER, { kind: 'nope', title: 'x', message: 'y' });
    if (resKind.status !== 400) fail(`bad kind expected 400, got ${resKind.status}`);
    else console.log('PASS invalid kind rejected (400)');

    // 5. With no connected phone, push still succeeds but delivers 0.
    ws.close();
    await new Promise((resolve) => setTimeout(resolve, 300));
    const resIdle = await postNotify(MASTER, { kind: 'done', title: 'x', message: 'y' });
    const jsonIdle = await resIdle.json();
    if (jsonIdle.delivered !== 0) fail(`expected delivered=0 with no clients, got ${JSON.stringify(jsonIdle)}`);
    else console.log('PASS push with no connected phone → delivered=0');

    console.log('notify.push tests passed');
  }
} catch (err) {
  fail(err.message);
} finally {
  child.kill();
  fakeDsh.close();
  rmSync(dir, { recursive: true, force: true });
  process.exit(failed ? 1 : 0);
}
