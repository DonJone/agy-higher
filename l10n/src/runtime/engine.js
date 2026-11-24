/**
 * AgyHigher STE-STC Non-Destructive Overlay Engine
 * Inspired by yuexps/Antigravity-Hans; refactored for STE-STC determinism & zero emoji compliance.
 */

export function createTranslator(config) {
  const {
    phrases = [],
    customEntries = [],
    keepEnglishOptionNames = false,
    keepOptionSet = new Set(),
    permissionTemplates = [],
    dynamicPatterns = []
  } = config;

  const exactMap = new Map();
  const longPhrases = [];

  for (const [src, dst] of phrases) {
    if (!src || !dst) continue;
    const key = src.toLowerCase();
    exactMap.set(key, dst);
    if (src.length > 15) {
      longPhrases.push([src, dst]);
    }
  }
  longPhrases.sort((a, b) => b[0].length - a[0].length);

  const customMap = new Map();
  for (const pair of customEntries) {
    if (!Array.isArray(pair) || pair.length < 2) continue;
    const src = String(pair[0] || '').trim();
    const dst = String(pair[1] || '').trim();
    if (!src) continue;
    customMap.set(src.toLowerCase(), dst); // empty dst => explicitly keep English
  }

  function translate(rawValue) {
    if (typeof rawValue !== 'string') return rawValue;
    const trimmed = rawValue.trim();
    if (!trimmed) return rawValue;

    const lower = trimmed.toLowerCase();

    // 1. Highest priority: user custom-translations.txt override or keep-English rule
    if (customMap.has(lower)) {
      const override = customMap.get(lower);
      if (override === '') return rawValue;
      return rawValue.replace(trimmed, () => override);
    }

    // 2. Keep English option names (e.g., Extra High / High / Medium / Low / Plan / Auto)
    if (keepEnglishOptionNames && keepOptionSet.has(lower)) {
      return rawValue;
    }

    // 3. Idempotency guard: already-translated permission strings
    if (/^(允许|在 .+ 中始终允许|拒绝访问)/.test(trimmed)) {
      return rawValue;
    }

    // 4. Permission templates (strictly preserve target command/path/URL via callback replace)
    for (const tpl of permissionTemplates) {
      const m = trimmed.match(tpl.re);
      if (m) {
        const out = tpl.format(...m);
        return rawValue.replace(trimmed, () => out);
      }
    }

    // 5. Exact phrase match (and trailing punctuation / shortcut suffix)
    if (exactMap.has(lower)) {
      const hit = exactMap.get(lower);
      return rawValue.replace(trimmed, () => hit);
    }

    const punctMatch = trimmed.match(/^(.+?)([:：.…!?]+)$/);
    if (punctMatch) {
      const baseLower = punctMatch[1].trim().toLowerCase();
      if (customMap.has(baseLower)) {
        const ov = customMap.get(baseLower);
        if (ov === '') return rawValue;
        return rawValue.replace(trimmed, () => ov + punctMatch[2]);
      }
      if (exactMap.has(baseLower)) {
        const hit = exactMap.get(baseLower);
        return rawValue.replace(trimmed, () => hit + punctMatch[2]);
      }
    }

    // 6. Dynamic variable patterns (counts, reset countdowns, match ratios)
    for (const pat of dynamicPatterns) {
      const m = trimmed.match(pat.re);
      if (m) {
        const out = pat.format(...m);
        return rawValue.replace(trimmed, () => out);
      }
    }

    // 7. Long phrases (> 15 chars, descending length order) substring pass
    let current = trimmed;
    let changed = false;
    for (const [src, dst] of longPhrases) {
      if (current.includes(src)) {
        current = current.split(src).join(dst);
        changed = true;
      }
    }
    if (changed) {
      return rawValue.replace(trimmed, () => current);
    }

    return rawValue;
  }

  return { translate };
}
