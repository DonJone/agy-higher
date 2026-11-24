import SwiftUI

/// STE-STC Two-Pane Settings Workspace (Linear / Raycast architecture):
/// - Left 200px Domain Rail (#101012): 账户 / 显示 / 中文拓展 / 更新
/// - Right Focused Canvas (#161618): Single active domain above the fold, zero scroll walls, zero prose clutter.
struct AccountsSettingsView: View {
    @ObservedObject var store: AppStore
    @ObservedObject private var updater = AppUpdateManager.shared

    var body: some View {
        let theme = store.theme

        HStack(spacing: 0) {
            SettingsDomainRail(store: store, updater: updater, theme: theme)
            HairlineDivider(theme: theme, axis: .vertical)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    switch store.activeSettingsSection {
                    case .accounts:
                        AccountsDomainPane(store: store, theme: theme)
                    case .display:
                        DisplayDomainPane(store: store, theme: theme)
                    case .l10n:
                        L10nDomainPane(store: store, theme: theme)
                    case .updates:
                        UpdatesDomainPane(updater: updater, theme: theme)
                    }
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 28)
                .frame(maxWidth: 880, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.bgCanvas)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Left Settings Rail (#101012)

private struct SettingsDomainRail: View {
    @ObservedObject var store: AppStore
    @ObservedObject var updater: AppUpdateManager
    let theme: MonochromeTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsSection.allCases) { section in
                SettingsRailItem(
                    section: section,
                    isSelected: store.activeSettingsSection == section,
                    trailingText: trailingLabel(for: section),
                    showAccentDot: shouldHighlightDot(for: section),
                    theme: theme
                ) {
                    store.activeSettingsSection = section
                }
            }

            Spacer()

            HairlineDivider(theme: theme, axis: .horizontal, subtle: true)
                .padding(.vertical, 10)

            HStack {
                Text(STCopy.appName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.inkSubtle)
                Spacer()
                Text("v\(AppUpdateManager.currentVersion)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.inkSubtle)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .frame(width: 200)
        .frame(maxHeight: .infinity)
        .background(theme.bgSidebar)
    }

    private func trailingLabel(for section: SettingsSection) -> String? {
        switch section {
        case .accounts:
            let count = store.snapshot?.accounts.count ?? 0
            return count > 0 ? "\(count)" : nil
        case .display:
            return nil
        case .l10n:
            guard let l10n = store.l10nStatus else { return nil }
            return l10n.patchInstalled ? STCopy.State.patched : STCopy.State.unpatched
        case .updates:
            if let rel = updater.availableRelease {
                return "v\(rel.version)"
            }
            return "v\(AppUpdateManager.currentVersion)"
        }
    }

    private func shouldHighlightDot(for section: SettingsSection) -> Bool {
        switch section {
        case .updates:
            return updater.availableRelease != nil
        default:
            return false
        }
    }
}

private struct SettingsRailItem: View {
    let section: SettingsSection
    let isSelected: Bool
    let trailingText: String?
    let showAccentDot: Bool
    let theme: MonochromeTheme
    let action: () -> Void

    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: section.iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? theme.inkPrimary : theme.inkMuted)
                    .frame(width: 16)

                Text(section.title)
                    .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? theme.inkPrimary : (hover.isHovered ? theme.inkPrimary : theme.inkSecondary))

                Spacer(minLength: 4)

                if showAccentDot {
                    Circle()
                        .fill(theme.alertAmber)
                        .frame(width: 5.5, height: 5.5)
                }

                if let trailingText {
                    Text(trailingText)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(isSelected ? theme.inkSecondary : theme.inkSubtle)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? theme.bgSelected : (hover.isHovered ? theme.bgHover : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(isSelected ? theme.borderControl : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.isHovered = $0 }
    }
}

// MARK: - Domain 1: Accounts & Quota Archive

private struct AccountsDomainPane: View {
    @ObservedObject var store: AppStore
    let theme: MonochromeTheme

    var body: some View {
        let accounts = store.snapshot?.accounts ?? []

        VStack(alignment: .leading, spacing: 0) {
            STSectionHeader(
                title: STCopy.Accounts.title,
                meta: "\(accounts.count)",
                theme: theme
            ) {
                if store.inactiveAccountCount > 0 {
                    ToolButton(title: STCopy.Action.clearInactive, theme: theme, style: .danger) {
                        store.runAccountAction("clear_inactive")
                    }
                }
                ToolButton(
                    title: store.isSyncingQuota ? STCopy.State.syncing : STCopy.Action.refreshAccounts,
                    theme: theme,
                    style: .primary,
                    isDisabled: store.isSyncingQuota
                ) {
                    store.refreshLiveQuotaAsync(silent: false)
                }
            }

            HairlineDivider(theme: theme, axis: .horizontal)

            if accounts.isEmpty {
                Text(STCopy.Accounts.empty)
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.inkMuted)
                    .padding(.vertical, 24)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(accounts.enumerated()), id: \.element.id) { idx, acc in
                        if idx > 0 {
                            HairlineDivider(theme: theme, axis: .horizontal, subtle: true)
                        }
                        FlatAccountRow(
                            account: acc,
                            hideNonGemini: store.hideNonGeminiModels,
                            theme: theme,
                            onRemoveCache: {
                                store.runAccountAction("remove_cached", email: acc.email)
                            }
                        )
                    }
                }
            }
        }
    }
}

