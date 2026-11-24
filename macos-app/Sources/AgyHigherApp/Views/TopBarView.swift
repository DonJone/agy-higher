import SwiftUI

/// Full-bleed 44px Linear/Cursor top navigation bar.
/// Right-side account trigger opens the multi-account comparison Popover on demand.
struct TopBarView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        let theme = store.theme
        let activeEmail = store.activeAccount?.email ?? (store.snapshot?.activeEmail ?? "")

        HStack(spacing: 14) {
            HStack(spacing: 7) {
                AntigravityMark()
                    .fill(theme.inkPrimary, style: FillStyle(eoFill: true))
                    .frame(width: 13.5, height: 13.5)
                Text("Antigravity")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(theme.inkPrimary)
            }
            .padding(.leading, 76)

            HairlineDivider(theme: theme, axis: .vertical)
                .frame(height: 14)

            HStack(spacing: 2) {
                NavTabItem(
                    title: "会话",
                    isActive: store.activeTab == .dashboard,
                    theme: theme
                ) {
                    store.activeTab = .dashboard
                }

                NavTabItem(
                    title: "账户与设置",
                    isActive: store.activeTab == .accounts,
                    theme: theme
                ) {
                    store.activeTab = .accounts
                }
            }

            Spacer()

            HStack(spacing: 8) {
                // Account dropdown trigger -> opens multi-account comparison Popover
                AccountPopoverTrigger(
                    email: activeEmail.isEmpty ? (store.isSyncingQuota ? "同步中..." : "未登录") : activeEmail,
                    weeklyPct: store.weeklyBucket?.remainingPct,
                    fiveHourPct: store.fiveHourBucket?.remainingPct,
                    isActive: !activeEmail.isEmpty,
                    isOpen: store.isAccountPopoverPresented,
                    theme: theme
                ) {
                    store.isAccountPopoverPresented.toggle()
                }
                .popover(isPresented: $store.isAccountPopoverPresented, arrowEdge: .bottom) {
                    AccountDropdownPopoverView(store: store)
                }

                ThemeToggleButton(mode: store.themeMode, theme: theme) {
                    store.toggleTheme()
                }
            }
            .padding(.trailing, 14)
        }
        .frame(height: 44)
        .background(theme.bgHeader)
    }
}

/// Multi-account comparison Popover tucked cleanly under the top-right account menu.
struct AccountDropdownPopoverView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        let theme = store.theme
        let accounts = store.snapshot?.accounts ?? []

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text("账户额度对比")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.inkPrimary)
                Text("\(accounts.count)")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(theme.inkMuted)
                Spacer()
                if let model = store.snapshot?.quota.activeModelLabel, !model.isEmpty {
                    Text(shortModel(model))
                        .font(.system(size: 11))
                        .foregroundStyle(theme.inkMuted)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            HairlineDivider(theme: theme, axis: .horizontal)

            if accounts.isEmpty {
                Text("暂无已验证账户")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.inkMuted)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(accounts.enumerated()), id: \.element.id) { idx, acc in
                        if idx > 0 {
                            HairlineDivider(theme: theme, axis: .horizontal, subtle: true)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(theme.activeDotColor(isActive: acc.isActive))
                                    .frame(width: 5.5, height: 5.5)
                                Text(acc.email)
                                    .font(.system(size: 12, weight: acc.isActive ? .semibold : .medium))
                                    .foregroundStyle(acc.isActive ? theme.inkPrimary : theme.inkSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                if let pct = acc.weeklyRemainingPct {
                                    Text("\(pct)%")
                                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                        .foregroundStyle(theme.quotaTextColor(remainingPct: pct))
                                } else {
                                    Text("--")
                                        .font(.system(size: 12).monospacedDigit())
                                        .foregroundStyle(theme.inkMuted)
                                }
                            }

                            if let pct = acc.weeklyRemainingPct {
                                ToolProgressBar(
                                    progress: Double(pct) / 100.0,
                                    fillColor: theme.quotaBarColor(remainingPct: pct),
                                    theme: theme,
                                    height: 3
                                )
                            }

                            HStack(spacing: 6) {
                                Text(acc.quotaSummaryText)
                                    .foregroundStyle(theme.inkMuted)
                                Text("·")
                                    .foregroundStyle(theme.inkSubtle)
                                Text(acc.resetCountdown)
                                    .foregroundStyle(theme.inkMuted)
                                    .lineLimit(1)
                            }
                            .font(.system(size: 10.5).monospacedDigit())
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                }
            }

            HairlineDivider(theme: theme, axis: .horizontal)

            HStack(spacing: 8) {
                ToolButton(
                    title: store.isSyncingQuota ? "同步中..." : "刷新额度",
                    theme: theme,
                    style: .secondary,
                    isDisabled: store.isSyncingQuota
                ) {
                    store.refreshLiveQuotaAsync(silent: false)
                }

                Spacer()

                ToolButton(
                    title: "账户与设置",
                    theme: theme,
                    style: .ghost
                ) {
                    store.isAccountPopoverPresented = false
                    store.activeTab = .accounts
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .frame(width: 310)
        .background(theme.bgElevated)
        .preferredColorScheme(theme.preferredColorScheme)
    }

    private func shortModel(_ raw: String) -> String {
        raw.replacingOccurrences(of: "Gemini ", with: "G")
            .replacingOccurrences(of: " (XHigh)", with: " XH")
            .replacingOccurrences(of: " (High)", with: " H")
    }
}

private struct NavTabItem: View {
    let title: String
    let isActive: Bool
    let theme: MonochromeTheme
    let action: () -> Void

    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: isActive ? .medium : .regular))
                .foregroundStyle(isActive ? theme.inkPrimary : (hover.isHovered ? theme.inkPrimary : theme.inkMuted))
                .padding(.horizontal, 10)
                .padding(.vertical, 4.5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isActive ? theme.bgSelected : (hover.isHovered ? theme.bgHover : Color.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(isActive ? theme.borderControl : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { hover.isHovered = $0 }
    }
}

private struct AccountPopoverTrigger: View {
    let email: String
    let weeklyPct: UInt32?
    let fiveHourPct: UInt32?
    let isActive: Bool
    let isOpen: Bool
    let theme: MonochromeTheme
    let action: () -> Void

    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Circle()
                    .fill(theme.activeDotColor(isActive: isActive))
                    .frame(width: 5.5, height: 5.5)

                Text(email)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle((hover.isHovered || isOpen) ? theme.inkPrimary : theme.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 185, alignment: .leading)

                if let w = weeklyPct {
                    HStack(spacing: 1.5) {
                        Text("\(w)%")
                            .foregroundStyle(theme.quotaTextColor(remainingPct: w))
                        if let h5 = fiveHourPct {
                            Text("-")
                                .foregroundStyle(theme.inkSubtle)
                            Text("\(h5)%")
                                .foregroundStyle(theme.quotaTextColor(remainingPct: h5))
                        }
                    }
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.inkMuted)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4.5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill((isOpen || hover.isHovered) ? theme.bgSelected : theme.bgControl.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder((isOpen || hover.isHovered) ? theme.borderHover : theme.borderControl, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hover.isHovered = $0 }
        .help("账户额度对比")
    }
}

private struct ThemeToggleButton: View {
    let mode: AppThemeMode
    let theme: MonochromeTheme
    let action: () -> Void

    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            Image(systemName: mode == .dark ? "sun.max" : "moon")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hover.isHovered ? theme.inkPrimary : theme.inkMuted)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hover.isHovered ? theme.bgSelected : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(hover.isHovered ? theme.borderControl : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { hover.isHovered = $0 }
        .help("切换深浅主题")
    }
}
