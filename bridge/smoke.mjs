#!/usr/bin/env node
// Smoke test for dsh-remote-bridge.
// Usage: node smoke.mjs
import { readFileSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';
import WebSocket from 'ws';

const configPath = process.env.BRIDGE_CONFIG || resolve(process.cwd(), 'config.json');
if (!existsSync(configPath)) {
  console.error('config.json not found. cp config.example.json config.json first.');
  process.exit(1);
}
const config = JSON.parse(readFileSync(configPath, 'utf8'));
const base = `http://127.0.0.1:${config.port || 8787}`;
const headers = {
  'Content-Type': 'application/json',
  Authorization: `Bearer ${config.token}`,
};

async function post(method, payload) {
  const res = await fetch(`${base}/api/${method}`, {
    method: 'POST',
    headers,
    body: JSON.stringify({
      type: 'client-request',
      rpcId: `smoke-${Date.now()}-${Math.random().toString(16).slice(2)}`,
      method,
      payload,
    }),
  });
  if (res.status === 401) throw new Error('401 unauthorized: check token');
  const json = await res.json();
  if (json.result?.ok !== true) throw new Error(JSON.stringify(json.result?.error));
  return json.result.value;
}

const health = await fetch(`${base}/health`).then((r) => r.json());
console.log('health:', health);

const sessions = await post('session.list', {});
console.log('session.list OK, sessions:', sessions.items?.length ?? 0);

const ws = new WebSocket(`ws://127.0.0.1:${config.port || 8787}/ws/events.mux?token=${encodeURIComponent(config.token)}`);
await new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error('ws timeout')), 5000);
  ws.on('message', (data) => {
    const frame = JSON.parse(data.toString());
    if (frame.type === 'bridge/connected') {
      clearTimeout(timer);
      console.log('ws stream OK');
      ws.close();
      resolve();
    }
  });
  ws.on('error', reject);
});
console.log('smoke test passed');