private struct FlatAccountRow: View {
    let account: AccountProfile
    let hideNonGemini: Bool
    let theme: MonochromeTheme
    let onRemoveCache: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                Circle()
                    .fill(theme.activeDotColor(isActive: account.isActive))
                    .frame(width: 6.5, height: 6.5)

                Text(account.email)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(theme.inkPrimary)

                if account.isActive {
                    Text(STCopy.State.current)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.inkSecondary)
                }

                Text("·").foregroundStyle(theme.inkSubtle)
                Text(account.planLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.inkMuted)

                Text("·").foregroundStyle(theme.inkSubtle)
                Text(account.resetCountdown)
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(theme.inkMuted)

                Text("·").foregroundStyle(theme.inkSubtle)
                Text(account.lastSeenAt)
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(theme.inkSubtle)

                Spacer()

                if !account.isActive {
                    ToolButton(title: STCopy.Action.removeCache, theme: theme, style: .danger, action: onRemoveCache)
                }
            }

            if let q = account.cachedQuota {
                let groups = hideNonGemini ? q.groups.filter { $0.isGemini } : q.groups
                if !groups.isEmpty {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(groups.enumerated()), id: \.element.id) { idx, g in
                            if idx > 0 {
                                HairlineDivider(theme: theme, axis: .vertical, subtle: true)
                            }
                            VStack(alignment: .leading, spacing: 7) {
                                Text(g.name)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(theme.inkMuted)

                                ForEach(g.buckets) { b in
                                    HStack(spacing: 10) {
                                        Text(b.window == "weekly" ? STCopy.Accounts.weeklyShort : (b.window == "5h" ? STCopy.Sidebar.fiveHourWindow : b.window))
                                            .font(.system(size: 11).monospacedDigit())
                                            .foregroundStyle(theme.inkSubtle)
                                            .frame(width: 20, alignment: .leading)

                                        ToolProgressBar(
                                            progress: b.remainingFraction,
                                            fillColor: theme.quotaBarColor(remainingPct: b.remainingPct),
                                            theme: theme,
                                            height: 3.5
                                        )

                                        Text("\(b.remainingPct)%")
                                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                            .foregroundStyle(theme.quotaTextColor(remainingPct: b.remainingPct))
                                            .frame(width: 38, alignment: .trailing)
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(theme.bgSurface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(theme.border, lineWidth: 1)
                    )
                    .padding(.leading, 16)
                }
            }
        }
        .padding(.vertical, 18)
    }
}

// MARK: - Domain 2: Display & Archive Preferences

private struct DisplayDomainPane: View {
    @ObservedObject var store: AppStore
    let theme: MonochromeTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            STSectionHeader(title: STCopy.Display.title, theme: theme) {
                EmptyView()
            }

            HairlineDivider(theme: theme, axis: .horizontal)

            STSettingRow(
                title: STCopy.Display.hideNonGemini,
                spec: STCopy.Display.hideNonGeminiSpec,
                theme: theme
            ) {
                ToolSwitch(isOn: store.hideNonGeminiModels, theme: theme) {
                    store.updatePreferences(hideNonGeminiModels: !store.hideNonGeminiModels)
                }
            }

            HairlineDivider(theme: theme, axis: .horizontal, subtle: true)

            STSettingRow(
                title: STCopy.Display.menuBarQuota,
                spec: STCopy.Display.menuBarQuotaSpec,
                theme: theme
            ) {
                ToolSwitch(isOn: store.showMenuBarQuota, theme: theme) {
                    store.updatePreferences(showMenuBarQuota: !store.showMenuBarQuota)
                }
            }

            HairlineDivider(theme: theme, axis: .horizontal, subtle: true)

            STSettingRow(
                title: STCopy.Display.showArchived,
                spec: STCopy.Display.showArchivedSpec,
                theme: theme
            ) {
                ToolSwitch(isOn: store.showArchivedSessions, theme: theme) {
                    store.updatePreferences(showArchivedSessions: !store.showArchivedSessions)
                }
            }

            HairlineDivider(theme: theme, axis: .horizontal, subtle: true)

