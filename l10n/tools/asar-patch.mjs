#!/usr/bin/env node
/**
 * AgyHigher Direct ASAR Patcher for Antigravity Desktop
 *
 * Patches /Applications/Antigravity.app/Contents/Resources/app.asar (dist/main.js)
 * with a minimal, dynamic STE-STC loader hook:
 *   - No special launch mode / no --remote-debugging-port needed
 *   - Works on normal Dock / Spotlight / Finder launches
 *   - Watches ~/.config/agy-higher/config.json and ~/.config/agy-higher/l10n/antigravity-stc-overlay.js
 *     so toggling Chinese localization or updating dictionaries applies LIVE with zero restart
 *   - Saves a byte-exact untouched backup in ~/.config/agy-higher/backups/app.asar.<version>.orig
 *   - 100% reversible via `uninstall`
 *
 * Usage:
 *   node l10n/tools/asar-patch.mjs status [--asar <path>] [--backup-dir <dir>]
 *   node l10n/tools/asar-patch.mjs install [--asar <path>] [--backup-dir <dir>] [--version <ver>]
 *   node l10n/tools/asar-patch.mjs uninstall [--asar <path>] [--backup-dir <dir>] [--version <ver>]
 */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

export const DEFAULT_ASAR_PATH = '/Applications/Antigravity.app/Contents/Resources/app.asar';
export const DEFAULT_BACKUP_DIR = path.join(os.homedir(), '.config', 'agy-higher', 'backups');
export const PATCH_MARKER_START = '// === AGY_HIGHER_STC_PATCH_START ===';
export const PATCH_MARKER_END = '// === AGY_HIGHER_STC_PATCH_END ===';
export const PATCH_SCHEMA_VERSION = 'v2-main-watch';

const MAIN_HOOK_SNIPPET = `
${PATCH_MARKER_START}
// AgyHigher STE-STC Main Process Loader (${PATCH_SCHEMA_VERSION})
(() => {
  try {
    const _fs = require('fs');
    const _os = require('os');
    const _path = require('path');
    const { app: _app, webContents: _webContents } = require('electron');
    const _cfgDir = _path.join(_os.homedir(), '.config', 'agy-higher');
    const _cfgPath = _path.join(_cfgDir, 'config.json');
    const _ovDir = _path.join(_cfgDir, 'l10n');
    const _ovPath = _path.join(_ovDir, 'antigravity-stc-overlay.js');

    const _readEnabled = () => {
      try {
        if (!_fs.existsSync(_cfgPath)) return false;
        const cfg = JSON.parse(_fs.readFileSync(_cfgPath, 'utf8'));
        return Boolean(cfg && cfg.l10nEnabled);
      } catch (_) {
        return false;
      }
    };

    const _applyToWebContents = (wc) => {
      try {
        if (!wc || wc.isDestroyed()) return;
        const url = String(wc.getURL() || '').toLowerCase();
        if (!url || url.startsWith('devtools://') || url.startsWith('chrome-extension://')) return;
        if (!_readEnabled()) {
          wc.executeJavaScript(
            "try{window.localStorage.setItem('agy_higher_stc_enabled','0')}catch(_){};if(typeof window.__AGY_HIGHER_STC_CLEANUP__==='function'){window.__AGY_HIGHER_STC_CLEANUP__();}"
          ).catch(() => {});
          return;
        }
        if (!_fs.existsSync(_ovPath)) return;
        const code = _fs.readFileSync(_ovPath, 'utf8');
        wc.executeJavaScript(
          "try{window.localStorage.setItem('agy_higher_stc_enabled','1')}catch(_){}\n" + code
        ).catch(() => {});
      } catch (_) {}
    };

    const _attachWc = (wc) => {
      if (!wc || wc.__agyHigherStcHooked) return;
      wc.__agyHigherStcHooked = true;
      wc.on('dom-ready', () => _applyToWebContents(wc));
      wc.on('did-finish-load', () => _applyToWebContents(wc));
      wc.on('did-navigate', () => _applyToWebContents(wc));
      wc.on('did-navigate-in-page', () => setTimeout(() => _applyToWebContents(wc), 120));
      if (!wc.isLoading()) _applyToWebContents(wc);
    };

    _app.on('web-contents-created', (_ev, wc) => _attachWc(wc));

    let _broadcastTimer = null;
    const _broadcast = () => {
      try {
        for (const wc of _webContents.getAllWebContents()) {
          _applyToWebContents(wc);
        }
      } catch (_) {}
    };
    const _scheduleBroadcast = () => {
      if (_broadcastTimer) clearTimeout(_broadcastTimer);
      _broadcastTimer = setTimeout(_broadcast, 150);
    };

    const _watchFile = (dir, targetName) => {
      try {
        if (_fs.existsSync(dir)) {
          _fs.watch(dir, (_ev, fn) => {
            if (!fn || fn === targetName) _scheduleBroadcast();
          });
        }
      } catch (_) {}
    };
    _watchFile(_cfgDir, 'config.json');
    _watchFile(_ovDir, 'antigravity-stc-overlay.js');
  } catch (_) {}
})();
${PATCH_MARKER_END}
`;

