# STE-STC (Simplified Technical English -> Simplified Technical Chinese) 翻译规范

本规范结合 ASD-STE100 简化技术英语原则与桌面工程工具本地化最佳实践，是 `agy-higher` 中文拓展词库的唯一验收标准。

## 核心五原则

1. **一词一义（Canonical Terminology）**
   - 同一技术概念在全产品范围内必须使用唯一固定译名，严禁混用近义词：
     - `Conversation` -> `对话`（不混用“聊天/会话串”）
     - `Session` -> `会话`
     - `Context` -> `上下文`（不混用“语境/内容”）
     - `Quota` -> `额度`（不混用“配额/限量”，除非明确为 `Limit` -> `限额`）
     - `Artifact` -> `产物`（不混用“制品/工件”）
     - `Archive` -> `归档`
     - `Pin` -> `置顶`
     - `Star` -> `星标`
     - `Subagent` -> `子代理`
     - `Checkpoint` -> `检查点`
     - `Thinking effort` -> `推理强度`
     - `Orchestrator` -> `编排器`
     - `Workspace` -> `工作区`
     - `Sandbox` -> `沙盒`

2. **祈使短句与零废话（Imperative & Zero Filler）**
   - 控件与菜单使用 2-6 字动宾或名词短语，如 `新建对话`、`归档对话`、`复制 ID`、`搜索产物内容`。
   - 严禁出现礼貌废话与拟人化措辞（如 `请您`、`您可以点击`、`点击这里`、`欢迎使用`、`小助手`）。

3. **技术标识符原样保留（Identifier Preservation）**
   - 产品名、模型名、协议、文件格式、命令行参数、快捷键、文件路径、URL、工具函数名一律保留英文原文（白名单由 `l10n/src/ste-stc-glossary.json` 的 `allowedLatin` 统一托管）。
   - 在 `keepOptionNamesEnglish` 开启时，推理强度（`Extra High / High / Medium / Low`）与模式名（`Plan / Auto / Accept Edits`）保持英文。

4. **极性严格一致（Polarity Fidelity）**
   - 权限与开关类词条严禁发生肯定/否定语义反转（`Allow` 对应 `允许`，`Deny` 对应 `拒绝`，`Hide` 对应 `隐藏/屏蔽`，`Show` 对应 `显示`，`Unarchive` 对应 `取消归档`）。

5. **幂等与数据隔离（Idempotency & Data Isolation）**
   - 任何静态词条或动态正则执行两次的输出必须与执行一次完全一致。
   - 长度 <= 15 的短词只参与整句/整控件精确匹配，不参与长句中间子串替换。
   - 跳过代码块（`code`、`pre`）、终端（`.xterm`）、编辑器（`.monaco-editor`）及用户输入消息正文。