            STSettingRow(
                title: STCopy.Display.theme,
                spec: STCopy.Display.themeSpec,
                theme: theme
            ) {
                STSegmentControl(
                    options: [
                        (STCopy.Display.dark, AppThemeMode.dark),
                        (STCopy.Display.light, AppThemeMode.light)
                    ],
                    selection: store.themeMode,
                    theme: theme
                ) { mode in
                    store.setThemeMode(mode)
                }
            }

            HairlineDivider(theme: theme, axis: .horizontal)
        }
    }
}

// MARK: - Domain 3: STE-STC Chinese Localization & Direct ASAR Patch

private struct L10nDomainPane: View {
    @ObservedObject var store: AppStore
    let theme: MonochromeTheme

    var body: some View {
        let l10n = store.l10nStatus
        let metaText: String = {
            guard let l10n else { return "STE-STC" }
            return "\(l10n.standard) · Antigravity \(l10n.antigravityVersion) · \(l10n.phraseCount) 词条"
        }()

        VStack(alignment: .leading, spacing: 0) {
            STSectionHeader(title: STCopy.L10n.title, meta: metaText, theme: theme) {
                if l10n?.patchInstalled == true {
                    ToolButton(
                        title: STCopy.Action.uninstallPatch,
                        theme: theme,
                        style: .danger,
                        isDisabled: store.isRelaunchingAntigravity || store.isRebuildingL10n
                    ) {
                        store.uninstallDirectPatchAsync()
                    }
                    ToolButton(
                        title: store.isRebuildingL10n ? STCopy.State.syncing : STCopy.Action.syncDict,
                        theme: theme,
                        style: .secondary,
                        isDisabled: store.isRebuildingL10n || store.isRelaunchingAntigravity
                    ) {
                        store.rebuildL10nOverlayAsync()
                    }
                    ToolButton(
                        title: store.isRelaunchingAntigravity ? STCopy.State.restarting : STCopy.Action.restartApp,
                        theme: theme,
                        style: .primary,
                        isDisabled: store.isRelaunchingAntigravity || store.isRebuildingL10n
                    ) {
                        store.restartAntigravityNormallyAsync()
                    }
                } else {
                    ToolButton(
                        title: store.isRebuildingL10n ? STCopy.State.syncing : STCopy.Action.syncDict,
                        theme: theme,
                        style: .secondary,
                        isDisabled: store.isRebuildingL10n || store.isRelaunchingAntigravity
                    ) {
                        store.rebuildL10nOverlayAsync()
                    }
                    ToolButton(
                        title: store.isRelaunchingAntigravity ? STCopy.State.installing : STCopy.Action.installPatch,
                        theme: theme,
                        style: .primary,
                        isDisabled: store.isRelaunchingAntigravity || store.isRebuildingL10n
                    ) {
                        store.installDirectPatchAsync(andRestart: true)
                    }
                }
            }

            HairlineDivider(theme: theme, axis: .horizontal)

            STSettingRow(
                title: STCopy.L10n.enable,
                spec: l10n?.patchInstalled == true ? "热切换" : "app.asar 直接补丁",
                theme: theme
            ) {
                ToolSwitch(isOn: store.l10nEnabled, theme: theme) {
                    store.toggleL10nEnabledAsync(!store.l10nEnabled)
                }
            }

            HairlineDivider(theme: theme, axis: .horizontal, subtle: true)

            STSettingRow(
                title: STCopy.L10n.keepEnglishOptions,
                spec: STCopy.L10n.keepEnglishOptionsSpec,
                theme: theme
            ) {
                ToolSwitch(isOn: store.l10nKeepEnglishOptions, theme: theme) {
                    store.updatePreferences(l10nKeepEnglishOptions: !store.l10nKeepEnglishOptions)
                }
            }

            HairlineDivider(theme: theme, axis: .horizontal, subtle: true)

            STSettingRow(
                title: STCopy.L10n.customOverlay,
                spec: l10n?.overlayReady == true ? STCopy.State.ready : STCopy.State.unbuilt,
                theme: theme
            ) {
                HStack(spacing: 8) {
                    ToolButton(title: STCopy.Action.editCustomTerms, theme: theme, style: .secondary) {
                        store.openCustomTranslationsFile()
                    }
                    ToolButton(title: STCopy.Action.copyPath, theme: theme, style: .secondary) {
                        store.copyL10nOverlayPath()
                    }
                }
            }

            if let l10n {
                HairlineDivider(theme: theme, axis: .horizontal)
                    .padding(.vertical, 18)

                HStack(alignment: .top, spacing: 44) {
                    VStack(spacing: 0) {
                        STInspectorRow(
                            key: STCopy.L10n.patchStatus,
                            value: l10n.patchInstalled
                                ? "\(STCopy.State.patched) (\(l10n.patchVersion.isEmpty ? "v2" : l10n.patchVersion))"
                                : STCopy.State.unpatched,
                            theme: theme
                        )
                        STInspectorRow(
                            key: STCopy.L10n.targetVersion,
                            value: "Antigravity \(l10n.antigravityVersion)",
                            theme: theme
                        )
                        STInspectorRow(
                            key: STCopy.L10n.backupStatus,
                            value: l10n.backupExists ? STCopy.L10n.backupReady : STCopy.L10n.backupNone,
                            isLast: true,
                            theme: theme
                        )
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 0) {
                        STInspectorRow(
                            key: STCopy.L10n.dictScale,
                            value: "\(l10n.phraseCount) + \(l10n.customRuleCount) 自定义",
                            theme: theme
                        )
                        STInspectorRow(
                            key: STCopy.L10n.scriptPath,
                            value: STCopy.abbreviateHome(l10n.overlayPath),
                            monospace: true,
                            theme: theme
                        )
                        STInspectorRow(
                            key: "SHA-256",
                            value: l10n.bundleShaShort.isEmpty ? "--" : l10n.bundleShaShort,
                            monospace: true,
                            isLast: true,
                            theme: theme
                        )
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

// MARK: - Domain 4: Built-in Auto-Updater

private struct UpdatesDomainPane: View {
    @ObservedObject var updater: AppUpdateManager
    let theme: MonochromeTheme

    var body: some View {
        let metaColor: Color = {
            if case .error = updater.state { return theme.alertRed }
            if case .available = updater.state { return theme.inkPrimary }
            return theme.inkMuted
        }()

        VStack(alignment: .leading, spacing: 0) {
            STSectionHeader(
                title: STCopy.Updates.title,
                meta: updater.statusSummaryText,
                metaColor: metaColor,
                theme: theme
            ) {
                if case .downloading = updater.state {
                    ToolButton(title: STCopy.Action.cancelDownload, theme: theme, style: .danger) {
                        updater.cancelDownload()
                    }
                } else if let release = updater.availableRelease {
                    ToolButton(title: STCopy.Action.openReleases, theme: theme, style: .secondary) {
                        updater.openReleasesPage()
                    }
                    ToolButton(
                        title: updater.isBusy ? STCopy.State.updating : "安装 v\(release.version)",
                        theme: theme,
                        style: .primary,
                        isDisabled: updater.isBusy
                    ) {
                        updater.startDownloadAndInstall(release)
                    }
                } else {
                    ToolButton(title: STCopy.Action.openReleases, theme: theme, style: .secondary) {
                        updater.openReleasesPage()
                    }
                    ToolButton(
                        title: updater.isBusy ? STCopy.State.checking : STCopy.Action.checkUpdates,
                        theme: theme,
                        style: .primary,
                        isDisabled: updater.isBusy
                    ) {
                        Task {
                            await updater.checkForUpdates(manual: true)
                        }
                    }
                }
            }

            if case .downloading(_, let progress, _, _) = updater.state {
                ToolProgressBar(
                    progress: progress,
                    fillColor: theme.barNeutral,
                    theme: theme,
                    height: 3
                )
                .padding(.bottom, 12)
            }

            HairlineDivider(theme: theme, axis: .horizontal)

            STSettingRow(
                title: STCopy.Updates.autoCheck,
                spec: STCopy.Updates.autoCheckSpec,
                theme: theme
            ) {
                ToolSwitch(isOn: updater.autoCheckEnabled, theme: theme) {
                    updater.autoCheckEnabled.toggle()
                }
            }

            HairlineDivider(theme: theme, axis: .horizontal, subtle: true)

            STSettingRow(
                title: STCopy.Updates.channel,
                spec: STCopy.Updates.channelSpec,
                theme: theme
            ) {
                STSegmentControl(
                    options: [
                        (AppUpdateChannel.stable.displayTitle, AppUpdateChannel.stable),
                        (AppUpdateChannel.prerelease.displayTitle, AppUpdateChannel.prerelease)
                    ],
                    selection: updater.updateChannel,
                    theme: theme
                ) { ch in
                    updater.updateChannel = ch
                }
            }

            HairlineDivider(theme: theme, axis: .horizontal)
                .padding(.vertical, 18)

            VStack(spacing: 0) {
                STInspectorRow(
                    key: STCopy.Updates.currentVersion,
                    value: "v\(AppUpdateManager.currentVersion)",
                    monospace: true,
                    theme: theme
                )
                STInspectorRow(
                    key: STCopy.Updates.verifyPolicy,
                    value: STCopy.Updates.verifyPolicyValue,
                    theme: theme
                )
                STInspectorRow(
                    key: STCopy.Updates.repository,
                    value: AppUpdateManager.githubRepo,
                    monospace: true,
                    isLast: true,
                    theme: theme
                )
            }
        }
    }
}