export function parseAsar(asarPath) {
  const buf = fs.readFileSync(asarPath);
  if (buf.length < 16) {
    throw new Error('Invalid ASAR archive: file too small');
  }
  const headerSize = buf.readUInt32LE(4);
  const jsonLen = buf.readUInt32LE(12);
  const headerEnd = 8 + headerSize;
  if (headerEnd > buf.length || 16 + jsonLen > headerEnd) {
    throw new Error('Invalid ASAR header bounds');
  }
  const tree = JSON.parse(buf.subarray(16, 16 + jsonLen).toString('utf8'));
  const payload = buf.subarray(headerEnd);
  return { tree, payload, rawBuf: buf };
}

function getAsarEntry(tree, relPath) {
  let cur = tree;
  for (const part of relPath.split('/')) {
    if (!cur || !cur.files || !cur.files[part]) return null;
    cur = cur.files[part];
  }
  return cur;
}

function computeIntegrity(contentBuf, blockSize = 4 * 1024 * 1024) {
  const hash = crypto.createHash('sha256').update(contentBuf).digest('hex');
  const blocks = [];
  if (contentBuf.length === 0) {
    blocks.push(hash);
  } else {
    for (let offset = 0; offset < contentBuf.length; offset += blockSize) {
      const slice = contentBuf.subarray(offset, Math.min(offset + blockSize, contentBuf.length));
      blocks.push(crypto.createHash('sha256').update(slice).digest('hex'));
    }
  }
  return { algorithm: 'SHA256', hash, blockSize, blocks };
}

function serializeAsarHeader(tree) {
  const jsonBuf = Buffer.from(JSON.stringify(tree), 'utf8');
  const jsonLen = jsonBuf.length;
  const pad = (4 - (jsonLen % 4)) % 4;
  const paddedJsonLen = jsonLen + pad;
  const stringPickleSize = 4 + paddedJsonLen;
  const headerSize = 4 + stringPickleSize;

  const hdr = Buffer.alloc(16 + paddedJsonLen, 0);
  hdr.writeUInt32LE(4, 0);
  hdr.writeUInt32LE(headerSize, 4);
  hdr.writeUInt32LE(stringPickleSize, 8);
  hdr.writeUInt32LE(jsonLen, 12);
  jsonBuf.copy(hdr, 16);
  return hdr;
}

