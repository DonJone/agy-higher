/**
 * STE-STC Translation Runtime Rules
 * Extracted & refactored from Antigravity-Hans pipeline architecture.
 * Strictly preserves commands, paths, URLs, tool names, and variable placeholders.
 */

export const KEEP_ENGLISH_OPTION_NAMES = new Set([
  'extra high',
  'high',
  'medium',
  'low',
  'auto',
  'plan',
  'accept edits',
  'turbo',
  'default',
  'max',
  'flash',
  'pro'
]);

export const SKIP_DOM_SELECTOR = [
  'script',
  'style',
  'noscript',
  'code',
  'pre',
  'kbd',
  'samp',
  'textarea',
  'input',
  '[contenteditable="true"]',
  '.xterm',
  '.monaco-editor',
  '[data-testid="message-content"]',
  '[data-testid="code-block"]'
].join(',');

export function formatShortDuration(raw) {
  return String(raw)
    .replace(/(\d+)\s*d\b/gi, '$1 天')
    .replace(/(\d+)\s*h\b/gi, '$1 小时')
    .replace(/(\d+)\s*m\b/gi, '$1 分钟')
    .replace(/(\d+)\s*s\b/gi, '$1 秒')
    .replace(/\s+/g, ' ')
    .trim();
}

export const PERMISSION_TEMPLATES = [
  {
    re: /^Allow\s+([a-zA-Z0-9_.-]+)\s+to\s+run\s+([\s\S]+)$/i,
    format: (_m, tool, target) => `允许 ${tool} 执行 ${target}`
  },
  {
    re: /^Allow\s+reading\s+([\s\S]+)$/i,
    format: (_m, target) => `允许读取 ${target}`
  },
  {
    re: /^Allow\s+editing\s+([\s\S]+)$/i,
    format: (_m, target) => `允许编辑 ${target}`
  },
  {
    re: /^Allow\s+creating\s+([\s\S]+)$/i,
    format: (_m, target) => `允许创建 ${target}`
  },
  {
    re: /^Allow\s+deleting\s+([\s\S]+)$/i,
    format: (_m, target) => `允许删除 ${target}`
  },
  {
    re: /^Always\s+allow\s+in\s+([\s\S]+)$/i,
    format: (_m, target) => `在 ${target} 中始终允许`
  },
  {
    re: /^Deny\s+access\s+to\s+([\s\S]+)$/i,
    format: (_m, target) => `拒绝访问 ${target}`
  }
];

export const DYNAMIC_PATTERNS = [
  {
    re: /^Resets\s+in\s+(\d+)\s*days?,?\s*(\d+)\s*hours?$/i,
    format: (_m, d, h) => `${d} 天 ${h} 小时后重置`
  },
  {
    re: /^Resets\s+in\s+(\d+)\s*hours?,?\s*(\d+)\s*min(?:ute)?s?$/i,
    format: (_m, h, m) => `${h} 小时 ${m} 分钟后重置`
  },
  {
    re: /^Resets\s+in\s+((?:\d+\s*[dhms]\b\s*)+)$/i,
    format: (_m, dur) => `${formatShortDuration(dur)}后重置`
  },
  {
    re: /^(\d+)%\s+left$/i,
    format: (_m, pct) => `剩余 ${pct}%`
  },
  {
    re: /^(\d+)\s+of\s+(\d+)\s+matches?$/i,
    format: (_m, cur, total) => `${cur} / ${total} 匹配`
  },
  {
    re: /^(\d+)\s+conversations?$/i,
    format: (_m, n) => `${n} 个对话`
  },
  {
    re: /^(\d+)\s+steps?$/i,
    format: (_m, n) => `${n} 步`
  },
  {
    re: /^Started\s+(\d+)\s+subagents?$/i,
    format: (_m, n) => `已启动 ${n} 个子代理`
  },
  {
    re: /^Starting\s+(\d+)\s+subagents?$/i,
    format: (_m, n) => `正在启动 ${n} 个子代理`
  },
  {
    re: /^Worked\s+for\s+((?:\d+\s*[dhms]\b\s*)+)$/i,
    format: (_m, dur) => `已耗时 ${formatShortDuration(dur)}`
  },
  {
    re: /^Show\s+(\d+)\s+breakdowns?$/i,
    format: (_m, n) => `显示 ${n} 项明细`
  },
  {
    re: /^Last\s+(\d+)\s+days?$/i,
    format: (_m, n) => `最近 ${n} 天`
  },
  {
    re: /^Overview\s*[·•]\s*(\d+)\s+of\s+(\d+)\s+tasks?\s+done$/i,
    format: (_m, done, total) => `概览 · 已完成 ${done}/${total} 项任务`
  },
  {
    re: /^Good\s+to\s+see\s+you,\s*(.+?)\.\s*What's\s+next\?$/i,
    format: (_m, name) => `你好，${name}。接下来要处理什么？`
  },
  {
    re: /^Welcome\s+back,\s*(.+?)[.!]?$/i,
    format: (_m, name) => `欢迎回来，${name}`
  },
  {
    re: /^Your\s+plan:\s*(.+)$/i,
    format: (_m, plan) => `当前套餐: ${plan}`
  },
  {
    re: /^(\d+)\s+agents?\s+running$/i,
    format: (_m, n) => `${n} 个代理运行中`
  },
  {
    re: /^Updated\s+((?:\d+\s*[dhms]\b\s*)+)\s+ago$/i,
    format: (_m, dur) => `${formatShortDuration(dur)}前更新`
  }
];
