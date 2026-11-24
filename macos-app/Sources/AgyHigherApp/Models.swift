import Foundation

struct ApiResponse<T: Decodable>: Decodable {
    let ok: Bool
    let data: T?
    let error: String?
}

struct AppPreferences: Codable, Equatable {
    let hideNonGeminiModels: Bool
    let showMenuBarQuota: Bool
    let themeMode: String
    let showArchivedSessions: Bool
    let l10nEnabled: Bool
    let l10nKeepEnglishOptions: Bool
}

struct L10nStatus: Codable, Equatable {
    let antigravityVersion: String
    let standard: String
    let dictionaryVersion: String
    let phraseCount: Int
    let customRuleCount: Int
    let overlayPath: String
    let customFilePath: String
    let overlayReady: Bool
    let bundleShaShort: String
    let patchInstalled: Bool
    let patchVersion: String
    let backupExists: Bool
}

struct NativeProject: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let folderPath: String?
    let sessionCount: Int
    let totalSteps: UInt32
    let lastModified: String
}

struct ContextBreakdown: Codable, Equatable {
    let rulesK: UInt32
    let cacheK: UInt32
    let freshInputK: UInt32
    let outputK: UInt32
    let freeK: UInt32
}

struct ToolUsageStat: Codable, Equatable, Identifiable {
    let name: String
    let count: UInt32
    var id: String { name }
}

struct SessionTelemetry: Codable, Identifiable, Equatable {
    let id: String
    let shortId: String
    let projectId: String
    let projectName: String
    let cwd: String
    let shortPath: String
    let workspacePaths: [String]
    let title: String
    let preview: String
    let lastUserPrompt: String
    let isPinned: Bool
    let isStarred: Bool
    let isArchived: Bool
    let tags: [String]
    let status: String
    let isLiveActive: Bool
    let branch: String
    let workspaceRuleFiles: [String]
    let artifactFiles: [String]
    let model: String
    let modelsUsed: [String]
    let ctxUsedTokens: UInt64
    let ctxLimitTokens: UInt64
    let ctxUsedK: UInt32
    let ctxTotalK: UInt32
    let ctxPct: UInt32
    let breakdown: ContextBreakdown
    let totalInputTokens: UInt64
    let totalCacheReadTokens: UInt64
    let totalOutputTokens: UInt64
    let totalThinkingTokens: UInt64
    let cacheHitPct: UInt32
    let costUsd: Double
    let stepCount: UInt32
    let llmTurns: UInt32
    let userTurns: UInt32
    let assistantTurns: UInt32
    let toolCallCount: UInt32
    let topTools: [ToolUsageStat]
    let checkpointCount: UInt32
    let subagentCount: UInt32
    let isCompactedPendingTurn: Bool
    let telemetryOrigin: String
    let createdAt: String
    let lastModified: String
}

struct QuotaBucket: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let window: String
    let remainingFraction: Double
    let remainingPct: UInt32
    let resetTime: String
    let resetCountdown: String
    let description: String
}

struct QuotaGroup: Codable, Equatable, Identifiable {
    let name: String
    let description: String
    let isGemini: Bool
    let buckets: [QuotaBucket]
    var id: String { name }
}

struct QuotaSnapshot: Codable, Equatable {
    let source: String
    let accountEmail: String
    let authMethod: String
    let planLabel: String
    let activeModelId: String
    let activeModelLabel: String
    let remainingCredits: Int64
    let upgradeUri: String
    let description: String
    let groups: [QuotaGroup]
    let fetchedAt: String
    let isCached: Bool
    let error: String?
}

struct AccountProfile: Codable, Identifiable, Equatable {
    let email: String
    let initial: String
    let authMethod: String
    let planLabel: String
    let isActive: Bool
    let lastSeenAt: String
    let quotaSummaryText: String
    let weeklyRemainingPct: UInt32?
    let fiveHourRemainingPct: UInt32?
    let resetCountdown: String
    let remainingCredits: Int64?
    let quotaUpdatedAt: String
    let cachedQuota: QuotaSnapshot?

    var id: String { email }
}

struct DashboardSnapshot: Codable, Equatable {
    let sandboxMode: Bool
    let sessionCount: Int
    let projects: [NativeProject]
    let sessions: [SessionTelemetry]
    let quota: QuotaSnapshot
    let accounts: [AccountProfile]
    let activeEmail: String
    let preferences: AppPreferences
    let l10n: L10nStatus
    let lastScannedAt: String
}

struct MutationResult: Codable, Equatable {
    let snapshot: DashboardSnapshot
    let message: String
}

// MARK: - Request Payloads

struct InitConfigPayload: Encodable {
    let sandboxMode: Bool
    let sandboxRoot: String?
}

struct UpdatePreferencesPayload: Encodable {
    let hideNonGeminiModels: Bool?
    let showMenuBarQuota: Bool?
    let themeMode: String?
    let showArchivedSessions: Bool?
    let l10nEnabled: Bool?
    let l10nKeepEnglishOptions: Bool?
}

struct AccountActionPayload: Encodable {
    let action: String
    let email: String?
}

struct L10nActionPayload: Encodable {
    let action: String
}
