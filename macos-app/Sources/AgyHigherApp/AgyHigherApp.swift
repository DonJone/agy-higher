import AppKit
import SwiftUI

final class AgyHigherAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: "--verify-snapshots"), idx + 1 < args.count {
            let outDir = args[idx + 1]
            NSApp.setActivationPolicy(.prohibited)
            Task { @MainActor in
                SnapshotRenderer.renderAll(to: outDir)
                NSApp.terminate(nil)
            }
            return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@MainActor
private enum SnapshotRenderer {
    static func renderAll(to outDir: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let store = AppStore(sandboxOverride: true, autoSyncLiveQuota: false, synchronousBootstrap: true)
        let size = CGSize(width: 1360, height: 840)

        // 1. Dark Session Inspector (calm carbon gray + bottom-left 3px quota dock + 4 borderless KPIs + Inspector KV list)
        store.themeMode = .dark
        store.activeTab = .dashboard
        if let first = store.snapshot?.sessions.first {
            store.selection = .session(first.id)
        }
        render(view: RootShellView(store: store).preferredColorScheme(.dark), size: size, to: "\(outDir)/v5-01-session-dark.png")

        // 2. Dark Project Folder Overview (clicking Donby folder shows all sessions under Donby)
        if let donbyProj = store.snapshot?.projects.first(where: { $0.name == "Donby" }) {
            store.selection = .project(donbyProj.id)
        }
        render(view: RootShellView(store: store).preferredColorScheme(.dark), size: size, to: "\(outDir)/v5-02-folder-dark.png")

        // 3. Light Session Inspector
        store.themeMode = .light
        if let first = store.snapshot?.sessions.first {
            store.selection = .session(first.id)
        }
        render(view: RootShellView(store: store).preferredColorScheme(.light), size: size, to: "\(outDir)/v5-03-session-light.png")

        // 4. Dark Alert States (8% red quota in sidebar dock + 24% amber 5h + 86% red context occupancy)
        store.themeMode = .dark
        store.activeTab = .dashboard
        injectAlertDemoState(store: store)
        if let first = store.snapshot?.sessions.first {
            store.selection = .session(first.id)
        }
        render(view: RootShellView(store: store).preferredColorScheme(.dark), size: size, to: "\(outDir)/v5-04-alert-states-dark.png")

        // 5. Top-Right Account Dropdown Popover (2 accounts: 8% red + 82% calm neutral)
        render(
            view: AccountDropdownPopoverView(store: store).preferredColorScheme(.dark),
            size: CGSize(width: 310, height: 245),
            to: "\(outDir)/v5-05-account-popover-dark.png"
        )

        // 6. Settings — Accounts Pane (Dark, 2-Pane Linear Architecture)
        store.activeTab = .accounts
        store.activeSettingsSection = .accounts
        render(view: RootShellView(store: store).preferredColorScheme(.dark), size: size, to: "\(outDir)/v5-06-accounts-settings-dark.png")

        // 7. Settings — L10n Pane (Dark, above the fold)
        store.activeSettingsSection = .l10n
        render(view: RootShellView(store: store).preferredColorScheme(.dark), size: size, to: "\(outDir)/v6-08-settings-l10n-dark.png")

        // 8. Menu Bar Popover (Dark)
        render(
            view: MenuBarPopoverView(store: store, onOpenMainWindowOverride: {}).preferredColorScheme(.dark),
            size: CGSize(width: 300, height: 390),
            to: "\(outDir)/v5-07-menubar-popover-dark.png"
        )
    }

