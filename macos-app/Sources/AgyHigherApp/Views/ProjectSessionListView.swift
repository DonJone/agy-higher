import SwiftUI

/// Left sidebar (#101012):
/// 1. Project & Session tree (empty folders collapse by default)
/// 2. Bottom-left compact Usage Dock (two 3px bars for Weekly & 5h quota)
struct ProjectSessionListView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        let theme = store.theme

        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ToolSearchField(
                    placeholder: STCopy.Sidebar.searchPlaceholder,
                    text: $store.searchQuery,
                    theme: theme
                )

                SidebarIconButton(
                    systemName: "arrow.clockwise",
                    help: STCopy.Action.refreshSessions,
                    isDisabled: store.isRefreshingSessions,
                    theme: theme
                ) {
                    store.refresh(showFeedback: true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 8)

            if store.visibleProjects.isEmpty {
                VStack {
                    Spacer()
                    Text(store.searchQuery.isEmpty ? STCopy.Sidebar.emptyProjects : STCopy.Sidebar.emptyMatches)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.inkMuted)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(store.visibleProjects) { project in
                            let items = store.sessions(forProject: project.id)
                            if !items.isEmpty || store.searchQuery.isEmpty {
                                ProjectSectionView(
                                    project: project,
                                    sessions: items,
                                    isCollapsed: store.isProjectCollapsed(project),
                                    isProjectSelected: store.selectedProjectId == project.id,
                                    selectedSessionId: store.selectedSessionId,
                                    theme: theme,
                                    onToggleCollapse: { store.toggleProjectCollapsed(project) },
                                    onSelectProject: { store.selectProject(project) },
                                    onSelectSession: { store.selectSession($0) }
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                }
            }

            HairlineDivider(theme: theme, axis: .horizontal)
            SidebarQuotaDock(store: store, theme: theme)
        }
        .frame(width: 262)
        .frame(maxHeight: .infinity)
        .background(theme.bgSidebar)
    }
}

// MARK: - Bottom-Left Compact Usage Dock

private struct SidebarQuotaDock: View {
    @ObservedObject var store: AppStore
    let theme: MonochromeTheme

    @StateObject private var hover = HoverState()

    var body: some View {
        let weekly = store.weeklyBucket
        let fiveH = store.fiveHourBucket
        let quota = store.snapshot?.quota

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(STCopy.Sidebar.quotaTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.inkSecondary)

                if let plan = quota?.planLabel, !plan.isEmpty {
                    Text(plan)
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.inkMuted)
                        .lineLimit(1)
                }

                Spacer()

                SidebarIconButton(
                    systemName: "arrow.clockwise",
                    help: STCopy.Action.refreshQuota,
                    isDisabled: store.isSyncingQuota,
                    theme: theme
                ) {
                    store.refreshLiveQuotaAsync(silent: false)
                }
            }

            if weekly == nil && fiveH == nil {
                Text(quota?.error ?? (store.isSyncingQuota ? STCopy.State.syncing : STCopy.Sidebar.noQuotaPrompt))
                    .font(.system(size: 11))
                    .foregroundStyle(quota?.error != nil ? theme.alertRed : theme.inkMuted)
                    .lineLimit(1)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    if let w = weekly {
                        CompactQuotaLine(
                            label: STCopy.Sidebar.weeklyRemaining,
                            pct: w.remainingPct,
                            fraction: w.remainingFraction,
                            theme: theme
                        )
                    }
                    if let h5 = fiveH {
                        CompactQuotaLine(
                            label: STCopy.Sidebar.fiveHourWindow,
                            pct: h5.remainingPct,
                            fraction: h5.remainingFraction,
                            theme: theme
                        )
                    }
                }
            }

            if let reset = weekly?.resetCountdown, !reset.isEmpty {
                HStack {
                    Text(reset)
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(theme.inkSubtle)
                        .lineLimit(1)
                    Spacer()
                    Button(STCopy.Action.details) {
                        store.openSettings(.accounts)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(hover.isHovered ? theme.inkPrimary : theme.inkMuted)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(hover.isHovered ? theme.bgHover.opacity(0.6) : Color.clear)
        .onHover { hover.isHovered = $0 }
    }
}

private struct CompactQuotaLine: View {
    let label: String
    let pct: UInt32
    let fraction: Double
    let theme: MonochromeTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.inkMuted)
                Spacer()
                Text("\(pct)%")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(theme.quotaTextColor(remainingPct: pct))
            }
            ToolProgressBar(
                progress: fraction,
                fillColor: theme.quotaBarColor(remainingPct: pct),
                theme: theme,
                height: 3
            )
        }
    }
}