export function inspectAsarPatchStatus(asarPath, backupDir, version = '2.35.0') {
  if (!fs.existsSync(asarPath)) {
    return {
      ok: true,
      asarExists: false,
      patched: false,
      patchVersion: '',
      backupExists: false,
      backupPath: ''
    };
  }
  const { tree, payload } = parseAsar(asarPath);
  const entry = getAsarEntry(tree, 'dist/main.js');
  if (!entry || entry.unpacked) {
    return {
      ok: false,
      asarExists: true,
      patched: false,
      patchVersion: '',
      backupExists: false,
      backupPath: '',
      error: 'dist/main.js not found in app.asar'
    };
  }
  const offset = Number(entry.offset);
  const mainContent = payload.subarray(offset, offset + entry.size).toString('utf8');
  const patched =
    mainContent.includes(PATCH_MARKER_START) && mainContent.includes(PATCH_MARKER_END);
  const verMatch = mainContent.match(/AgyHigher STE-STC Main Process Loader \(([^)]+)\)/);
  const backupPath = findBackupPath(backupDir, version);
  return {
    ok: true,
    asarExists: true,
    patched,
    patchVersion: verMatch ? verMatch[1] : patched ? 'unknown' : '',
    backupExists: Boolean(backupPath),
    backupPath: backupPath || path.join(backupDir, `app.asar.${sanitizeVersion(version)}.orig`)
  };
}

function sanitizeVersion(v) {
  return String(v || 'unknown').replace(/[^a-zA-Z0-9._-]/g, '_');
}

function findBackupPath(backupDir, version) {
  const exact = path.join(backupDir, `app.asar.${sanitizeVersion(version)}.orig`);
  if (fs.existsSync(exact)) return exact;
  if (fs.existsSync(backupDir)) {
    const candidates = fs
      .readdirSync(backupDir)
      .filter((f) => f.startsWith('app.asar.') && f.endsWith('.orig'))
      .sort()
      .reverse();
    if (candidates.length > 0) return path.join(backupDir, candidates[0]);
  }
  return null;
}

function stripExistingPatch(src) {
  const startIdx = src.indexOf(PATCH_MARKER_START);
  const endIdx = src.indexOf(PATCH_MARKER_END);
  if (startIdx !== -1 && endIdx !== -1 && endIdx > startIdx) {
    return (
      src.slice(0, startIdx).trimEnd() +
      '\n' +
      src.slice(endIdx + PATCH_MARKER_END.length).trimStart()
    ).trimEnd() + '\n';
  }
  return src;
}

export function installAsarPatch(asarPath, backupDir, version = '2.35.0') {
  if (!fs.existsSync(asarPath)) {
    throw new Error(`未找到 app.asar: ${asarPath}`);
  }
  fs.mkdirSync(backupDir, { recursive: true });
  const exactBackup = path.join(backupDir, `app.asar.${sanitizeVersion(version)}.orig`);

  const { tree, payload } = parseAsar(asarPath);
  const entry = getAsarEntry(tree, 'dist/main.js');
  if (!entry || entry.unpacked) {
    throw new Error('未能在 app.asar 中定位 dist/main.js');
  }

  const origOffset = Number(entry.offset);
  const currentMain = payload.subarray(origOffset, origOffset + entry.size).toString('utf8');
  const alreadyPatched = currentMain.includes(PATCH_MARKER_START);

  // Save byte-exact original backup strictly BEFORE patching
  if (!alreadyPatched && !fs.existsSync(exactBackup)) {
    fs.copyFileSync(asarPath, exactBackup);
  }

  // Always patch cleanly from original untouched backup if available (avoids payload bloat on re-patch)
  const baseAsarPath = alreadyPatched && fs.existsSync(exactBackup) ? exactBackup : asarPath;
  const base = parseAsar(baseAsarPath);
  const baseEntry = getAsarEntry(base.tree, 'dist/main.js');
  const baseOffset = Number(baseEntry.offset);
  const baseMain = stripExistingPatch(
    base.payload.subarray(baseOffset, baseOffset + baseEntry.size).toString('utf8')
  );

  const patchedMainBuf = Buffer.from(baseMain.trimEnd() + '\n' + MAIN_HOOK_SNIPPET, 'utf8');
  const newOffset = base.payload.length;
  baseEntry.offset = String(newOffset);
  baseEntry.size = patchedMainBuf.length;
  baseEntry.integrity = computeIntegrity(
    patchedMainBuf,
    baseEntry.integrity?.blockSize || 4 * 1024 * 1024
  );

  const newHeader = serializeAsarHeader(base.tree);
  const outBuf = Buffer.concat([newHeader, base.payload, patchedMainBuf]);

  // Atomic replace in same directory
  const tmpPath = `${asarPath}.agy-higher.tmp.${process.pid}`;
  try {
    fs.writeFileSync(tmpPath, outBuf, { mode: 0o644 });
    fs.renameSync(tmpPath, asarPath);
  } catch (err) {
    try {
      if (fs.existsSync(tmpPath)) fs.unlinkSync(tmpPath);
    } catch {}
    throw err;
  }

  const verify = inspectAsarPatchStatus(asarPath, backupDir, version);
  if (!verify.patched) {
    throw new Error('补丁写入后校验失败');
  }
  return {
    ok: true,
    patched: true,
    patchVersion: verify.patchVersion,
    backupPath: exactBackup,
    alreadyPatched
  };
}