    private static func injectAlertDemoState(store: AppStore) {
        guard let snap = store.snapshot else { return }
        var alertGroups = snap.quota.groups
        if !alertGroups.isEmpty, alertGroups[0].buckets.count >= 2 {
            let b0 = alertGroups[0].buckets[0]
            let b1 = alertGroups[0].buckets[1]
            alertGroups[0] = QuotaGroup(
                name: alertGroups[0].name,
                description: alertGroups[0].description,
                isGemini: true,
                buckets: [
                    QuotaBucket(
                        id: b0.id, name: b0.name, window: b0.window,
                        remainingFraction: 0.08, remainingPct: 8,
                        resetTime: b0.resetTime, resetCountdown: "5 天 3 小时后重置",
                        description: b0.description
                    ),
                    QuotaBucket(
                        id: b1.id, name: b1.name, window: b1.window,
                        remainingFraction: 0.24, remainingPct: 24,
                        resetTime: b1.resetTime, resetCountdown: "1 小时 12 分钟后重置",
                        description: b1.description
                    )
                ]
            )
        }
        let alertQuota = QuotaSnapshot(
            source: snap.quota.source,
            accountEmail: "donnnyjuan@gmail.com",
            authMethod: snap.quota.authMethod,
            planLabel: snap.quota.planLabel,
            activeModelId: snap.quota.activeModelId,
            activeModelLabel: snap.quota.activeModelLabel,
            remainingCredits: snap.quota.remainingCredits,
            upgradeUri: snap.quota.upgradeUri,
            description: snap.quota.description,
            groups: alertGroups,
            fetchedAt: snap.quota.fetchedAt,
            isCached: false,
            error: nil
        )
        var sessions = snap.sessions
        if let first = sessions.first {
            sessions[0] = SessionTelemetry(
                id: first.id, shortId: first.shortId,
                projectId: first.projectId, projectName: first.projectName,
                cwd: first.cwd, shortPath: first.shortPath,
                workspacePaths: first.workspacePaths, title: first.title,
                preview: first.preview, lastUserPrompt: first.lastUserPrompt,
                isPinned: first.isPinned, isStarred: first.isStarred,
                isArchived: first.isArchived, tags: first.tags,
                status: first.status,
                isLiveActive: true, branch: first.branch,
                workspaceRuleFiles: first.workspaceRuleFiles,
                artifactFiles: first.artifactFiles, model: first.model,
                modelsUsed: first.modelsUsed,
                ctxUsedTokens: 438_200, ctxLimitTokens: 512_000,
                ctxUsedK: 438, ctxTotalK: 512, ctxPct: 86,
                breakdown: ContextBreakdown(rulesK: 16, cacheK: 392, freshInputK: 24, outputK: 6, freeK: 74),
                totalInputTokens: first.totalInputTokens,
                totalCacheReadTokens: first.totalCacheReadTokens,
                totalOutputTokens: first.totalOutputTokens,
                totalThinkingTokens: first.totalThinkingTokens,
                cacheHitPct: first.cacheHitPct, costUsd: first.costUsd,
                stepCount: first.stepCount, llmTurns: first.llmTurns,
                userTurns: first.userTurns, assistantTurns: first.assistantTurns,
                toolCallCount: first.toolCallCount,
                topTools: [ToolUsageStat(name: "read_file", count: 18), ToolUsageStat(name: "edit_file", count: 9)],
                checkpointCount: first.checkpointCount, subagentCount: first.subagentCount,
                isCompactedPendingTurn: false,
                telemetryOrigin: first.telemetryOrigin,
                createdAt: first.createdAt, lastModified: first.lastModified
            )
        }
        let acc1 = AccountProfile(
            email: "donnnyjuan@gmail.com", initial: "D",
            authMethod: "consumer", planLabel: "Google AI Pro",
            isActive: true, lastSeenAt: "2026-11-23 15:44",
            quotaSummaryText: "周 8% · 5h 24%",
            weeklyRemainingPct: 8, fiveHourRemainingPct: 24,
            resetCountdown: "5 天 3 小时后重置", remainingCredits: 0,
            quotaUpdatedAt: snap.quota.fetchedAt, cachedQuota: alertQuota
        )
        let acc2 = AccountProfile(
            email: "ananmagoro701@gmail.com", initial: "A",
            authMethod: "consumer", planLabel: "Google AI Pro",
            isActive: false, lastSeenAt: "2026-11-23 15:40",
            quotaSummaryText: "周 82% · 5h 67%",
            weeklyRemainingPct: 82, fiveHourRemainingPct: 67,
            resetCountdown: "5 天 17 小时后重置", remainingCredits: 0,
            quotaUpdatedAt: snap.quota.fetchedAt, cachedQuota: snap.quota
        )
        store.applySnapshot(
            DashboardSnapshot(
                sandboxMode: true,
                sessionCount: sessions.count,
                projects: snap.projects,
                sessions: sessions,
                quota: alertQuota,
                accounts: [acc1, acc2],
                activeEmail: "donnnyjuan@gmail.com",
                preferences: snap.preferences,
                l10n: snap.l10n,
                lastScannedAt: snap.lastScannedAt
            ),
            resetSelection: false
        )
    }

    private static func render<V: View>(view: V, size: CGSize, to path: String) {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}

private struct WindowChromeConfigurator: NSViewRepresentable {
    let bgHex: UInt32
    let isDark: Bool

