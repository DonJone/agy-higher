---
name: agy-higher-l10n
description: >-
  Maintain and adapt the STE-STC (Simplified Technical English -> Simplified
  Technical Chinese) Chinese localization overlay for Google Antigravity
  Desktop inside agy-higher. Use when Antigravity updates to a new version
  (e.g. v2.35.0+), new untranslated UI strings appear, terminology needs
  STE-STC normalization, or custom-translations.txt rules need validation.
---

# AgyHigher STE-STC 中文拓展维护指南

本技能用于让 Agent 以**声明式、可审计、可回归测试**的方式长期维护 Antigravity 中文拓展词库，完全采用 **STE-STC（Simplified Technical English -> Simplified Technical Chinese）** 翻译标准，并借鉴 `yuexps/Antigravity-Hans` 的“词库源码化 + 非侵入运行时叠加 + 用户自定义覆盖”三层架构。

## 架构目录

- **词库源码（唯一可编辑入口）**：`l10n/src/`
  - `ste-stc-glossary.json`：STE-STC 核心术语表、禁用口语清单与允许保留的拉丁技术标识符白名单。
  - `dict/common.json`：通用控件、导航、搜索、归档/置顶/星标与状态词条。
  - `dict/chat-agent.json`：对话、上下文、产物、子代理、工具调用、审批与 v2.35.0 新特性词条。
  - `dict/settings-quota.json`：账户、额度窗口、模型、MCP、插件、权限与沙盒词条。
  - `runtime/rules.js`：权限模板、动态正则、DOM 跳过选择器与英文选项名白名单。
  - `runtime/engine.js`：幂等翻译引擎（自定义覆盖 > 选项名保留英文 > 权限模板 > 精确匹配 > 动态规则 > 长短语替换）。
- **Agent 维护工具链**：`l10n/tools/`
  - `dict.mjs`：增删改查与 STE-STC 术语核对 CLI。
  - `build-overlay.mjs`：将 `l10n/src/` 编译为自包含运行时产物 `l10n/dist/antigravity-stc-overlay.js` 与 `l10n/dist/manifest.json`（同时供 `AgyHigher.app` 同步到 `~/.config/agy-higher/l10n/`）。
  - `lint-l10n.mjs`：STE-STC 规范检查（排序、重键、空值、极性反转、口语废话、术语不一致、Emoji 检查）。
  - `overlay.test.mjs`：Node 原生回归测试（幂等性、权限路径防篡改、动态模板、用户自定义名单、`keepOptionNamesEnglish`）。
- **用户自定义覆盖**：`~/.config/agy-higher/custom-translations.txt`（每行 `English = 中文` 覆盖，或仅写 `English` 强制保留原文）。

## 标准维护工作流

1. **查看当前词库统计与目标版本**
   ```bash
   node l10n/tools/dict.mjs stats
   ```
2. **检索或查重某条英文原文**
   ```bash
   node l10n/tools/dict.mjs find "Archive conversation"
   node l10n/tools/dict.mjs check "Allow reading /etc/hosts"
   ```
3. **新增或更新词条（必须符合 STE-STC 规范，详见 `references/ste-stc-standard.md`）**
   ```bash
   node l10n/tools/dict.mjs add common "Search in artifact" "搜索产物内容"
   node l10n/tools/dict.mjs set settings-quota "Weekly limit" "每周限额"
   ```
4. **编译产物、执行 STE-STC Lint 与回归测试（提交前必须全部 0 错误通过）**
   ```bash
   node l10n/tools/build-overlay.mjs
   node l10n/tools/lint-l10n.mjs
   node --test l10n/tools/overlay.test.mjs
   ```

## 硬性安全边界

- 禁止直接修改 `/Applications/Antigravity.app` 安装包内文件或破坏其代码签名。
- 禁止手动编辑 `l10n/dist/antigravity-stc-overlay.js`；所有变更必须落在 `l10n/src/` 并通过 `build-overlay.mjs` 重建。
- 权限模板与动态规则中所有命令、路径、URL、工具名与变量占位符必须原样保留，严禁改写或使用不安全的 `$` 字符串替换。
- 严禁在词库、脚本或文档中出现任何 Unicode Emoji。
