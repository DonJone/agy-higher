#!/usr/bin/env node
/**
 * AgyHigher Non-Destructive CDP Injector for Antigravity Desktop
 * Inspired by yuexps/Antigravity-Hans:
 *   - NEVER modifies /Applications/Antigravity.app (preserves Apple Hardened Runtime & CodeSignature)
 *   - Strictly binds loopback 127.0.0.1 only
 *   - NEVER touches interactive `agy` CLI processes
 *
 * Commands:
 *   node l10n/tools/cdp-inject.mjs status [--port 9229]
 *   node l10n/tools/cdp-inject.mjs inject --overlay <path> [--port 9229]
 *   node l10n/tools/cdp-inject.mjs disable [--port 9229]
 *   node l10n/tools/cdp-inject.mjs relaunch --overlay <path> [--port 9229]
 */

import fs from 'node:fs';
import { execFileSync, spawn } from 'node:child_process';

const DEFAULT_PORT = 9229;
const PORT_SPAN = 5;
const ANTIGRAVITY_BIN = '/Applications/Antigravity.app/Contents/MacOS/Antigravity';
const IGNORED_TYPES = new Set(['worker', 'service_worker', 'shared_worker', 'background_page']);

function parseArgs(argv) {
  const cmd = argv[0] || 'status';
  const opts = { cmd, port: DEFAULT_PORT, overlay: null };
  for (let i = 1; i < argv.length; i++) {
    if (argv[i] === '--port' && argv[i + 1]) {
      opts.port = Number(argv[++i]) || DEFAULT_PORT;
    } else if (argv[i] === '--overlay' && argv[i + 1]) {
      opts.overlay = argv[++i];
    }
  }
  return opts;
}

function listAntigravityDesktopPids() {
  try {
    const out = execFileSync('ps', ['-axo', 'pid=,command='], { encoding: 'utf8' });
    const hits = [];
    for (const line of out.split('\n')) {
      const m = line.trim().match(/^(\d+)\s+(.*)$/);
      if (!m) continue;
      const pid = Number(m[1]);
      const cmd = m[2];
      // Strictly match ONLY Antigravity.app main binary (never helpers, never agy CLI)
      if (cmd.startsWith(ANTIGRAVITY_BIN)) {
        const portMatch = cmd.match(/--remote-debugging-port=(\d+)/);
        hits.push({ pid, cmd, debugPort: portMatch ? Number(portMatch[1]) : 0 });
      }
    }
    return hits;
  } catch {
    return [];
  }
}

function isInjectableTarget(t) {
  if (!t || IGNORED_TYPES.has(t.type)) return false;
  if (!t.webSocketDebuggerUrl || !t.id) return false;
  try {
    const ws = new URL(t.webSocketDebuggerUrl);
    if (ws.hostname !== '127.0.0.1' && ws.hostname !== 'localhost') return false;
    if (!ws.pathname.startsWith('/devtools/page/')) return false;
  } catch {
    return false;
  }
  const rawUrl = String(t.url || '').toLowerCase();
  if (rawUrl.startsWith('devtools://') || rawUrl.startsWith('chrome-extension://')) {
    return false;
  }
  if (rawUrl.startsWith('data:text/html')) return true;
  if (rawUrl.startsWith('http://127.0.0.1') || rawUrl.startsWith('http://localhost') ||
      rawUrl.startsWith('https://127.0.0.1') || rawUrl.startsWith('https://localhost') ||
      rawUrl.startsWith('file://') || rawUrl.startsWith('vscode-file://')) {
    return true;
  }
  return t.type === 'page' || t.type === 'webview';
}

