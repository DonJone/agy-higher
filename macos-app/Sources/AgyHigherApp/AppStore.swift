import AppKit
import Foundation
import SwiftUI

enum MainViewTab: String {
    case dashboard
    case accounts
}

enum SidebarSelection: Equatable {
    case session(String)
    case project(String)
}

@MainActor
final class AppStore: ObservableObject {
    @Published var themeMode: AppThemeMode = .dark
    @Published var activeTab: MainViewTab = .dashboard
    @Published var snapshot: DashboardSnapshot?
    @Published var selection: SidebarSelection?
    @Published var collapsedProjectIds: Set<String> = []
    @Published var userToggledProjectIds: Set<String> = []
    @Published var searchQuery: String = "" {
        didSet {
            if oldValue != searchQuery {
                rebuildSidebarIndex()
            }
        }
    }
    @Published var toastMessage: String?
    @Published var isSyncingQuota: Bool = false
    @Published var isRefreshingSessions: Bool = false
    @Published var isRebuildingL10n: Bool = false
    @Published var isRelaunchingAntigravity: Bool = false
    @Published var isAccountPopoverPresented: Bool = false

    // Pre-indexed O(1) sidebar cache (rebuilt ONLY on snapshot or searchQuery change)
    @Published private(set) var visibleProjects: [NativeProject] = []
    private var filteredSessionsByProject: [String: [SessionTelemetry]] = [:]
    private var allSessionsByProject: [String: [SessionTelemetry]] = [:]
    private var sessionsById: [String: SessionTelemetry] = [:]
    private var projectsById: [String: NativeProject] = [:]

    private let bridge = CoreBridge()
    private var toastTask: Task<Void, Never>?
    private var themeOverriddenByArg: Bool = false
    private var lastRefreshDate: Date = .distantPast
    private var isBootstrapped: Bool = false
    private var userManuallyPickedSelection: Bool = false
    private var lastTrackedLiveSessionId: String?
    private var fsWatchers: [DispatchSourceFileSystemObject] = []
    private var fsDebounceTask: Task<Void, Never>?

    deinit {
        for source in fsWatchers {
            source.cancel()
        }
    }

    var theme: MonochromeTheme {
        MonochromeTheme(mode: themeMode)
    }

    init(
        sandboxOverride: Bool? = nil,
        autoSyncLiveQuota: Bool = true,
        synchronousBootstrap: Bool = false
    ) {
        let args = ProcessInfo.processInfo.arguments
        let envSandbox = ProcessInfo.processInfo.environment["AGY_HIGHER_SANDBOX"] == "1"
        let argSandbox = args.contains("--sandbox")
        let sandboxMode = sandboxOverride ?? (envSandbox || argSandbox)

        if args.contains("--light") {
            themeMode = .light
            themeOverriddenByArg = true
        } else if args.contains("--dark") {
            themeMode = .dark
            themeOverriddenByArg = true
        }
        if args.contains("--accounts") || args.contains("--config") {
            activeTab = .accounts
        }

        if synchronousBootstrap {
            bootstrapSync(sandboxMode: sandboxMode, autoSyncLiveQuota: autoSyncLiveQuota)
        } else {
            bootstrapAsync(sandboxMode: sandboxMode, autoSyncLiveQuota: autoSyncLiveQuota)
        }
    }

    private func bootstrapSync(sandboxMode: Bool, autoSyncLiveQuota: Bool) {
        do {
            let snap = try bridge.initialize(sandboxMode: sandboxMode)
            finishBootstrap(snap: snap, sandboxMode: sandboxMode, autoSyncLiveQuota: autoSyncLiveQuota)
        } catch {
            showToast(error.localizedDescription)
        }
    }

    /// Off-main-thread startup so macOS Window Frame 0 renders instantaneously (0ms UI thread stall).
    private func bootstrapAsync(sandboxMode: Bool, autoSyncLiveQuota: Bool) {
        let localBridge = bridge
        Task.detached(priority: .userInitiated) {
            do {
                let snap = try localBridge.initialize(sandboxMode: sandboxMode)
                await MainActor.run { [weak self] in
                    self?.finishBootstrap(snap: snap, sandboxMode: sandboxMode, autoSyncLiveQuota: autoSyncLiveQuota)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.showToast(error.localizedDescription)
                }
            }
        }
    }

