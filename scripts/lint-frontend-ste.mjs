#!/usr/bin/env node
/**
 * AgyHigher Frontend STE-STC Architecture & Copy Linter
 * Enforces STE-STC software design discipline across SwiftUI views & Rust user messages:
 * 1. Canonical terminology (forbids non-canonical synonyms like 子 Agent, 产出文件, 屏蔽非 Gemini)
 * 2. Zero conversational filler (请您, 您可以, 点击这里, 小助手)
 * 3. Zero Unicode emojis
 * 4. Zero SwiftUI @State macros (macOS CLT build safety)
 * 5. Zero Capsule() pills (strict 4px-6px desktop geometry)
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');

const EMOJI_RE = /[\p{Extended_Pictographic}]/u;
const FORBIDDEN_TERMS = [
  { term: '子 Agent', canonical: '子代理' },
  { term: '产出文件', canonical: '产物' },
  { term: '屏蔽非 Gemini', canonical: '隐藏非 Gemini' },
  { term: '文件夹下会话', canonical: '项目会话' },
  { term: '请您', canonical: '(删除废话)' },
  { term: '您可以', canonical: '(使用祈使短句)' },
  { term: '点击这里', canonical: '(使用祈使短句)' },
  { term: '小助手', canonical: '代理' }
];

const TARGET_ROOTS = [
  path.join(ROOT, 'macos-app', 'Sources', 'AgyHigherApp'),
  path.join(ROOT, 'rust-core', 'src')
];

let errors = 0;
let checkedFiles = 0;

function walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      walk(full);
      continue;
    }
    if (!/\.(swift|rs)$/.test(entry.name)) continue;
    checkedFiles++;
    const rel = path.relative(ROOT, full);
    const content = fs.readFileSync(full, 'utf8');

    if (EMOJI_RE.test(content)) {
      console.error(`[ERROR] Emoji detected in ${rel}`);
      errors++;
    }
    if (entry.name.endsWith('.swift')) {
      if (/@State\b/.test(content)) {
        console.error(`[ERROR] Forbidden @State macro in ${rel}`);
        errors++;
      }
      if (/\bCapsule\s*\(/.test(content)) {
        console.error(`[ERROR] Forbidden Capsule() pill in ${rel} (use 4px-6px RoundedRectangle)`);
        errors++;
      }
    }
    for (const { term, canonical } of FORBIDDEN_TERMS) {
      if (content.includes(term)) {
        console.error(`[ERROR] Non-canonical STE-STC term "${term}" in ${rel} -> use "${canonical}"`);
        errors++;
      }
    }
  }
}

for (const root of TARGET_ROOTS) walk(root);

if (errors > 0) {
  console.error(`[FAIL] Frontend STE-STC lint failed: ${errors} error(s) across ${checkedFiles} files.`);
  process.exit(1);
}
console.log(`[PASS] Frontend STE-STC lint passed (${checkedFiles} source files, 0 errors).`);
