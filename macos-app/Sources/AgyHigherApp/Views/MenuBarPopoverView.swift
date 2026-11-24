import AppKit
import SwiftUI

/// Restrained carbon-gray menu bar popover (quiet neutral when healthy, amber/crimson only on alert).
struct MenuBarPopoverView: View {
    @ObservedObject var store: AppStore
    @Environment(\.openWindow) private var openWindow
    var onOpenMainWindowOverride: (() -> Void)? = nil

    var body: some View {
        let theme = store.theme
        let activeEmail = store.activeAccount?.email ?? (store.snapshot?.activeEmail ?? "")
        let weeklyPct = store.weeklyBucket?.remainingPct
        let fiveHourPct = store.fiveHourBucket?.remainingPct

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(theme.activeDotColor(isActive: !activeEmail.isEmpty))
                    .frame(width: 5.5, height: 5.5)

                Text(activeEmail.isEmpty ? "同步中..." : activeEmail)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.inkPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                if let w = weeklyPct {
                    HStack(spacing: 2) {
                        Text("\(w)%")
                            .foregroundStyle(theme.quotaTextColor(remainingPct: w))
                        if let h5 = fiveHourPct {
                            Text("-")
                                .foregroundStyle(theme.inkSubtle)
                            Text("\(h5)%")
                                .foregroundStyle(theme.quotaTextColor(remainingPct: h5))
                        }
                    }
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                } else {
                    Text("--")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(theme.inkMuted)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            HairlineDivider(theme: theme, axis: .horizontal)

            VStack(alignment: .leading, spacing: 10) {
                if store.visibleQuotaGroups.isEmpty {
                    Text("暂无额度数据")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.inkMuted)
                } else {
                    ForEach(store.visibleQuotaGroups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.name)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(theme.inkMuted)

                            ForEach(group.buckets) { bucket in
                                VStack(alignment: .leading, spacing: 3.5) {
                                    HStack {
                                        Text(bucket.window == "weekly" ? "周" : (bucket.window == "5h" ? "5h" : bucket.name))
                                            .font(.system(size: 11))
                                            .foregroundStyle(theme.inkMuted)
                                        Spacer()
                                        Text(bucket.resetCountdown)
                                            .font(.system(size: 10.5).monospacedDigit())
                                            .foregroundStyle(theme.inkSubtle)
                                        Text("\(bucket.remainingPct)%")
                                            .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                                            .foregroundStyle(theme.quotaTextColor(remainingPct: bucket.remainingPct))
                                            .frame(width: 34, alignment: .trailing)
                                    }
                                    ToolProgressBar(
                                        progress: bucket.remainingFraction,
                                        fillColor: theme.quotaBarColor(remainingPct: bucket.remainingPct),
                                        theme: theme,
                                        height: 3
                                    )
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            if let session = store.liveActiveSession {
                HairlineDivider(theme: theme, axis: .horizontal)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(theme.activeDotColor(isActive: session.isLiveActive))
                            .frame(width: 5, height: 5)
                        Text(session.isLiveActive ? "当前活跃上下文" : "最近会话上下文")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(theme.inkMuted)
                        Spacer()
                        Text("\(session.ctxPct)%")
                            .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(theme.occupancyTextColor(ctxPct: session.ctxPct))
                    }
                    Text(session.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.inkPrimary)
                        .lineLimit(1)
                    ToolProgressBar(
                        progress: Double(session.ctxPct) / 100.0,
                        fillColor: theme.occupancyBarColor(ctxPct: session.ctxPct),
                        theme: theme,
                        height: 3
                    )
                    Text("\(formatCompactTokens(session.ctxUsedTokens)) / \(formatCompactTokens(session.ctxLimitTokens)) · \(session.model)")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(theme.inkMuted)
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            if let accounts = store.snapshot?.accounts, accounts.count > 1 {
                HairlineDivider(theme: theme, axis: .horizontal)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(accounts.prefix(4)) { acc in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(theme.activeDotColor(isActive: acc.isActive))
                                .frame(width: 5, height: 5)
                            Text(acc.email)
                                .font(.system(size: 11, weight: acc.isActive ? .semibold : .regular))
                                .foregroundStyle(acc.isActive ? theme.inkPrimary : theme.inkSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            if let pct = acc.weeklyRemainingPct {
                                Text("\(pct)%")
                                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(theme.quotaTextColor(remainingPct: pct))
                            } else {
                                Text("--")
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(theme.inkMuted)
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
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

                ToolButton(
                    title: "打开主面板",
                    theme: theme,
                    style: .primary
                ) {
                    openMainDashboardWindow()
                }

                Spacer()

                ToolButton(
                    title: "退出",
                    theme: theme,
                    style: .ghost
                ) {
                    NSApp.terminate(nil)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(width: 300)
        .background(theme.bgElevated)
        .preferredColorScheme(theme.preferredColorScheme)
        .onAppear {
            store.refresh(showFeedback: false)
        }
    }

    private func openMainDashboardWindow() {
        if let override = onOpenMainWindowOverride {
            override()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        if let existing = NSApp.windows.first(where: { $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized) }) {
            if existing.isMiniaturized {
                existing.deminiaturize(nil)
            }
            existing.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main-dashboard")
        }
    }
}