async function fetchTargetsOnPort(port) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 800);
  try {
    const res = await fetch(`http://127.0.0.1:${port}/json/list`, { signal: controller.signal });
    if (!res.ok) return null;
    const list = await res.json();
    if (!Array.isArray(list)) return null;
    return list.filter(isInjectableTarget);
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

async function discoverActiveCdp(preferredPort) {
  const running = listAntigravityDesktopPids();
  const ports = [];
  for (const p of running) {
    if (p.debugPort > 0 && !ports.includes(p.debugPort)) ports.push(p.debugPort);
  }
  for (let i = 0; i < PORT_SPAN; i++) {
    const cand = preferredPort + i;
    if (!ports.includes(cand)) ports.push(cand);
  }
  for (const port of ports) {
    const targets = await fetchTargetsOnPort(port);
    if (targets !== null) {
      return { port, targets, antigravityRunning: running.length > 0 };
    }
  }
  return { port: 0, targets: [], antigravityRunning: running.length > 0 };
}

function cdpSession(wsUrl, timeoutMs = 4000) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(wsUrl);
    let nextId = 1;
    const pending = new Map();
    const timer = setTimeout(() => {
      try { ws.close(); } catch {}
      reject(new Error('CDP connection timeout'));
    }, timeoutMs);

    ws.addEventListener('open', () => {
      clearTimeout(timer);
      const call = (method, params = {}) =>
        new Promise((res, rej) => {
          const id = nextId++;
          const callTimer = setTimeout(() => {
            pending.delete(id);
            rej(new Error(`CDP ${method} timeout`));
          }, timeoutMs);
          pending.set(id, {
            resolve: (v) => { clearTimeout(callTimer); res(v); },
            reject: (e) => { clearTimeout(callTimer); rej(e); }
          });
          ws.send(JSON.stringify({ id, method, params }));
        });
      resolve({
        call,
        close: () => {
          try { ws.close(); } catch {}
        }
      });
    });

    ws.addEventListener('message', (ev) => {
      try {
        const msg = JSON.parse(String(ev.data));
        if (msg.id && pending.has(msg.id)) {
          const h = pending.get(msg.id);
          pending.delete(msg.id);
          if (msg.error) h.reject(new Error(msg.error.message || 'CDP error'));
          else h.resolve(msg.result || {});
        }
      } catch {}
    });

    ws.addEventListener('error', () => {
      clearTimeout(timer);
      reject(new Error('CDP WebSocket error'));
    });
  });
}

async function checkInjected(target) {
  let sess = null;
  try {
    sess = await cdpSession(target.webSocketDebuggerUrl, 1500);
    const r = await sess.call('Runtime.evaluate', {
      expression: 'Boolean(window.__AGY_HIGHER_STC_OVERLAY_LOADED__)',
      returnByValue: true
    });
    return Boolean(r?.result?.value);
  } catch {
    return false;
  } finally {
    if (sess) sess.close();
  }
}

async function injectTarget(target, overlayCode) {
  let sess = null;
  try {
    sess = await cdpSession(target.webSocketDebuggerUrl, 4500);
    await sess.call('Page.enable').catch(() => {});
    await sess.call('Page.addScriptToEvaluateOnNewDocument', { source: overlayCode }).catch(() => {});
    const evalRes = await sess.call('Runtime.evaluate', {
      expression: overlayCode,
      awaitPromise: false,
      returnByValue: false
    });
    if (evalRes?.exceptionDetails) {
      return { ok: false, error: evalRes.exceptionDetails.text || 'evaluate exception' };
    }
    const verify = await sess.call('Runtime.evaluate', {
      expression: 'Boolean(window.__AGY_HIGHER_STC_OVERLAY_LOADED__)',
      returnByValue: true
    });
    return { ok: Boolean(verify?.result?.value) };
  } catch (e) {
    return { ok: false, error: e.message };
  } finally {
    if (sess) sess.close();
  }
}

async function disableTarget(target) {
  let sess = null;
  try {
    sess = await cdpSession(target.webSocketDebuggerUrl, 2500);
    await sess.call('Runtime.evaluate', {
      expression: `(() => {
        try { window.localStorage.setItem('agy_higher_stc_enabled', '0'); } catch (_e) {}
        if (typeof window.__AGY_HIGHER_STC_CLEANUP__ === 'function') {
          window.__AGY_HIGHER_STC_CLEANUP__();
          return true;
        }
        return false;
      })()`,
      returnByValue: true
    });
    return true;
  } catch {
    return false;
  } finally {
    if (sess) sess.close();
  }
}