export function uninstallAsarPatch(asarPath, backupDir, version = '2.35.0') {
  if (!fs.existsSync(asarPath)) {
    throw new Error(`未找到 app.asar: ${asarPath}`);
  }
  const backupPath = findBackupPath(backupDir, version);
  if (backupPath && fs.existsSync(backupPath)) {
    const tmpPath = `${asarPath}.agy-higher.restore.${process.pid}`;
    try {
      fs.copyFileSync(backupPath, tmpPath);
      fs.chmodSync(tmpPath, 0o644);
      fs.renameSync(tmpPath, asarPath);
    } catch (err) {
      try {
        if (fs.existsSync(tmpPath)) fs.unlinkSync(tmpPath);
      } catch {}
      throw err;
    }
    return { ok: true, patched: false, restoredFromBackup: true, backupPath };
  }

  // Fallback: strip marker cleanly if backup was manually removed
  const status = inspectAsarPatchStatus(asarPath, backupDir, version);
  if (!status.patched) {
    return { ok: true, patched: false, restoredFromBackup: false };
  }
  const { tree, payload } = parseAsar(asarPath);
  const entry = getAsarEntry(tree, 'dist/main.js');
  const origOffset = Number(entry.offset);
  const curMain = payload.subarray(origOffset, origOffset + entry.size).toString('utf8');
  const cleanedBuf = Buffer.from(stripExistingPatch(curMain), 'utf8');
  entry.offset = String(payload.length);
  entry.size = cleanedBuf.length;
  entry.integrity = computeIntegrity(cleanedBuf, entry.integrity?.blockSize || 4 * 1024 * 1024);

  const outBuf = Buffer.concat([serializeAsarHeader(tree), payload, cleanedBuf]);
  const tmpPath = `${asarPath}.agy-higher.restore.${process.pid}`;
  fs.writeFileSync(tmpPath, outBuf, { mode: 0o644 });
  fs.renameSync(tmpPath, asarPath);
  return { ok: true, patched: false, restoredFromBackup: false };
}

function parseCliArgs(argv) {
  const opts = {
    cmd: argv[0] || 'status',
    asar: DEFAULT_ASAR_PATH,
    backupDir: DEFAULT_BACKUP_DIR,
    version: '2.35.0'
  };
  for (let i = 1; i < argv.length; i++) {
    if (argv[i] === '--asar' && argv[i + 1]) opts.asar = argv[++i];
    else if (argv[i] === '--backup-dir' && argv[i + 1]) opts.backupDir = argv[++i];
    else if (argv[i] === '--version' && argv[i + 1]) opts.version = argv[++i];
  }
  return opts;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const opts = parseCliArgs(process.argv.slice(2));
  try {
    let result;
    if (opts.cmd === 'status') {
      result = inspectAsarPatchStatus(opts.asar, opts.backupDir, opts.version);
    } else if (opts.cmd === 'install') {
      result = installAsarPatch(opts.asar, opts.backupDir, opts.version);
    } else if (opts.cmd === 'uninstall') {
      result = uninstallAsarPatch(opts.asar, opts.backupDir, opts.version);
    } else {
      throw new Error(`Unknown command: ${opts.cmd}`);
    }
    console.log(JSON.stringify(result));
  } catch (err) {
    console.error(JSON.stringify({ ok: false, error: err?.message || String(err) }));
    process.exit(1);
  }
}