// MARK: - Project Folder & Session Rows

private struct SidebarIconButton: View {
    let systemName: String
    let help: String
    var isDisabled: Bool = false
    let theme: MonochromeTheme
    let action: () -> Void

    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hover.isHovered ? theme.inkPrimary : theme.inkMuted)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(hover.isHovered ? theme.bgSelected : Color.clear)
                )
                .opacity(isDisabled ? 0.4 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hover.isHovered = $0 }
        .help(help)
    }
}

private struct ProjectSectionView: View {
    let project: NativeProject
    let sessions: [SessionTelemetry]
    let isCollapsed: Bool
    let isProjectSelected: Bool
    let selectedSessionId: String?
    let theme: MonochromeTheme
    let onToggleCollapse: () -> Void
    let onSelectProject: () -> Void
    let onSelectSession: (String) -> Void

    @StateObject private var hover = HoverState()

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 2) {
                Button(action: onToggleCollapse) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(theme.inkSubtle)
                        .frame(width: 18, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: onSelectProject) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 10.5))
                            .foregroundStyle(isProjectSelected ? theme.inkPrimary : theme.inkSubtle)

                        Text(project.name)
                            .font(.system(size: 12, weight: isProjectSelected ? .semibold : .medium))
                            .foregroundStyle(
                                isProjectSelected
                                    ? theme.inkPrimary
                                    : (sessions.isEmpty ? theme.inkMuted : theme.inkSecondary)
                            )
                            .lineLimit(1)

                        Spacer()

                        Text("\(sessions.count)")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(isProjectSelected ? theme.inkSecondary : theme.inkSubtle)
                    }
                    .padding(.vertical, 4.5)
                    .padding(.trailing, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isProjectSelected ? theme.bgSelected : (hover.isHovered ? theme.bgHover : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(isProjectSelected ? theme.borderControl : Color.clear, lineWidth: 1)
            )
            .onHover { hover.isHovered = $0 }

            if !isCollapsed {
                if sessions.isEmpty {
                    Text(STCopy.Sidebar.emptySessions)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.inkSubtle)
                        .padding(.leading, 26)
                        .padding(.vertical, 3)
                } else {
                    ForEach(sessions) { session in
                        SessionRowView(
                            session: session,
                            isSelected: session.id == selectedSessionId,
                            theme: theme
                        ) {
                            onSelectSession(session.id)
                        }
                    }
                }
            }
        }
        .padding(.bottom, 3)
    }
}

private struct SessionRowView: View {
    let session: SessionTelemetry
    let isSelected: Bool
    let theme: MonochromeTheme
    let action: () -> Void

    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(theme.activeDotColor(isActive: session.isLiveActive))
                        .frame(width: 5, height: 5)

                    Text(session.title)
                        .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? theme.inkPrimary : theme.inkSecondary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if session.isArchived {
                        Text(STCopy.State.archived)
                            .font(.system(size: 9.5))
                            .foregroundStyle(theme.inkSubtle)
                    }
                    if session.isStarred {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(theme.inkMuted)
                    }
                    if session.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(theme.inkSubtle)
                    }
                }

                HStack(spacing: 6) {
                    Text(STCopy.shortModel(session.model))
                        .font(.system(size: 10.5))
                        .foregroundStyle(isSelected ? theme.inkMuted : theme.inkSubtle)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if session.ctxUsedK > 0 {
                        HStack(spacing: 3) {
                            Text("\(session.ctxPct)%")
                                .foregroundStyle(theme.occupancyTextColor(ctxPct: session.ctxPct, secondaryWhenNormal: !isSelected))
                            Text("·")
                                .foregroundStyle(isSelected ? theme.inkMuted : theme.inkSubtle)
                            Text("\(session.ctxUsedK)k")
                                .foregroundStyle(isSelected ? theme.inkMuted : theme.inkSubtle)
                        }
                        .font(.system(size: 10.5, weight: session.ctxPct > 80 ? .semibold : .regular).monospacedDigit())
                    } else {
                        Text("\(session.stepCount) 步")
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(isSelected ? theme.inkMuted : theme.inkSubtle)
                    }
                }
                .padding(.leading, 11)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? theme.bgSelected : (hover.isHovered ? theme.bgHover : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(isSelected ? theme.borderControl : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hover.isHovered = $0 }
        .padding(.leading, 12)
    }
}