    final class Coordinator {
        var lastWindowId: ObjectIdentifier?
        var lastIsDark: Bool?
        var lastBgHex: UInt32?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coord = context.coordinator
        DispatchQueue.main.async {
            applyIfNeeded(to: view.window, coordinator: coord)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coord = context.coordinator
        guard let win = nsView.window else {
            DispatchQueue.main.async {
                applyIfNeeded(to: nsView.window, coordinator: coord)
            }
            return
        }
        applyIfNeeded(to: win, coordinator: coord)
    }

    /// Guard strictly so AppKit window.appearance & backing layers are NEVER re-invalidated on normal redraws.
    private func applyIfNeeded(to window: NSWindow?, coordinator: Coordinator) {
        guard let window else { return }
        let winId = ObjectIdentifier(window)
        if coordinator.lastWindowId == winId
            && coordinator.lastIsDark == isDark
            && coordinator.lastBgHex == bgHex
        {
            return
        }
        coordinator.lastWindowId = winId
        coordinator.lastIsDark = isDark
        coordinator.lastBgHex = bgHex

        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        let r = CGFloat((bgHex >> 16) & 0xFF) / 255.0
        let g = CGFloat((bgHex >> 8) & 0xFF) / 255.0
        let b = CGFloat(bgHex & 0xFF) / 255.0
        window.backgroundColor = NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
        window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }
}

@main
struct AgyHigherApp: App {
    @NSApplicationDelegateAdaptor(AgyHigherAppDelegate.self) var appDelegate
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup(STCopy.windowTitle, id: "main-dashboard") {
            RootShellView(store: store)
                .frame(minWidth: 980, idealWidth: 1320, minHeight: 640, idealHeight: 820)
                .preferredColorScheme(store.theme.preferredColorScheme)
                .tint(store.theme.inkPrimary)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button(STCopy.Action.checkUpdatesMenu) {
                    store.openSettings(.updates)
                    Task {
                        await AppUpdateManager.shared.checkForUpdates(manual: true)
                    }
                }
            }
            CommandGroup(after: .toolbar) {
                Button(STCopy.Action.refreshSessions) {
                    store.refresh(showFeedback: true)
                }
                .keyboardShortcut("r", modifiers: .command)

                Button(STCopy.Action.refreshQuota) {
                    store.refreshLiveQuotaAsync(silent: false)
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])

                Button(STCopy.Action.toggleTheme) {
                    store.toggleTheme()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra(
            isInserted: Binding(
                get: { store.showMenuBarQuota },
                set: { newValue in
                    guard newValue != store.showMenuBarQuota else { return }
                    DispatchQueue.main.async {
                        store.updatePreferences(showMenuBarQuota: newValue)
                    }
                }
            )
        ) {
            MenuBarPopoverView(store: store)
        } label: {
            HStack(spacing: 4) {
                Image(nsImage: BrandIconFactory.menuBarTemplateImage)
                Text(store.menuBarLabelText)
                    .monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
    }
}

/// Full-bleed Linear / Raycast / Cursor desktop shell:
/// Sidebar (#101012) + Topbar (#101012) form a seamless dark frame around the brighter Main Canvas (#161618).
struct RootShellView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        let theme = store.theme

        ZStack {
            theme.bgCanvas.ignoresSafeArea()

            WindowChromeConfigurator(
                bgHex: store.themeMode == .dark ? 0x101012 : 0xF5F5F7,
                isDark: store.themeMode == .dark
            )
            .frame(width: 0, height: 0)

            VStack(spacing: 0) {
                TopBarView(store: store)
                HairlineDivider(theme: theme, axis: .horizontal)

                if store.activeTab == .dashboard {
                    HStack(spacing: 0) {
                        ProjectSessionListView(store: store)
                        HairlineDivider(theme: theme, axis: .vertical)
                        TelemetryDashboardView(store: store)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    AccountsSettingsView(store: store)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .ignoresSafeArea(.container, edges: .top)

            if let toast = store.toastMessage {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.inkPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(theme.bgElevated)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(theme.borderControl, lineWidth: 1)
                        )
                        .padding(.bottom, 16)
                }
                .allowsHitTesting(false)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.14), value: store.toastMessage)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshOnActivateIfStale()
        }
        .task {
            let args = ProcessInfo.processInfo.arguments
            if !args.contains("--verify-snapshots") && !args.contains("--sandbox") {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await AppUpdateManager.shared.checkForUpdatesIfAutoEnabled()
            }
        }
    }
}
