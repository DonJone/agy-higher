import SwiftUI

/// Full-bleed Linear / Raycast style Accounts & Preferences screen.
/// Quiet carbon gray (#161618), whisper dividers, restrained alerts only (<15% crimson / <30% amber).
struct AccountsSettingsView: View {
    @ObservedObject var store: AppStore
    @ObservedObject private var updater = AppUpdateManager.shared

    var body: some View {
        let theme = store.theme
        let accounts = store.snapshot?.accounts ?? []

        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Section 1: Accounts
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: 10) {
                        Text("已登录账户")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.inkPrimary)

                        Text("\(accounts.count)")
                            .font(.system(size: 12.5).monospacedDigit())
                            .foregroundStyle(theme.inkMuted)

                        Spacer()

                        if store.inactiveAccountCount > 0 {
                            ToolButton(
                                title: "清空历史缓存",
                                theme: theme,
                                style: .danger
                            ) {
                                store.runAccountAction("clear_inactive")
                            }
                        }

                        ToolButton(
                            title: store.isSyncingQuota ? "同步中..." : "刷新账户与额度",
                            theme: theme,
                            style: .primary,
                            isDisabled: store.isSyncingQuota
                        ) {
                            store.refreshLiveQuotaAsync(silent: false)
                        }
                    }
                    .padding(.bottom, 16)

                    HairlineDivider(theme: theme, axis: .horizontal)

                    if accounts.isEmpty {
                        Text("暂无已验证账户")
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
                .padding(.bottom, 28)

                HairlineDivider(theme: theme, axis: .horizontal)
                    .padding(.bottom, 24)

                // Section 2: Preferences (Compact Inspector Rows)
                VStack(alignment: .leading, spacing: 0) {
                    Text("面板设置")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.inkPrimary)
                        .padding(.bottom, 14)

                    HairlineDivider(theme: theme, axis: .horizontal)

                    FlatSettingRow(
                        title: "屏蔽非 Gemini 模型",
                        detail: "隐藏 Claude / GPT 额度分组",
                        theme: theme
                    ) {
                        ToolSwitch(isOn: store.hideNonGeminiModels, theme: theme) {
                            store.updatePreferences(hideNonGeminiModels: !store.hideNonGeminiModels)
                        }
                    }

                    HairlineDivider(theme: theme, axis: .horizontal, subtle: true)

                    FlatSettingRow(
                        title: "顶部菜单栏显示额度",
                        detail: "常驻 Gemini 周剩余-5h 百分比",
                        theme: theme
                    ) {
                        ToolSwitch(isOn: store.showMenuBarQuota, theme: theme) {
                            store.updatePreferences(showMenuBarQuota: !store.showMenuBarQuota)
                        }
                    }

                    HairlineDivider(theme: theme, axis: .horizontal, subtle: true)

                    FlatSettingRow(
                        title: "显示归档历史会话",
                        detail: "兼容 Antigravity v2.35 无限历史与归档标注",
                        theme: theme
                    ) {
                        ToolSwitch(isOn: store.showArchivedSessions, theme: theme) {
                            store.updatePreferences(showArchivedSessions: !store.showArchivedSessions)
                        }
                    }

                    HairlineDivider(theme: theme, axis: .horizontal, subtle: true)

                    FlatSettingRow(
                        title: "主题",
                        detail: "深色 / 浅色",
                        theme: theme
                    ) {
                        HStack(spacing: 2) {
                            SegmentOption(
                                title: "深色",
                                isActive: store.themeMode == .dark,
                                theme: theme
                            ) {
                                store.setThemeMode(.dark)
                            }
                            SegmentOption(
                                title: "浅色",
                                isActive: store.themeMode == .light,
                                theme: theme
                            ) {
                                store.setThemeMode(.light)
                            }
                        }
                        .padding(2)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(theme.bgSidebar)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(theme.borderControl, lineWidth: 1)
                        )
                    }

                    HairlineDivider(theme: theme, axis: .horizontal)
                }
                .padding(.bottom, 28)

                // Section 3: Chinese Localization Extension (STE-STC, Agent-Maintainable)
                VStack(alignment: .leading, spacing: 0) {
                    let l10n = store.l10nStatus

                    HStack(alignment: .center, spacing: 10) {
                        Text("中文拓展")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.inkPrimary)

                        Text(l10n?.standard ?? "STE-STC")
                            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(theme.inkMuted)

                        if let l10n {
                            Text("·").foregroundStyle(theme.inkSubtle)
                            Text("Antigravity \(l10n.antigravityVersion)")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(theme.inkMuted)
                            Text("·").foregroundStyle(theme.inkSubtle)
                            Text("\(l10n.phraseCount) 词条")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(theme.inkMuted)
                            if l10n.customRuleCount > 0 {
                                Text("·").foregroundStyle(theme.inkSubtle)
                                Text("\(l10n.customRuleCount) 自定义")
                                    .font(.system(size: 12).monospacedDigit())
                                    .foregroundStyle(theme.inkSecondary)
                            }
                        }

                        Spacer()

                        if l10n?.patchInstalled == true {
                            ToolButton(
                                title: "卸载补丁",
                                theme: theme,
                                style: .danger,
                                isDisabled: store.isRelaunchingAntigravity || store.isRebuildingL10n
                            ) {
                                store.uninstallDirectPatchAsync()
                            }

                            ToolButton(
                                title: store.isRebuildingL10n ? "同步中..." : "同步词库",
                                theme: theme,
                                style: .secondary,
                                isDisabled: store.isRebuildingL10n || store.isRelaunchingAntigravity
                            ) {
                                store.rebuildL10nOverlayAsync()
                            }

                            ToolButton(
                                title: store.isRelaunchingAntigravity ? "重启中..." : "重启 Antigravity",
                                theme: theme,
                                style: .primary,
                                isDisabled: store.isRelaunchingAntigravity || store.isRebuildingL10n
                            ) {
                                store.restartAntigravityNormallyAsync()
                            }
                        } else {
                            ToolButton(
                                title: store.isRebuildingL10n ? "同步中..." : "同步词库",
                                theme: theme,
                                style: .secondary,
                                isDisabled: store.isRebuildingL10n || store.isRelaunchingAntigravity
                            ) {
                                store.rebuildL10nOverlayAsync()
                            }

                            ToolButton(
                                title: store.isRelaunchingAntigravity ? "安装中..." : "安装中文补丁",
                                theme: theme,
                                style: .primary,
                                isDisabled: store.isRelaunchingAntigravity || store.isRebuildingL10n
                            ) {
                                store.installDirectPatchAsync(andRestart: true)
                            }
                        }
                    }
                    .padding(.bottom, 14)

                    HairlineDivider(theme: theme, axis: .horizontal)

                    FlatSettingRow(
                        title: "启用中文拓展",
                        detail: l10n?.patchInstalled == true
                            ? "已直接打补丁（\(l10n?.patchVersion ?? "v2")）· 正常启动永久生效，开关实时热切换"
                            : "尚未安装直接补丁 · 开启将自动写入 app.asar 补丁（原版自动备份）",
                        theme: theme
                    ) {
                        ToolSwitch(isOn: store.l10nEnabled, theme: theme) {
                            store.toggleL10nEnabledAsync(!store.l10nEnabled)
                        }
                    }

                    HairlineDivider(theme: theme, axis: .horizontal, subtle: true)

                    FlatSettingRow(
                        title: "选项名保留英文",
                        detail: "保留 Extra High / High / Medium / Low / Plan / Auto",
                        theme: theme
                    ) {
                        ToolSwitch(isOn: store.l10nKeepEnglishOptions, theme: theme) {
                            store.updatePreferences(l10nKeepEnglishOptions: !store.l10nKeepEnglishOptions)
                        }
                    }

                    HairlineDivider(theme: theme, axis: .horizontal, subtle: true)

                    FlatSettingRow(
                        title: "自定义词条与覆盖脚本",
                        detail: l10n?.overlayReady == true ? "已构建就绪" : "点击同步生成本地脚本",
                        theme: theme
                    ) {
                        HStack(spacing: 8) {
                            ToolButton(
                                title: "编辑自定义词条",
                                theme: theme,
                                style: .secondary
                            ) {
                                store.openCustomTranslationsFile()
                            }
                            ToolButton(
                                title: "复制脚本路径",
                                theme: theme,
                                style: .secondary
                            ) {
                                store.copyL10nOverlayPath()
                            }
                        }
                    }

                    if let l10n {
                        HairlineDivider(theme: theme, axis: .horizontal, subtle: true)
                        HStack(spacing: 8) {
                            Text("脚本路径")
                                .font(.system(size: 11.5))
                                .foregroundStyle(theme.inkMuted)
                            Text(abbreviateHome(l10n.overlayPath))
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(theme.inkSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            if !l10n.bundleShaShort.isEmpty {
                                Text(l10n.bundleShaShort)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(theme.inkSubtle)
                            }
                        }
                        .padding(.vertical, 11)
                    }

                    HairlineDivider(theme: theme, axis: .horizontal)
                }
                .padding(.bottom, 28)

                // Section 4: Built-in Auto-Updater (GitHub Releases + SHA-256 + In-Place Inode Replace)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: 10) {
                        Text("软件更新")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.inkPrimary)

                        Text("v\(AppUpdateManager.currentVersion)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(theme.inkMuted)

                        Text("·").foregroundStyle(theme.inkSubtle)

                        Text(updater.statusSummaryText)
                            .font(.system(size: 12))
                            .foregroundStyle({
                                if case .error = updater.state { return theme.alertRed }
                                if case .available = updater.state { return theme.inkPrimary }
                                return theme.inkMuted
                            }())
                            .lineLimit(1)

                        Spacer()

                        if case .downloading = updater.state {
                            ToolButton(title: "取消下载", theme: theme, style: .danger) {
                                updater.cancelDownload()
                            }
                        } else if let release = updater.availableRelease {
                            ToolButton(title: "查看发布页", theme: theme, style: .secondary) {
                                updater.openReleasesPage()
                            }
                            ToolButton(
                                title: updater.isBusy ? "更新中..." : "下载并安装 v\(release.version)",
                                theme: theme,
                                style: .primary,
                                isDisabled: updater.isBusy
                            ) {
                                updater.startDownloadAndInstall(release)
                            }
                        } else {
                            ToolButton(title: "发布页", theme: theme, style: .secondary) {
                                updater.openReleasesPage()
                            }
                            ToolButton(
                                title: updater.isBusy ? "检查中..." : "检查更新",
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
                    .padding(.bottom, 14)

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

                    FlatSettingRow(
                        title: "启动时自动检查更新",
                        detail: "优先校验 SHA-256 并原位替换，保留程序坞图标位置",
                        theme: theme
                    ) {
                        ToolSwitch(isOn: updater.autoCheckEnabled, theme: theme) {
                            updater.autoCheckEnabled.toggle()
                        }
                    }

                    HairlineDivider(theme: theme, axis: .horizontal, subtle: true)

                    FlatSettingRow(
                        title: "更新通道",
                        detail: "正式版 / 预览版（GitHub Releases）",
                        theme: theme
                    ) {
                        HStack(spacing: 2) {
                            SegmentOption(
                                title: "正式版",
                                isActive: updater.updateChannel == .stable,
                                theme: theme
                            ) {
                                updater.updateChannel = .stable
                            }
                            SegmentOption(
                                title: "预览版",
                                isActive: updater.updateChannel == .prerelease,
                                theme: theme
                            ) {
                                updater.updateChannel = .prerelease
                            }
                        }
                        .padding(2)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(theme.bgSidebar)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(theme.borderControl, lineWidth: 1)
                        )
                    }

                    HairlineDivider(theme: theme, axis: .horizontal)
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bgCanvas)
    }

    private func abbreviateHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
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
                    Text("当前")
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
                    ToolButton(
                        title: "移除缓存",
                        theme: theme,
                        style: .danger,
                        action: onRemoveCache
                    )
                }
            }

            if let q = account.cachedQuota {
                let groups = hideNonGemini ? q.groups.filter { $0.isGemini } : q.groups
                if !groups.isEmpty {
                    // Single flat layer (6px radius, whisper border, zero nested cards)
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
                                        Text(b.window == "weekly" ? "周" : (b.window == "5h" ? "5h" : b.window))
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

private struct FlatSettingRow<Control: View>: View {
    let title: String
    let detail: String
    let theme: MonochromeTheme
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.inkPrimary)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.inkMuted)
            }
            Spacer()
            control
        }
        .padding(.vertical, 14)
    }
}

private struct SegmentOption: View {
    let title: String
    let isActive: Bool
    let theme: MonochromeTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: isActive ? .medium : .regular))
                .foregroundStyle(isActive ? theme.inkPrimary : theme.inkMuted)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isActive ? theme.bgSelected : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(isActive ? theme.borderControl : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
