import Foundation

/// Centralized STE-STC (Simplified Technical English -> Simplified Technical Chinese)
/// Copy & Formatter Registry for AgyHigher.
///
/// Enforces all 5 STE-STC software design principles across the entire SwiftUI frontend:
/// 1. Canonical Terminology (one concept -> one term: 会话/项目/上下文/额度/产物/子代理/检查点/归档/星标/标签)
/// 2. Imperative Verbs & Zero Filler (2-4 char verb-object actions; zero conversational fluff)
/// 3. Technical Identifier Preservation (GitHub, SHA-256, STE-STC, Gemini, Claude, GPT, Extra High, Plan, Auto)
/// 4. Strict Polarity Fidelity (隐藏/显示, 启用/关闭, 安装/卸载)
/// 5. Deterministic State Tokens (compact state labels + tabular numeric readouts)
enum STCopy {
    // MARK: - Brand & Navigation
    static let appName = "AgyHigher"
    static let windowTitle = "AgyHigher"

    enum Nav {
        static let sessions = "会话"
        static let settings = "设置"
    }

    enum SettingsNav {
        static let accounts = "账户"
        static let display = "显示"
        static let l10n = "中文拓展"
        static let updates = "更新"
    }

    // MARK: - Canonical Action Verbs (Imperative, 2-4 chars)
    enum Action {
        static let refresh = "刷新"
        static let refreshSessions = "刷新会话"
        static let refreshQuota = "刷新额度"
        static let refreshAccounts = "刷新额度"
        static let syncDict = "同步词库"
        static let installPatch = "安装补丁"
        static let uninstallPatch = "卸载补丁"
        static let restartApp = "重启应用"
        static let editCustomTerms = "编辑词条"
        static let copyPath = "复制路径"
        static let copyId = "复制 ID"
        static let clearInactive = "清理缓存"
        static let removeCache = "移除"
        static let clearSearch = "清空"
        static let details = "明细"
        static let checkUpdates = "检查更新"
        static let checkUpdatesMenu = "检查更新..."
        static let openReleases = "发布页"
        static let cancelDownload = "取消"
        static let openMainWindow = "打开主窗口"
        static let quit = "退出"
        static let toggleTheme = "切换主题"
    }

    // MARK: - Deterministic Busy / State Tokens
    enum State {
        static let syncing = "同步中..."
        static let building = "构建中..."
        static let installing = "安装中..."
        static let restarting = "重启中..."
        static let checking = "检查中..."
        static let updating = "更新中..."
        static let current = "当前"
        static let active = "活跃"
        static let idle = "空闲"
        static let running = "运行中"
        static let archived = "归档"
        static let archivedFull = "已归档"
        static let patched = "已安装"
        static let unpatched = "未安装"
        static let ready = "就绪"
        static let unbuilt = "未构建"
        static let none = "无"
        static let notSignedIn = "未登录"
    }

    // MARK: - Sidebar & Quota Dock
    enum Sidebar {
        static let searchPlaceholder = "筛选项目或会话"
        static let emptyProjects = "无项目"
        static let emptyMatches = "无匹配结果"
        static let emptySessions = "无会话"
        static let quotaTitle = "额度"
        static let weeklyRemaining = "周剩余"
        static let fiveHourWindow = "5h"
        static let noQuotaPrompt = "刷新以获取额度"
    }

    // MARK: - Session Inspector & Project Overview
    enum Inspector {
        static let emptySelection = "选择项目或会话"
        static let contextUsage = "上下文占用"
        static let totalInput = "累计输入"
        static let cacheHit = "缓存命中"
        static let estimatedCost = "估算费用"
        static let referenceRate = "公开费率"
        static let rules = "规则"
        static let cache = "缓存"
        static let freshInput = "新增"
        static let output = "输出"
        static let remaining = "剩余"
        static let telemetrySection = "遥测明细"
        static let currentModel = "当前模型"
        static let stepsAndTurns = "步数 / 轮次"
        static let userAndAssistant = "提问 / 回复"
        static let toolsAndCheckpoints = "工具调用 / 检查点"
        static let subagents = "子代理"
        static let tags = "标签"
        static let sessionStatus = "状态"
        static let topTools = "高频工具"
        static let modelsUsed = "已用模型"
        static let artifacts = "产物"
        static let ruleFiles = "规则文件"
        static let thinkingTokens = "思考 Token"
        static let dataSource = "数据源"
        static let recentPrompt = "最近输入"
    }

