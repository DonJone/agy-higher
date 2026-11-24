#!/usr/bin/env node
/**
 * Upstream Dictionary Harvester & STE-STC Normalizer
 * Pulls Antigravity UI phrase coverage from yuexps/Antigravity-Hans (common/chat-agent/settings)
 * and normalizes every entry strictly into AgyHigher's STE-STC standard:
 *   - Hand-crafted local STE-STC entries ALWAYS keep highest priority
 *   - Strips emojis & conversational filler
 *   - Normalizes non-canonical terms to ste-stc-glossary.json canonical terminology
 *   - Skips polarity-violating or identity entries
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');
const DICT_DIR = path.join(ROOT, 'src', 'dict');
const GLOSSARY_PATH = path.join(ROOT, 'src', 'ste-stc-glossary.json');

const EMOJI_RE = /[\p{Extended_Pictographic}]/u;

const SOURCES = [
  {
    url: 'https://raw.githubusercontent.com/yuexps/Antigravity-Hans/main/resources/src/dict/common.json',
    localFile: 'common.json'
  },
  {
    url: 'https://raw.githubusercontent.com/yuexps/Antigravity-Hans/main/resources/src/dict/chat-agent.json',
    localFile: 'chat-agent.json'
  },
  {
    url: 'https://raw.githubusercontent.com/yuexps/Antigravity-Hans/main/resources/src/dict/settings.json',
    localFile: 'settings-quota.json'
  }
];

const STE_STC_REPLACEMENTS = [
  [/请您/g, ''],
  [/您可以点击/g, '点击'],
  [/点击这里/g, '点击此处'],
  [/欢迎使用/g, ''],
  [/非常抱歉/g, '抱歉'],
  [/小助手/g, '代理'],
  [/贴心/g, ''],
  [/智能体/g, '代理'],
  [/工作空间/g, '工作区'],
  [/工件/g, '产物'],
  [/思考力度/g, '推理强度'],
  [/思维力度/g, '推理强度'],
  [/子智能体/g, '子代理'],
  [/子任务代理/g, '子代理'],
  [/[!！]{2,}/g, '。']
];

const POLARITY_RULES = [
  { srcRe: /\bdisable\b/i, forbiddenDst: ['启用', '开启'], requiredAny: ['禁用', '关闭', '停用'] },
  { srcRe: /\benable\b/i, forbiddenDst: ['禁用', '关闭'], requiredAny: ['启用', '开启'] },
  { srcRe: /\bunarchive\b/i, forbiddenDst: [], requiredAny: ['取消归档', '恢复'] },
  { srcRe: /\bunpin\b/i, forbiddenDst: [], requiredAny: ['取消置顶'] },
  { srcRe: /\bunstar\b/i, forbiddenDst: [], requiredAny: ['取消星标'] },
  { srcRe: /\bdeny\b/i, forbiddenDst: ['允许'], requiredAny: ['拒绝'] },
  { srcRe: /\bhide\b/i, forbiddenDst: ['显示'], requiredAny: ['隐藏'] }
];

// Extra v2.35.0 strings directly observed on live Antigravity Desktop UI
const EXTRA_V235_PHRASES = {
  'common.json': {
    'Application': '应用程序',
    'Shortcuts': '快捷键',
    'Not in Project': '未归属项目',
    'Conversations': '对话',
    'This Computer': '本机',
    'Email': '邮箱',
    'Terms of Service': '服务条款',
    'Privacy Policy': '隐私政策',
    'Interface Layout': '界面布局',
    'Knowledge Work': '知识协作',
    'Software Engineering': '软件工程',
    'Marketing emails': '营销邮件',
    'Enable telemetry': '启用遥测',
    'Disable telemetry': '禁用遥测'
  },
  'chat-agent.json': {
    'Ask anything': '输入问题',
    'New chat': '新建对话',
    'What\'s next?': '接下来要做什么？'
  },
  'settings-quota.json': {
    'Usage & Quota': '用量与额度',
    'Account & Billing': '账户与账单',
    'Your plan': '当前套餐'
  }
};

function normalizeSteStc(val) {
  let out = String(val || '').replace(EMOJI_RE, '').trim();
  for (const [re, rep] of STE_STC_REPLACEMENTS) {
    out = out.replace(re, rep);
  }
  return out.replace(/\s{2,}/g, ' ').trim();
}

function violatesPolarity(src, dst) {
  for (const rule of POLARITY_RULES) {
    if (rule.srcRe.test(src)) {
      const hasReq =
        rule.requiredAny.length === 0 || rule.requiredAny.some((tok) => dst.includes(tok));
      const hasBad = rule.forbiddenDst.some((tok) => dst.includes(tok) && !hasReq);
      if (!hasReq || hasBad) return true;
    }
  }
  return false;
}

async function main() {
  const glossary = JSON.parse(fs.readFileSync(GLOSSARY_PATH, 'utf8'));
  const forbidden = glossary.forbiddenFiller || [];

  const localDocs = {};
  const globalSeenLower = new Set();

  // Load existing local hand-crafted STE-STC entries first (highest priority!)
  for (const src of SOURCES) {
    const fullPath = path.join(DICT_DIR, src.localFile);
    const doc = JSON.parse(fs.readFileSync(fullPath, 'utf8'));
    localDocs[src.localFile] = { fullPath, doc };
    for (const k of Object.keys(doc.phrases)) {
      globalSeenLower.add(k.trim().toLowerCase());
    }
  }

  // Merge extra v2.35.0 live-observed phrases first
  for (const [file, map] of Object.entries(EXTRA_V235_PHRASES)) {
    const target = localDocs[file];
    for (const [k, v] of Object.entries(map)) {
      const lower = k.trim().toLowerCase();
      if (!globalSeenLower.has(lower)) {
        target.doc.phrases[k.trim()] = v.trim();
        globalSeenLower.add(lower);
      }
    }
  }

  let added = 0;
  let skipped = 0;

  for (const src of SOURCES) {
    const res = await fetch(src.url);
    if (!res.ok) throw new Error(`Failed to fetch ${src.url}: ${res.status}`);
    const upstream = await res.json();
    const target = localDocs[src.localFile];

    for (const [rawKey, rawVal] of Object.entries(upstream)) {
      const k = rawKey.trim();
      if (!k || k.length < 2 || EMOJI_RE.test(k)) {
        skipped++;
        continue;
      }
      const lower = k.toLowerCase();
      if (globalSeenLower.has(lower)) continue;

      const v = normalizeSteStc(rawVal);
      if (!v || v === k || EMOJI_RE.test(v)) {
        skipped++;
        continue;
      }
      if (forbidden.some((w) => v.includes(w))) {
        skipped++;
        continue;
      }
      if (violatesPolarity(k, v)) {
        skipped++;
        continue;
      }

      target.doc.phrases[k] = v;
      globalSeenLower.add(lower);
      added++;
    }
  }

  // Write deterministically sorted JSON files
  for (const { fullPath, doc } of Object.values(localDocs)) {
    const sorted = Object.entries(doc.phrases).sort((a, b) => {
      if (b[0].length !== a[0].length) return b[0].length - a[0].length;
      return a[0].localeCompare(b[0], 'en');
    });
    doc.phrases = Object.fromEntries(sorted);
    fs.writeFileSync(fullPath, JSON.stringify(doc, null, 2) + '\n', 'utf8');
  }

  console.log(`[SYNC] Added ${added} STE-STC normalized phrases (skipped ${skipped}), total ${globalSeenLower.size}.`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
