import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import net from 'node:net';
import os from 'node:os';

export const name = 'dsh-remote';
export const inject = [];

const BRIDGE_PORT_DEFAULT = 8787;
const DEFAULT_ALLOWED_IPS = ['127.0.0.1', '100.64.0.0/10'];
const RESTART_DELAY_MS = 3000;

function bridgeEntry() {
  return fileURLToPath(new URL('./bridge/server.js', import.meta.url));
}

function pluginDataDir() {
  return join(homedir(), '.dsh', 'plugins', 'dsh-remote');
}

function lanAddresses() {
  const out = [];
  for (const addrs of Object.values(os.networkInterfaces())) {
    for (const addr of addrs ?? []) {
      if (addr.internal || addr.family !== 'IPv4') continue;
      const ip = addr.address;
      if (ip.startsWith('169.254.')) continue;
      out.push(ip);
      const m = ip.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/);
      if (m && !ip.startsWith('100.')) {
        // Home Wi-Fi subnets are almost always /24; keep the exact IP too so a
        // different mask still works, and the admin can tighten it later.
        out.push(`${m[1]}.${m[2]}.${m[3]}.0/24`);
      }
    }
  }
  return [...new Set(out)];
}

function ensureConfig() {
  const dir = pluginDataDir();
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const file = join(dir, 'config.json');
  const base = {
    host: '0.0.0.0',
    port: BRIDGE_PORT_DEFAULT,
    dshBaseUrl: 'http://127.0.0.1:3080',
    token: '',
    allowedIps: DEFAULT_ALLOWED_IPS,
    trustProxy: false,
    pairTtlMs: 180000,
    pairPendingTtlMs: 600000,
    pairRequireApproval: true,
    devicesFile: 'devices.json',
    bridgeName: os.hostname(),
    rateLimit: { windowMs: 60000, max: 120 },
  };
  let existing = {};
  if (existsSync(file)) {
    try {
      existing = JSON.parse(readFileSync(file, 'utf8'));
    } catch (err) {
      throw new Error(`dsh-remote: failed to parse ${file}: ${err.message}`);
    }
  }
  const merged = { ...base, ...existing };
  merged.rateLimit = { ...base.rateLimit, ...(existing.rateLimit ?? {}) };
  if (!merged.token || String(merged.token).startsWith('CHANGE_ME')) {
    merged.token = crypto.randomBytes(32).toString('hex');
  }
  // Never persist a broad "allow all" default; always have loopback plus the
  // current Tailscale/LAN addresses so QR pairing works on first launch.
  const allowed = Array.isArray(merged.allowedIps) ? merged.allowedIps : [];
  if (allowed.length === 0) {
    merged.allowedIps = DEFAULT_ALLOWED_IPS;
  }
  const desired = new Set([...merged.allowedIps, ...lanAddresses()]);
  merged.allowedIps = [...desired];
  writeFileSync(file, JSON.stringify(merged, null, 2) + '\n', { mode: 0o600 });
  chmodSync(file, 0o600);
  return { file, config: merged };
}

function portFree(port) {
  return new Promise((resolve) => {
    const socket = net.connect({ port, host: '127.0.0.1' });
    let done = false;
    const finish = (value) => {
      if (done) return;
      done = true;
      socket.destroy();
      resolve(value);
    };
    socket.once('connect', () => finish(false));
    socket.once('error', () => finish(true));
    socket.setTimeout(1500, () => finish(false));
  });
}

async function bridgeAlreadyHealthy(port) {
  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 1500);
    const res = await fetch(`http://127.0.0.1:${port}/health`, { signal: controller.signal });
    clearTimeout(timer);
    if (!res.ok) return false;
    const body = await res.json();
    return body?.service === 'dsh-remote-bridge';
  } catch {
    return false;
  }
}

function apply(ctx) {
  const log = {
    info: (message) => {
      if (ctx.logger?.info) ctx.logger.info(`[dsh-remote] ${message}`);
      else console.log(`[dsh-remote] ${message}`);
    },
    warn: (message) => {
      if (ctx.logger?.warn) ctx.logger.warn(`[dsh-remote] ${message}`);
      else console.warn(`[dsh-remote] ${message}`);
    },
    error: (message) => {
      if (ctx.logger?.error) ctx.logger.error(`[dsh-remote] ${message}`);
      else console.error(`[dsh-remote] ${message}`);
    },
  };

  let { file: configFile, config } = ensureConfig();
  const port = Number(config.port || BRIDGE_PORT_DEFAULT);
  const entry = bridgeEntry();
  const bridgeDir = dirname(entry);

  ctx.effect(() => {
    let stopped = false;
    let child = null;
    let restartTimer = null;
    let ensureTimer = null;
    let lastPortWarnAt = 0;

    const start = () => {
      if (stopped) return;
      log.info(`starting bridge ${entry} on 0.0.0.0:${port}`);
      child = spawn(process.execPath, ['--preserve-symlinks', entry], {
        cwd: bridgeDir,
        env: {
          ...process.env,
          BRIDGE_CONFIG: configFile,
          BRIDGE_PORT: String(port),
        },
        stdio: ['ignore', 'pipe', 'pipe'],
      });
      child.stdout?.on('data', (chunk) => {
        for (const line of chunk.toString().split('\n')) {
          if (line.trim()) log.info(`bridge: ${line.trim()}`);
        }
      });
      child.stderr?.on('data', (chunk) => {
        for (const line of chunk.toString().split('\n')) {
          if (line.trim()) log.error(`bridge: ${line.trim()}`);
        }
      });
      child.on('error', (err) => log.error(`bridge spawn failed: ${err.message}`));
      child.on('exit', (code, signal) => {
        child = null;
        if (stopped) return;
        log.warn(`bridge exited (code=${code}, signal=${signal}); restarting in ${RESTART_DELAY_MS}ms`);
        restartTimer = setTimeout(start, RESTART_DELAY_MS);
        restartTimer.unref?.();
      });
    };

    const ensure = async () => {
      if (stopped || child) return;
      if (await bridgeAlreadyHealthy(port)) return;
      if (!(await portFree(port))) {
        const t = Date.now();
        if (t - lastPortWarnAt > 60_000) {
          lastPortWarnAt = t;
          log.warn(`port ${port} is occupied by something that is not dsh-remote-bridge; waiting for it to free up`);
        }
        return;
      }
      start();
    };

    ensure().catch((err) => log.error(`bridge health check failed: ${err.message}`));
    ensureTimer = setInterval(() => {
      ensure().catch((err) => log.error(`bridge health check failed: ${err.message}`));
    }, 5000);
    ensureTimer.unref?.();

    return () => {
      stopped = true;
      if (restartTimer) clearTimeout(restartTimer);
      if (ensureTimer) clearInterval(ensureTimer);
      child?.kill();
    };
  }, 'dsh-remote: bridge lifecycle');
}

export { apply };