    enum Folder {
        static let totalSessions = "会话总数"
        static let peakContext = "最高上下文"
        static let totalSteps = "累计步数"
        static let totalCost = "合计估算"
        static let allIdle = "全部空闲"
        static let noData = "无数据"
        static let tableTitle = "项目会话"
        static let colContext = "上下文"
        static let colSteps = "步数"
        static let colCost = "估算"
        static let colUpdated = "更新时间"
        static let empty = "无会话"
    }

    // MARK: - Settings Domains (Concise Technical Labels + Specs)
    enum Accounts {
        static let title = "账户"
        static let popoverTitle = "账户额度"
        static let empty = "无已验证账户"
        static let weeklyShort = "周"
    }

    enum Display {
        static let title = "显示"
        static let hideNonGemini = "隐藏非 Gemini 模型"
        static let hideNonGeminiSpec = "Claude / GPT"
        static let menuBarQuota = "状态栏显示额度"
        static let menuBarQuotaSpec = "周%-5h%"
        static let showArchived = "显示归档会话"
        static let showArchivedSpec = "v2.35 无限历史"
        static let theme = "外观主题"
        static let themeSpec = "深色 / 浅色"
        static let dark = "深色"
        static let light = "浅色"
    }

    enum L10n {
        static let title = "中文拓展"
        static let enable = "启用中文拓展"
        static let keepEnglishOptions = "选项名保留英文"
        static let keepEnglishOptionsSpec = "Extra High / Plan / Auto"
        static let customOverlay = "自定义词条与脚本"
        static let targetVersion = "目标版本"
        static let patchStatus = "补丁状态"
        static let dictScale = "词库规模"
        static let scriptPath = "脚本路径"
        static let backupStatus = "原版备份"
        static let backupReady = "已备份"
        static let backupNone = "无"
    }

    enum Updates {
        static let title = "软件更新"
        static let autoCheck = "自动检查更新"
        static let autoCheckSpec = "启动时静默检查"
        static let channel = "更新通道"
        static let channelSpec = "GitHub Releases"
        static let currentVersion = "当前版本"
        static let verifyPolicy = "校验方式"
        static let verifyPolicyValue = "SHA-256 + 原位替换"
        static let repository = "发布仓库"
    }

    enum MenuBar {
        static let noQuota = "无额度数据"
        static let activeContext = "活跃上下文"
        static let recentContext = "最近上下文"
    }

    // MARK: - Compact Technical Formatters
    static func tokens(_ count: UInt64) -> String {
        if count >= 1_000_000 {
            return String(format: "%.2fM", Double(count) / 1_000_000.0)
        } else if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000.0)
        }
        return "\(count)"
    }

    static func shortModel(_ raw: String) -> String {
        raw.replacingOccurrences(of: "Gemini ", with: "G")
            .replacingOccurrences(of: " (XHigh)", with: " XH")
            .replacingOccurrences(of: " (High)", with: " H")
            .replacingOccurrences(of: " (Medium)", with: " M")
            .replacingOccurrences(of: " (Low)", with: " L")
    }

    static func abbreviateHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    static func telemetryOrigin(_ origin: String) -> String {
        switch origin {
        case "db+gen_metadata": return "gen_metadata"
        case "compacted-pending": return "已压缩 (待下轮校准)"
        case "db-steps": return "steps"
        case "transcript.jsonl": return "transcript"
        default: return "summary"
        }
    }
}
