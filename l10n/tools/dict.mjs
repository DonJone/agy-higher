#!/usr/bin/env node
/**
 * AgyHigher STE-STC Dictionary CLI (Agent-Maintainable)
 * Commands:
 *   node l10n/tools/dict.mjs stats
 *   node l10n/tools/dict.mjs find <query>
 *   node l10n/tools/dict.mjs add <domain> <source> <target>
 *   node l10n/tools/dict.mjs set <domain> <source> <target>
 *   node l10n/tools/dict.mjs remove <source>
 *   node l10n/tools/dict.mjs check
 *   node l10n/tools/dict.mjs audit-ste
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');
const DICT_DIR = path.join(ROOT, 'src', 'dict');
const GLOSSARY_PATH = path.join(ROOT, 'src', 'ste-stc-glossary.json');

function loadDomainFiles() {
  if (!fs.existsSync(DICT_DIR)) {
    throw new Error(`Missing dictionary directory: ${DICT_DIR}`);
  }
  const files = fs
    .readdirSync(DICT_DIR)
    .filter((f) => f.endsWith('.json'))
    .sort();
  return files.map((file) => {
    const domain = file.replace(/\.json$/, '');
    const fullPath = path.join(DICT_DIR, file);
    const raw = JSON.parse(fs.readFileSync(fullPath, 'utf8'));
    const hasWrapper = raw && typeof raw === 'object' && raw.phrases && typeof raw.phrases === 'object';
    const meta = hasWrapper
      ? { group: raw.group || domain, description: raw.description || `${domain} dictionary (STE-STC)` }
      : { group: domain, description: `${domain} dictionary (STE-STC)` };
    const data = hasWrapper ? raw.phrases : raw;
    return { domain, file, fullPath, meta, data };
  });
}

function saveDomainFile(fullPath, data, meta) {
  const sortedEntries = Object.entries(data).sort((a, b) => {
    if (b[0].length !== a[0].length) return b[0].length - a[0].length;
    return a[0].localeCompare(b[0], 'en');
  });
  const ordered = {
    group: meta.group,
    description: meta.description,
    phrases: Object.fromEntries(sortedEntries)
  };
  fs.writeFileSync(fullPath, JSON.stringify(ordered, null, 2) + '\n', 'utf8');
}

function cmdStats() {
  const domains = loadDomainFiles();
  let total = 0;
  const rows = [];
  for (const d of domains) {
    const count = Object.keys(d.data).length;
    total += count;
    rows.push({ domain: d.domain, count });
  }
  const glossary = JSON.parse(fs.readFileSync(GLOSSARY_PATH, 'utf8'));
  console.log(`STE-STC Dictionary Stats (version ${glossary.version})`);
  console.log(`Standard: ${glossary.standard}`);
  for (const r of rows) {
    console.log(`  - ${r.domain}.json: ${r.count} entries`);
  }
  console.log(`Total phrases: ${total}`);
}

function cmdFind(query) {
  if (!query) {
    console.error('Usage: dict.mjs find <query>');
    process.exit(1);
  }
  const q = query.toLowerCase();
  const domains = loadDomainFiles();
  let hits = 0;
  for (const d of domains) {
    for (const [k, v] of Object.entries(d.data)) {
      if (k.toLowerCase().includes(q) || String(v).toLowerCase().includes(q)) {
        console.log(`[${d.domain}] ${k} => ${v}`);
        hits++;
      }
    }
  }
  console.log(`Matches: ${hits}`);
}

function cmdUpsert(mode, domain, source, target) {
  if (!domain || !source || !target) {
    console.error(`Usage: dict.mjs ${mode} <domain> <source> <target>`);
    process.exit(1);
  }
  const domains = loadDomainFiles();
  const srcLower = source.trim().toLowerCase();
  const existing = [];
  for (const d of domains) {
    for (const k of Object.keys(d.data)) {
      if (k.toLowerCase() === srcLower) {
        existing.push({ domain: d.domain, key: k, fullPath: d.fullPath, meta: d.meta, data: d.data });
      }
    }
  }
  if (mode === 'add' && existing.length > 0) {
    console.error(
      `Entry "${source}" already exists in [${existing[0].domain}] as "${existing[0].key}". Use "set" to update.`
    );
    process.exit(1);
  }

  let targetDom = domains.find((d) => d.domain === domain);
  if (!targetDom) {
    const fullPath = path.join(DICT_DIR, `${domain}.json`);
    targetDom = {
      domain,
      file: `${domain}.json`,
      fullPath,
      meta: { group: domain, description: `${domain} dictionary (STE-STC)` },
      data: {}
    };
  }

  // If moving or updating case-insensitive key across domains, clean previous exact match
  for (const hit of existing) {
    if (hit.domain !== domain || hit.key !== source.trim()) {
      delete hit.data[hit.key];
      saveDomainFile(hit.fullPath, hit.data, hit.meta);
    }
  }

  targetDom.data[source.trim()] = target.trim();
  saveDomainFile(targetDom.fullPath, targetDom.data, targetDom.meta);
  console.log(`[${mode}] ${domain}.json: "${source.trim()}" => "${target.trim()}"`);
}

function cmdRemove(source) {
  if (!source) {
    console.error('Usage: dict.mjs remove <source>');
    process.exit(1);
  }
  const domains = loadDomainFiles();
  const srcLower = source.trim().toLowerCase();
  let removed = 0;
  for (const d of domains) {
    for (const k of Object.keys(d.data)) {
      if (k.toLowerCase() === srcLower) {
        delete d.data[k];
        saveDomainFile(d.fullPath, d.data, d.meta);
        console.log(`[remove] ${d.domain}.json: "${k}"`);
        removed++;
      }
    }
  }
  if (removed === 0) {
    console.error(`Entry not found: "${source}"`);
    process.exit(1);
  }
}

function cmdCheck() {
  const domains = loadDomainFiles();
  const seen = new Map();
  let errors = 0;

  for (const d of domains) {
    for (const [k, v] of Object.entries(d.data)) {
      if (!k.trim()) {
        console.error(`[ERROR] Empty key in ${d.file}`);
        errors++;
        continue;
      }
      if (typeof v !== 'string' || !v.trim()) {
        console.error(`[ERROR] Empty value for "${k}" in ${d.file}`);
        errors++;
        continue;
      }
      if (k.trim() === v.trim()) {
        console.error(`[ERROR] Unchanged translation "${k}" in ${d.file}`);
        errors++;
      }
      const lower = k.trim().toLowerCase();
      if (seen.has(lower)) {
        const prev = seen.get(lower);
        console.error(
          `[ERROR] Duplicate key "${k}" in ${d.file} (already in ${prev.file} as "${prev.key}")`
        );
        errors++;
      } else {
        seen.set(lower, { file: d.file, key: k });
      }
    }
  }

  if (errors > 0) {
    console.error(`Check failed with ${errors} error(s).`);
    process.exit(1);
  }
  console.log(`Check passed: ${seen.size} unique entries across ${domains.length} domain files.`);
}

function cmdAuditSte() {
  const domains = loadDomainFiles();
  const glossary = JSON.parse(fs.readFileSync(GLOSSARY_PATH, 'utf8'));
  const forbidden = glossary.forbiddenFiller || [];
  let warnings = 0;

  for (const d of domains) {
    for (const [k, v] of Object.entries(d.data)) {
      for (const word of forbidden) {
        if (v.includes(word)) {
          console.log(`[WARN] Forbidden filler "${word}" in [${d.domain}] "${k}" => "${v}"`);
          warnings++;
        }
      }
      if (/[!！]{2,}/.test(v)) {
        console.log(`[WARN] Excessive punctuation in [${d.domain}] "${k}" => "${v}"`);
        warnings++;
      }
    }
  }
  console.log(`STE-STC audit finished: ${warnings} warning(s).`);
}

const [, , cmd, ...args] = process.argv;
switch (cmd) {
  case 'stats':
    cmdStats();
    break;
  case 'find':
    cmdFind(args.join(' '));
    break;
  case 'add':
    cmdUpsert('add', args[0], args[1], args[2]);
    break;
  case 'set':
    cmdUpsert('set', args[0], args[1], args[2]);
    break;
  case 'remove':
    cmdRemove(args.join(' '));
    break;
  case 'check':
    cmdCheck();
    break;
  case 'audit-ste':
    cmdAuditSte();
    break;
  default:
    console.log('Usage: dict.mjs <stats|find|add|set|remove|check|audit-ste> [args...]');
    process.exit(cmd ? 1 : 0);
}
