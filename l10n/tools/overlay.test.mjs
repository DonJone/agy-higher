import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createTranslator } from '../src/runtime/engine.js';
import {
  KEEP_ENGLISH_OPTION_NAMES,
  PERMISSION_TEMPLATES,
  DYNAMIC_PATTERNS
} from '../src/runtime/rules.js';
import { loadMergedPhrases, parseCustomTranslationsText } from './build-overlay.mjs';
import {
  inspectAsarPatchStatus,
  installAsarPatch,
  uninstallAsarPatch
} from './asar-patch.mjs';

const { phrases } = loadMergedPhrases();

function makeTranslator(extra = {}) {
  return createTranslator({
    phrases,
    keepOptionSet: KEEP_ENGLISH_OPTION_NAMES,
    permissionTemplates: PERMISSION_TEMPLATES,
    dynamicPatterns: DYNAMIC_PATTERNS,
    ...extra
  });
}

test('STE-STC exact UI phrases and trailing punctuation', () => {
  const { translate } = makeTranslator();
  assert.equal(translate('New conversation'), '新建对话');
  assert.equal(translate('Show archived conversations'), '显示已归档对话');
  assert.equal(translate('Search in HTML artifact'), '在 HTML 产物中搜索');
  assert.equal(translate('Settings:'), '设置:');
  assert.equal(translate('  Thinking effort  '), '  推理强度  ');
});

test('keepEnglishOptionNames preserves model/mode option labels when enabled', () => {
  const keepOn = makeTranslator({ keepEnglishOptionNames: true });
  assert.equal(keepOn.translate('Extra High'), 'Extra High');
  assert.equal(keepOn.translate('Plan'), 'Plan');
  assert.equal(keepOn.translate('Auto'), 'Auto');
  assert.equal(keepOn.translate('Accept Edits'), 'Accept Edits');

  const keepOff = makeTranslator({ keepEnglishOptionNames: false });
  assert.equal(keepOff.translate('Extra High'), '极高');
  assert.equal(keepOff.translate('Accept Edits'), '自动接受编辑');
});

test('permission templates preserve commands, paths, and special $ sequences idempotently', () => {
  const { translate } = makeTranslator();
  const cmd = 'Allow bash to run echo "$& $1 $HOME/test"';
  const once = translate(cmd);
  assert.equal(once, '允许 bash 执行 echo "$& $1 $HOME/test"');
  assert.equal(translate(once), once);

  const pathPerm = 'Allow editing /Users/don/git/agy-higher/rust-core/src/lib.rs';
  const pOnce = translate(pathPerm);
  assert.equal(pOnce, '允许编辑 /Users/don/git/agy-higher/rust-core/src/lib.rs');
  assert.equal(translate(pOnce), pOnce);
});

test('v2.35.0 dynamic patterns translate reset timers, HTML search matches, and subagent counts', () => {
  const { translate } = makeTranslator();
  assert.equal(translate('Resets in 2 days, 5 hours'), '2 天 5 小时后重置');
  assert.equal(translate('Resets in 4h 30m'), '4 小时 30 分钟后重置');
  assert.equal(translate('91% left'), '剩余 91%');
  assert.equal(translate('3 of 12 matches'), '3 / 12 匹配');
  assert.equal(translate('Started 4 subagents'), '已启动 4 个子代理');
  assert.equal(translate('Worked for 1m 24s'), '已耗时 1 分钟 24 秒');
  assert.equal(translate('Overview · 3 of 5 tasks done'), '概览 · 已完成 3/5 项任务');
});

test('custom-translations.txt supports keep-English lines and custom overrides with highest priority', () => {
  const raw = `
# Keep technical terms in English
Context window
# Custom STE-STC override
New conversation = 创建新对话
Settings = 偏好设置
`;
  const customEntries = parseCustomTranslationsText(raw);
  assert.equal(customEntries.length, 3);

  const { translate } = makeTranslator({ customEntries });
  assert.equal(translate('Context window'), 'Context window');
  assert.equal(translate('New conversation'), '创建新对话');
  assert.equal(translate('Settings:'), '偏好设置:');
});

test('live v2.35.0 greeting and plan dynamic patterns translate cleanly', () => {
  const { translate } = makeTranslator();
  assert.equal(translate("Good to see you, anan. What's next?"), '你好，anan。接下来要处理什么？');
  assert.equal(translate('Your plan: Google AI Ultra'), '当前套餐: Google AI Ultra');
});

test('ASAR direct patch install and uninstall roundtrip is byte-exact', async () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'agy-asar-test-'));
  try {
    const asarPath = path.join(tmp, 'app.asar');
    const backupDir = path.join(tmp, 'backups');
    const origMain = Buffer.from('"use strict";\nconsole.log("hello antigravity");\n', 'utf8');
    const pkg = Buffer.from('{"name":"antigravity","main":"dist/main.js"}\n', 'utf8');
    const tree = {
      files: {
        'package.json': { size: pkg.length, offset: '0' },
        dist: {
          files: {
            'main.js': { size: origMain.length, offset: String(pkg.length) }
          }
        }
      }
    };
    const jsonBuf = Buffer.from(JSON.stringify(tree), 'utf8');
    const pad = (4 - (jsonBuf.length % 4)) % 4;
    const hdr = Buffer.alloc(16 + jsonBuf.length + pad, 0);
    hdr.writeUInt32LE(4, 0);
    hdr.writeUInt32LE(8 + jsonBuf.length + pad, 4);
    hdr.writeUInt32LE(4 + jsonBuf.length + pad, 8);
    hdr.writeUInt32LE(jsonBuf.length, 12);
    jsonBuf.copy(hdr, 16);
    const origAsar = Buffer.concat([hdr, pkg, origMain]);
    fs.writeFileSync(asarPath, origAsar);

    assert.equal(inspectAsarPatchStatus(asarPath, backupDir, '2.35.0').patched, false);

    const ins = installAsarPatch(asarPath, backupDir, '2.35.0');
    assert.equal(ins.patched, true);
    assert.equal(inspectAsarPatchStatus(asarPath, backupDir, '2.35.0').patched, true);
    // Re-parse patched dist/main.js and verify zero syntax errors
    const vm = await import('node:vm');
    const { parseAsar } = await import('./asar-patch.mjs');
    const patchedParsed = parseAsar(asarPath);
    const mainEntry = patchedParsed.tree.files.dist.files['main.js'];
    const mainSrc = patchedParsed.payload
      .subarray(Number(mainEntry.offset), Number(mainEntry.offset) + mainEntry.size)
      .toString('utf8');
    assert.doesNotThrow(() => new vm.Script(mainSrc, { filename: 'dist/main.js' }));

    const un = uninstallAsarPatch(asarPath, backupDir, '2.35.0');
    assert.equal(un.patched, false);
    assert.equal(un.restoredFromBackup, true);
    assert.equal(Buffer.compare(fs.readFileSync(asarPath), origAsar), 0);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});