async function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));

  if (opts.cmd === 'status') {
    const disc = await discoverActiveCdp(opts.port);
    let injectedCount = 0;
    for (const t of disc.targets) {
      if (await checkInjected(t)) injectedCount++;
    }
    console.log(JSON.stringify({
      ok: true,
      cdpConnected: disc.port > 0,
      cdpPort: disc.port,
      targetCount: disc.targets.length,
      injectedCount,
      antigravityRunning: disc.antigravityRunning
    }));
    return;
  }

  if (opts.cmd === 'disable') {
    const disc = await discoverActiveCdp(opts.port);
    let cleaned = 0;
    for (const t of disc.targets) {
      if (await disableTarget(t)) cleaned++;
    }
    console.log(JSON.stringify({
      ok: true,
      cdpConnected: disc.port > 0,
      cdpPort: disc.port,
      targetCount: disc.targets.length,
      injectedCount: 0,
      cleanedCount: cleaned
    }));
    return;
  }

  if (opts.cmd === 'inject') {
    if (!opts.overlay || !fs.existsSync(opts.overlay)) {
      console.error(JSON.stringify({ ok: false, error: 'Missing overlay script file' }));
      process.exit(1);
    }
    const overlayCode = fs.readFileSync(opts.overlay, 'utf8');
    // Force enabled flag on explicit inject so previous toggle-off doesn't suppress translation
    const wrapped = `try { window.localStorage.setItem('agy_higher_stc_enabled', '1'); } catch (_e) {}\n${overlayCode}`;
    const disc = await discoverActiveCdp(opts.port);
    if (disc.port === 0) {
      console.log(JSON.stringify({
        ok: false,
        cdpConnected: false,
        cdpPort: 0,
        targetCount: 0,
        injectedCount: 0,
        error: '未检测到 Antigravity CDP 调试端口'
      }));
      process.exit(0);
    }
    let injectedCount = 0;
    for (const t of disc.targets) {
      const r = await injectTarget(t, wrapped);
      if (r.ok) injectedCount++;
    }
    console.log(JSON.stringify({
      ok: true,
      cdpConnected: true,
      cdpPort: disc.port,
      targetCount: disc.targets.length,
      injectedCount
    }));
    return;
  }

  if (opts.cmd === 'relaunch') {
    if (!fs.existsSync(ANTIGRAVITY_BIN)) {
      console.error(JSON.stringify({ ok: false, error: '未找到 /Applications/Antigravity.app' }));
      process.exit(1);
    }
    if (!opts.overlay || !fs.existsSync(opts.overlay)) {
      console.error(JSON.stringify({ ok: false, error: '未找到 STE-STC 汉化脚本' }));
      process.exit(1);
    }

    // 1. Gracefully quit ONLY Antigravity.app (never agy CLI!)
    const existing = listAntigravityDesktopPids();
    if (existing.length > 0) {
      try {
        execFileSync('osascript', ['-e', 'tell application "Antigravity" to quit'], {
          stdio: 'ignore',
          timeout: 5000
        });
      } catch {}
      const deadline = Date.now() + 7000;
      while (Date.now() < deadline && listAntigravityDesktopPids().length > 0) {
        await sleep(200);
      }
      // If still hanging after graceful quit, send SIGTERM only to Antigravity.app main PIDs
      for (const p of listAntigravityDesktopPids()) {
        try { process.kill(p.pid, 'SIGTERM'); } catch {}
      }
      const termDeadline = Date.now() + 3000;
      while (Date.now() < termDeadline && listAntigravityDesktopPids().length > 0) {
        await sleep(150);
      }
    }

    // 2. Launch Antigravity.app with loopback-only CDP debugging port
    const child = spawn(
      ANTIGRAVITY_BIN,
      [`--remote-debugging-port=${opts.port}`, '--remote-debugging-address=127.0.0.1'],
      { detached: true, stdio: 'ignore' }
    );
    child.unref();

    // 3. Wait for CDP targets (prefer main UI page to be ready)
    const readyDeadline = Date.now() + 18000;
    let targets = [];
    while (Date.now() < readyDeadline) {
      const list = await fetchTargetsOnPort(opts.port);
      if (list && list.length > 0) {
        targets = list;
        const hasMain = list.some((t) => {
          const u = String(t.url || '').toLowerCase();
          return u.startsWith('http://127.0.0.1') || u.startsWith('http://localhost') || u.includes('workbench');
        });
        if (hasMain) break;
      }
      await sleep(250);
    }

    // Give main renderer a short settle moment, then re-list and inject all targets
    await sleep(600);
    const finalTargets = (await fetchTargetsOnPort(opts.port)) || targets;
    const overlayCode = fs.readFileSync(opts.overlay, 'utf8');
    const wrapped = `try { window.localStorage.setItem('agy_higher_stc_enabled', '1'); } catch (_e) {}\n${overlayCode}`;
    let injectedCount = 0;
    for (const t of finalTargets) {
      const r = await injectTarget(t, wrapped);
      if (r.ok) injectedCount++;
    }

    console.log(JSON.stringify({
      ok: true,
      cdpConnected: finalTargets.length > 0,
      cdpPort: opts.port,
      targetCount: finalTargets.length,
      injectedCount
    }));
    return;
  }

  console.error(JSON.stringify({ ok: false, error: `Unknown command: ${opts.cmd}` }));
  process.exit(1);
}

main().catch((err) => {
  console.error(JSON.stringify({ ok: false, error: err?.message || String(err) }));
  process.exit(1);
});
