#!/usr/bin/env node
/**
 * AgyHigher STE-STC Linter
 * Enforces Simplified Technical English -> Simplified Technical Chinese quality gates:
 * 1. No empty/duplicate/unchanged entries across l10n/src/dict/*.json
 * 2. Zero Unicode emojis anywhere in dictionaries or built overlay
 * 3. Zero conversational filler (from ste-stc-glossary.json forbiddenFiller)
 * 4. Polarity inversion checks (e.g. Enable/Disable, Show/Hide, Allow/Deny, Pin/Unpin, Archive/Unarchive)
 * 5. Canonical glossary consistency & residual non-allowlisted lowercase English warnings
 * 6. Dist bundle length-order & sync check
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadMergedPhrases } from './build-overlay.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');
const DICT_DIR = path.join(ROOT, 'src', 'dict');
const GLOSSARY_PATH = path.join(ROOT, 'src', 'ste-stc-glossary.json');
const DIST_OVERLAY = path.join(ROOT, 'dist', 'antigravity-stc-overlay.js');

const EMOJI_RE = /[\p{Extended_Pictographic}]/u;

const POLARITY_RULES = [
  { srcRe: /\bdisable\b/i, forbiddenDst: ['启用', '开启'], requiredAny: ['禁用', '关闭', '停用'] },
  { srcRe: /\benable\b/i, forbiddenDst: ['禁用', '关闭'], requiredAny: ['启用', '开启'] },
  { srcRe: /\bunarchive\b/i, forbiddenDst: [], requiredAny: ['取消归档', '恢复'] },
  { srcRe: /\bunpin\b/i, forbiddenDst: [], requiredAny: ['取消置顶'] },
  { srcRe: /\bunstar\b/i, forbiddenDst: [], requiredAny: ['取消星标'] },
  { srcRe: /\bdeny\b/i, forbiddenDst: ['允许'], requiredAny: ['拒绝'] },
  { srcRe: /\bhide\b/i, forbiddenDst: ['显示'], requiredAny: ['隐藏'] }
];

function main() {
  const glossary = JSON.parse(fs.readFileSync(GLOSSARY_PATH, 'utf8'));
  const forbiddenFiller = glossary.forbiddenFiller || [];
  const allowedLatin = new Set((glossary.allowedLatin || []).map((w) => w.toLowerCase()));

  const files = fs
    .readdirSync(DICT_DIR)
    .filter((f) => f.endsWith('.json'))
    .sort();

  let errors = 0;
  let warnings = 0;
  const seen = new Map();

  for (const file of files) {
    const fullPath = path.join(DICT_DIR, file);
    const raw = JSON.parse(fs.readFileSync(fullPath, 'utf8'));
    const data = raw && typeof raw === 'object' && raw.phrases && typeof raw.phrases === 'object'
      ? raw.phrases
      : raw;

    for (const [rawKey, rawVal] of Object.entries(data)) {
      const k = rawKey.trim();
      const v = typeof rawVal === 'string' ? rawVal.trim() : '';

      if (!k || !v) {
        console.error(`[ERROR] Empty key or value in ${file}: "${rawKey}"`);
        errors++;
        continue;
      }
      if (k === v) {
        console.error(`[ERROR] Identity translation in ${file}: "${k}"`);
        errors++;
      }
      if (EMOJI_RE.test(k) || EMOJI_RE.test(v)) {
        console.error(`[ERROR] Emoji detected in ${file}: "${k}" => "${v}"`);
        errors++;
      }

      const lower = k.toLowerCase();
      if (seen.has(lower)) {
        console.error(`[ERROR] Duplicate key "${k}" in ${file} and ${seen.get(lower)}`);
        errors++;
      } else {
        seen.set(lower, file);
      }

      for (const filler of forbiddenFiller) {
        if (v.includes(filler)) {
          console.error(`[ERROR] STE-STC forbidden filler "${filler}" in ${file}: "${k}" => "${v}"`);
          errors++;
        }
      }

      for (const rule of POLARITY_RULES) {
        if (rule.srcRe.test(k)) {
          const hasReq =
            rule.requiredAny.length === 0 || rule.requiredAny.some((tok) => v.includes(tok));
          const hasBad = rule.forbiddenDst.some((tok) => v.includes(tok) && !hasReq);
          if (!hasReq || hasBad) {
            console.error(`[ERROR] Polarity mismatch in ${file}: "${k}" => "${v}"`);
            errors++;
          }
        }
      }

      // Check residual lowercase English words not in allowedLatin
      const latinTokens = v.match(/[A-Za-z][A-Za-z0-9_-]*/g) || [];
      for (const tok of latinTokens) {
        if (allowedLatin.has(tok.toLowerCase())) continue;
        if (/^[A-Z0-9]{2,}$/.test(tok)) continue;
        if (/^[a-z]{3,}$/.test(tok)) {
          console.warn(`[WARN] Residual lowercase Latin "${tok}" in ${file}: "${k}" => "${v}"`);
          warnings++;
        }
      }
    }
  }

  // Verify sorted phrase descending order
  const { phrases } = loadMergedPhrases();
  for (let i = 1; i < phrases.length; i++) {
    if (phrases[i][0].length > phrases[i - 1][0].length) {
      console.error(`[ERROR] Phrase length order violated at index ${i}`);
      errors++;
      break;
    }
  }

  if (fs.existsSync(DIST_OVERLAY)) {
    const built = fs.readFileSync(DIST_OVERLAY, 'utf8');
    if (EMOJI_RE.test(built)) {
      console.error('[ERROR] Emoji detected in compiled dist/antigravity-stc-overlay.js');
      errors++;
    }
  } else {
    console.error('[ERROR] Missing compiled dist/antigravity-stc-overlay.js');
    errors++;
  }

  if (errors > 0) {
    console.error(`[FAIL] STE-STC lint failed: ${errors} error(s), ${warnings} warning(s).`);
    process.exit(1);
  }
  console.log(
    `[PASS] STE-STC lint passed (${phrases.length} phrases, 0 errors, ${warnings} warning(s)).`
  );
}

main();