    private func finishBootstrap(snap: DashboardSnapshot, sandboxMode: Bool, autoSyncLiveQuota: Bool) {
        isBootstrapped = true
        lastRefreshDate = Date()
        if !themeOverriddenByArg {
            themeMode = (snap.preferences.themeMode == "light") ? .light : .dark
        }
        applySnapshot(snap, resetSelection: true)

        if !sandboxMode {
            startLiveAntigravityWatchers()
        }

        if autoSyncLiveQuota && !sandboxMode && shouldAutoSyncQuota(snap.quota) {
            refreshLiveQuotaAsync(silent: true)
        }
    }

    /// Zero-CPU macOS kqueue (`EVFILT_VNODE`) file-system watchers on Antigravity Desktop's
    /// live conversations & presence directories so active context changes reflect immediately.
    private func startLiveAntigravityWatchers() {
        guard fsWatchers.isEmpty else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let watchPaths = [
            "\(home)/.gemini/antigravity/conversations",
            "\(home)/.gemini/antigravity/presence",
            "\(home)/.gemini/antigravity"
        ]
        for path in watchPaths {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .rename, .attrib],
                queue: DispatchQueue.global(qos: .utility)
            )
            src.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in
                    self?.scheduleDebouncedLiveRefresh()
                }
            }
            src.setCancelHandler {
                close(fd)
            }
            src.resume()
            fsWatchers.append(src)
        }
    }

    private func scheduleDebouncedLiveRefresh() {
        fsDebounceTask?.cancel()
        fsDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self?.refresh(showFeedback: false)
        }
    }

    /// Skip redundant 6s live subprocess on rapid app reopen when verified cache is < 60s old.
    private func shouldAutoSyncQuota(_ quota: QuotaSnapshot) -> Bool {
        if quota.groups.isEmpty || quota.accountEmail.isEmpty || quota.fetchedAt.isEmpty {
            return true
        }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        if let fetched = fmt.date(from: quota.fetchedAt) {
            return Date().timeIntervalSince(fetched) >= 60.0
        }
        return true
    }

    /// Off-main-thread refresh with in-flight deduplication (never blocks scrolling or animations).
    func refresh(showFeedback: Bool = false) {
        guard !isRefreshingSessions else { return }
        isRefreshingSessions = true
        let localBridge = bridge
        Task.detached(priority: .userInitiated) {
            do {
                let snap = try localBridge.refresh()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isRefreshingSessions = false
                    self.lastRefreshDate = Date()
                    self.applySnapshot(snap, resetSelection: false)
                    if showFeedback {
                        self.showToast("已刷新 \(snap.sessionCount) 个会话")
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isRefreshingSessions = false
                    if showFeedback {
                        self.showToast(error.localizedDescription)
                    }
                }
            }
        }
    }

    /// Zero-CPU event-driven freshness: silently refresh on app activation if >= 4s since last scan.
    func refreshOnActivateIfStale() {
        guard isBootstrapped, !isRefreshingSessions else { return }
        guard Date().timeIntervalSince(lastRefreshDate) >= 4.0 else { return }
        refresh(showFeedback: false)
    }

    /// Instant O(1) session selection on main thread (zero blocking C-ABI roundtrip).
    func selectSession(_ sessionId: String) {
        userManuallyPickedSelection = true
        selection = .session(sessionId)
        activeTab = .dashboard
        if let s = sessionsById[sessionId], s.telemetryOrigin == "summary-only" {
            let localBridge = bridge
            Task.detached(priority: .userInitiated) {
                if let snap = try? localBridge.focusSession(sessionId) {
                    await MainActor.run { [weak self] in
                        self?.applySnapshot(snap, resetSelection: false)
                    }
                }
            }
        }
    }

    func selectProject(_ project: NativeProject) {
        userManuallyPickedSelection = true
        selection = .project(project.id)
        activeTab = .dashboard
        if project.sessionCount > 0 && isProjectCollapsed(project) {
            userToggledProjectIds.insert(project.id)
            collapsedProjectIds.remove(project.id)
        }
    }

    func isProjectCollapsed(_ project: NativeProject) -> Bool {
        if userToggledProjectIds.contains(project.id) {
            return collapsedProjectIds.contains(project.id)
        }
        return project.sessionCount == 0
    }

    func toggleProjectCollapsed(_ project: NativeProject) {
        let currentlyCollapsed = isProjectCollapsed(project)
        userToggledProjectIds.insert(project.id)
        if currentlyCollapsed {
            collapsedProjectIds.remove(project.id)
        } else {
            collapsedProjectIds.insert(project.id)
        }
    }

    func refreshLiveQuotaAsync(silent: Bool = false) {
        guard !isSyncingQuota else { return }
        isSyncingQuota = true
        let localBridge = bridge
        Task.detached(priority: .userInitiated) {
            do {
                let updated = try localBridge.refreshLiveQuota()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isSyncingQuota = false
                    self.applySnapshot(updated, resetSelection: false)
                    if let err = updated.quota.error, !err.isEmpty {
                        if !silent {
                            self.showToast("同步失败: \(err)")
                        }
                    } else if !silent {
                        self.showToast("已同步 \(updated.activeEmail)")
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isSyncingQuota = false
                    if !silent {
                        self.showToast(error.localizedDescription)
                    }
                }
            }
        }
    }

    func applySnapshot(_ snap: DashboardSnapshot, resetSelection: Bool) {
        snapshot = snap
        rebuildAllIndexes(from: snap)

        // Auto-follow whenever Antigravity Desktop switches to a new live active session!
        let currentLive = snap.sessions.first(where: { $0.isLiveActive })
        let newLiveId = currentLive?.id
        if let lid = newLiveId, lid != lastTrackedLiveSessionId {
            lastTrackedLiveSessionId = lid
            if !resetSelection {
                selection = .session(lid)
                return
            }
        } else if newLiveId == nil {
            lastTrackedLiveSessionId = nil
        }

        if !resetSelection, let cur = selection {
            switch cur {
            case .session(let sid):
                if sessionsById[sid] != nil {
                    // If user never manually picked another session, always stay locked on the newest active session
                    if !userManuallyPickedSelection, let top = snap.sessions.first {
                        selection = .session(top.id)
                    }
                    return
                }
            case .project(let pid):
                if projectsById[pid] != nil { return }
            }
        }
        if let first = snap.sessions.first {
            selection = .session(first.id)
        } else if let firstProj = snap.projects.first {
            selection = .project(firstProj.id)
        } else {
            selection = nil
        }
    }

    private func rebuildAllIndexes(from snap: DashboardSnapshot) {
        var sById: [String: SessionTelemetry] = [:]
        sById.reserveCapacity(snap.sessions.count)
        var byProj: [String: [SessionTelemetry]] = [:]
        for s in snap.sessions {
            sById[s.id] = s
            byProj[s.projectId, default: []].append(s)
        }
        var pById: [String: NativeProject] = [:]
        pById.reserveCapacity(snap.projects.count)
        for p in snap.projects {
            pById[p.id] = p
        }
        sessionsById = sById
        projectsById = pById
        allSessionsByProject = byProj
        rebuildSidebarIndex()
    }

    private func rebuildSidebarIndex() {
        guard let snap = snapshot else {
            filteredSessionsByProject = [:]
            visibleProjects = []
            return
        }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            filteredSessionsByProject = allSessionsByProject
            let withSessions = snap.projects.filter { $0.sessionCount > 0 }
            let empty = snap.projects.filter { $0.sessionCount == 0 }
            visibleProjects = withSessions + empty
        } else {
            var filtered: [String: [SessionTelemetry]] = [:]
            for s in snap.sessions {
                if s.title.lowercased().contains(q)
                    || s.projectName.lowercased().contains(q)
                    || s.shortPath.lowercased().contains(q)
                    || s.shortId.lowercased().contains(q)
                    || s.model.lowercased().contains(q)
                {
                    filtered[s.projectId, default: []].append(s)
                }
            }
            filteredSessionsByProject = filtered
            visibleProjects = snap.projects.filter { !(filtered[$0.id]?.isEmpty ?? true) }
        }
    }

    // MARK: - O(1) Computed Dashboard Properties

    var selectedSessionId: String? {
        if case .session(let sid) = selection { return sid }
        return nil
    }

    var selectedProjectId: String? {
        if case .project(let pid) = selection { return pid }
        return nil
    }

    /// Strictly resolves the session Antigravity Desktop is currently using (locked / live / most recently touched).
    var liveActiveSession: SessionTelemetry? {
        guard let sessions = snapshot?.sessions else { return nil }
        return sessions.first(where: { $0.isLiveActive }) ?? sessions.first
    }

    var selectedSession: SessionTelemetry? {
        if case .session(let sid) = selection, let hit = sessionsById[sid] {
            return hit
        }
        return liveActiveSession
    }

    var selectedProject: NativeProject? {
        if case .project(let pid) = selection {
            return projectsById[pid]
        }
        return nil
    }

    var activeAccount: AccountProfile? {
        guard let snap = snapshot else { return nil }
        return snap.accounts.first(where: { $0.isActive }) ?? snap.accounts.first
    }

    var inactiveAccountCount: Int {
        guard let accounts = snapshot?.accounts else { return 0 }
        return accounts.filter { !$0.isActive }.count
    }

    var hideNonGeminiModels: Bool {
        snapshot?.preferences.hideNonGeminiModels ?? true
    }

    var showMenuBarQuota: Bool {
        snapshot?.preferences.showMenuBarQuota ?? true
    }

    var showArchivedSessions: Bool {
        snapshot?.preferences.showArchivedSessions ?? false
    }

    var l10nEnabled: Bool {
        snapshot?.preferences.l10nEnabled ?? false
    }

    var l10nKeepEnglishOptions: Bool {
        snapshot?.preferences.l10nKeepEnglishOptions ?? true
    }

    var l10nStatus: L10nStatus? {
        snapshot?.l10n
    }

    var visibleQuotaGroups: [QuotaGroup] {
        guard let groups = snapshot?.quota.groups else { return [] }
        return hideNonGeminiModels ? groups.filter { $0.isGemini } : groups
    }

    var primaryGeminiGroup: QuotaGroup? {
        guard let groups = snapshot?.quota.groups else { return nil }
        return groups.first(where: { $0.isGemini && $0.name.lowercased().contains("gemini models") })
            ?? groups.first(where: { $0.isGemini })
    }

    /// Strictly resolves the Gemini weekly quota bucket (never falls back to 5h window).
    var weeklyBucket: QuotaBucket? {
        primaryGeminiGroup?.buckets.first(where: { bucket in
            let w = bucket.window.lowercased()
            let id = bucket.id.lowercased()
            let name = bucket.name.lowercased()
            return w == "weekly" || w == "7d" || id.contains("weekly") || name.contains("weekly")
        })
    }

    var fiveHourBucket: QuotaBucket? {
        primaryGeminiGroup?.buckets.first(where: { $0.window.lowercased() == "5h" })
    }

    /// Headline percentage strictly locked to Gemini weekly remaining quota.
    var headlineRemainingPct: UInt32? {
        weeklyBucket?.remainingPct
    }

    /// Compact status bar readout: "<weekly>%-<5h>%" (e.g. "98%-91%").
    var menuBarLabelText: String {
        switch (weeklyBucket?.remainingPct, fiveHourBucket?.remainingPct) {
        case let (w?, h5?):
            return "\(w)%-\(h5)%"
        case let (w?, nil):
            return "\(w)%"
        default:
            return "--"
        }
    }

    func sessions(forProject projectId: String) -> [SessionTelemetry] {
        filteredSessionsByProject[projectId] ?? []
    }

    func allSessions(forProject projectId: String) -> [SessionTelemetry] {
        allSessionsByProject[projectId] ?? []
    }

    // MARK: - Fast Preferences & Account Mutations (Rust fast-path < 0.3ms)

    func updatePreferences(
        hideNonGeminiModels: Bool? = nil,
        showMenuBarQuota: Bool? = nil,
        themeMode newTheme: AppThemeMode? = nil,
        showArchivedSessions: Bool? = nil,
        l10nEnabled: Bool? = nil,
        l10nKeepEnglishOptions: Bool? = nil
    ) {
        if let newTheme {
            self.themeMode = newTheme
        }
        do {
            let res = try bridge.updatePreferences(
                hideNonGeminiModels: hideNonGeminiModels,
                showMenuBarQuota: showMenuBarQuota,
                themeMode: newTheme?.rawValue,
                showArchivedSessions: showArchivedSessions,
                l10nEnabled: l10nEnabled,
                l10nKeepEnglishOptions: l10nKeepEnglishOptions
            )
            applySnapshot(res.snapshot, resetSelection: false)
            showToast(res.message)
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func toggleL10nEnabledAsync(_ enabled: Bool) {
        guard !isRebuildingL10n && !isRelaunchingAntigravity else { return }
        isRebuildingL10n = true
        let localBridge = bridge
        Task.detached(priority: .userInitiated) {
            do {
                let res = try localBridge.updatePreferences(l10nEnabled: enabled)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isRebuildingL10n = false
                    self.applySnapshot(res.snapshot, resetSelection: false)
                    self.showToast(res.message)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isRebuildingL10n = false
                    self.showToast(error.localizedDescription)
                }
            }
        }
    }

    func installDirectPatchAsync(andRestart: Bool = false) {
        guard !isRelaunchingAntigravity && !isRebuildingL10n else { return }
        isRelaunchingAntigravity = true
        showToast(andRestart ? "正在安装直接补丁并重启 Antigravity..." : "正在安装 Antigravity 中文补丁...")
        let localBridge = bridge
        Task.detached(priority: .userInitiated) {
            do {
                let res = try localBridge.l10nAction("install_patch")
                let finalRes = andRestart ? try localBridge.l10nAction("restart_antigravity") : res
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isRelaunchingAntigravity = false
                    self.applySnapshot(finalRes.snapshot, resetSelection: false)
                    self.showToast(andRestart ? "直接补丁已安装并正常重启 Antigravity" : res.message)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isRelaunchingAntigravity = false
                    self.showToast(error.localizedDescription)
                }
            }
        }
    }

    func uninstallDirectPatchAsync() {
        guard !isRelaunchingAntigravity && !isRebuildingL10n else { return }
        isRelaunchingAntigravity = true
        let localBridge = bridge
        Task.detached(priority: .userInitiated) {
            do {
                let res = try localBridge.l10nAction("uninstall_patch")
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isRelaunchingAntigravity = false
                    self.applySnapshot(res.snapshot, resetSelection: false)
                    self.showToast(res.message)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isRelaunchingAntigravity = false
                    self.showToast(error.localizedDescription)
                }
            }
        }
    }

    func restartAntigravityNormallyAsync() {
        guard !isRelaunchingAntigravity else { return }
        isRelaunchingAntigravity = true
        showToast("正在正常重启 Antigravity...")
        let localBridge = bridge
        Task.detached(priority: .userInitiated) {
            do {
                let res = try localBridge.l10nAction("restart_antigravity")
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isRelaunchingAntigravity = false
                    self.applySnapshot(res.snapshot, resetSelection: false)
                    self.showToast(res.message)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isRelaunchingAntigravity = false
                    self.showToast(error.localizedDescription)
                }
            }
        }
    }

    func rebuildL10nOverlayAsync() {
        guard !isRebuildingL10n else { return }
        isRebuildingL10n = true
        let localBridge = bridge
        Task.detached(priority: .userInitiated) {
            do {
                let res = try localBridge.l10nAction("rebuild")
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isRebuildingL10n = false
                    self.applySnapshot(res.snapshot, resetSelection: false)
                    self.showToast(res.message)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isRebuildingL10n = false
                    self.showToast(error.localizedDescription)
                }
            }
        }
    }

    func openCustomTranslationsFile() {
        do {
            let res = try bridge.l10nAction("ensure_custom_file")
            applySnapshot(res.snapshot, resetSelection: false)
            let url = URL(fileURLWithPath: res.snapshot.l10n.customFilePath)
            NSWorkspace.shared.open(url)
            showToast("已打开自定义词条文件")
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func copyL10nOverlayPath() {
        guard let status = l10nStatus else { return }
        if !status.overlayReady {
            rebuildL10nOverlayAsync()
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(status.overlayPath, forType: .string)
        showToast("已复制注入脚本路径")
    }

    func setThemeMode(_ mode: AppThemeMode) {
        guard themeMode != mode else { return }
        updatePreferences(themeMode: mode)
    }

    func toggleTheme() {
        let next: AppThemeMode = (themeMode == .dark) ? .light : .dark
        updatePreferences(themeMode: next)
    }

    func runAccountAction(_ action: String, email: String? = nil) {
        do {
            let res = try bridge.accountAction(action, email: email)
            applySnapshot(res.snapshot, resetSelection: false)
            showToast(res.message)
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func copySessionId(_ session: SessionTelemetry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.id, forType: .string)
        showToast("已复制 #\(session.shortId)")
    }

    func showToast(_ message: String) {
        toastMessage = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            if !Task.isCancelled {
                toastMessage = nil
            }
        }
    }
}
