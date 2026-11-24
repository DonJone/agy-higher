import CAgyHigherCore
import Foundation

enum CoreBridgeError: LocalizedError {
    case encodingFailed(String)
    case decodingFailed(String)
    case coreError(String)
    case nullPointer

    var errorDescription: String? {
        switch self {
        case .encodingFailed(let msg): return "编码请求失败: \(msg)"
        case .decodingFailed(let msg): return "解析核心响应失败: \(msg)"
        case .coreError(let msg): return msg
        case .nullPointer: return "Rust 核心返回空指针"
        }
    }
}

final class CoreBridge: @unchecked Sendable {
    private func consume<T: Decodable>(_ rawPtr: UnsafeMutablePointer<CChar>?) throws -> T {
        guard let ptr = rawPtr else {
            throw CoreBridgeError.nullPointer
        }
        defer { agy_higher_string_free(ptr) }
        let jsonString = String(cString: ptr)
        guard let data = jsonString.data(using: .utf8) else {
            throw CoreBridgeError.decodingFailed("Invalid UTF-8")
        }
        let decoder = JSONDecoder()
        let envelope: ApiResponse<T>
        do {
            envelope = try decoder.decode(ApiResponse<T>.self, from: data)
        } catch {
            throw CoreBridgeError.decodingFailed("\(error.localizedDescription) — raw: \(jsonString.prefix(240))")
        }
        if envelope.ok, let payload = envelope.data {
            return payload
        }
        throw CoreBridgeError.coreError(envelope.error ?? "未知核心错误")
    }

    private func encodeJSON<P: Encodable>(_ payload: P) throws -> String {
        let encoder = JSONEncoder()
        do {
            let data = try encoder.encode(payload)
            guard let str = String(data: data, encoding: .utf8) else {
                throw CoreBridgeError.encodingFailed("UTF-8 conversion failed")
            }
            return str
        } catch {
            throw CoreBridgeError.encodingFailed(error.localizedDescription)
        }
    }

    func initialize(sandboxMode: Bool = false, sandboxRoot: String? = nil) throws -> DashboardSnapshot {
        let json = try encodeJSON(InitConfigPayload(sandboxMode: sandboxMode, sandboxRoot: sandboxRoot))
        return try json.withCString { ptr in
            try consume(agy_higher_init(ptr))
        }
    }

    func refresh() throws -> DashboardSnapshot {
        try consume(agy_higher_refresh())
    }

    func focusSession(_ sessionId: String) throws -> DashboardSnapshot {
        try sessionId.withCString { ptr in
            try consume(agy_higher_focus_session(ptr))
        }
    }

    func refreshLiveQuota() throws -> DashboardSnapshot {
        try consume(agy_higher_refresh_live_quota())
    }

    func updatePreferences(
        hideNonGeminiModels: Bool? = nil,
        showMenuBarQuota: Bool? = nil,
        themeMode: String? = nil,
        showArchivedSessions: Bool? = nil,
        l10nEnabled: Bool? = nil,
        l10nKeepEnglishOptions: Bool? = nil
    ) throws -> MutationResult {
        let json = try encodeJSON(UpdatePreferencesPayload(
            hideNonGeminiModels: hideNonGeminiModels,
            showMenuBarQuota: showMenuBarQuota,
            themeMode: themeMode,
            showArchivedSessions: showArchivedSessions,
            l10nEnabled: l10nEnabled,
            l10nKeepEnglishOptions: l10nKeepEnglishOptions
        ))
        return try json.withCString { ptr in
            try consume(agy_higher_update_preferences(ptr))
        }
    }

    func accountAction(_ action: String, email: String? = nil) throws -> MutationResult {
        let json = try encodeJSON(AccountActionPayload(action: action, email: email))
        return try json.withCString { ptr in
            try consume(agy_higher_account_action(ptr))
        }
    }

    func l10nAction(_ action: String) throws -> MutationResult {
        let json = try encodeJSON(L10nActionPayload(action: action))
        return try json.withCString { ptr in
            try consume(agy_higher_l10n_action(ptr))
        }
    }
}
