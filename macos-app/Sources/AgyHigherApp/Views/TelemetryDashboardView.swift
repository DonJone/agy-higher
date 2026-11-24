import SwiftUI

/// Main Content Canvas (#161618) — 100% focused on the active selection:
/// - Session selected -> STE-STC Session Inspector (4 borderless KPIs + 6px context bar + 2-column KV Inspector)
/// - Project selected -> Project Overview listing all sessions inside that project
struct TelemetryDashboardView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        let theme = store.theme

        ScrollView(.vertical, showsIndicators: false) {
            if let project = store.selectedProject {
                ProjectFolderOverviewView(
                    project: project,
                    sessions: store.allSessions(forProject: project.id),
                    theme: theme,
                    onSelectSession: { store.selectSession($0) }
                )
            } else if let session = store.selectedSession {
                SessionInspectorView(
                    session: session,
                    theme: theme,
                    onCopyId: { store.copySessionId(session) }
                )
            } else {
                VStack {
                    Spacer()
                    Text(STCopy.Inspector.emptySelection)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.inkMuted)
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bgCanvas)
    }
}

// MARK: - View A: STE-STC Session Inspector

private struct SessionInspectorView: View {
    let session: SessionTelemetry
    let theme: MonochromeTheme
    let onCopyId: () -> Void

    var body: some View {
        let barColor = theme.occupancyBarColor(ctxPct: session.ctxPct)
        let occTextColor = theme.occupancyTextColor(ctxPct: session.ctxPct)

        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(theme.activeDotColor(isActive: session.isLiveActive))
                            .frame(width: 7, height: 7)
                        Text(session.title)
                            .font(.system(size: 20, weight: .semibold))
                            .tracking(-0.35)
                            .foregroundStyle(theme.inkPrimary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 8) {
                        Text(session.projectName)
                            .foregroundStyle(theme.inkSecondary)
                            .fontWeight(.medium)
                        Text("·").foregroundStyle(theme.inkSubtle)
                        Text(session.shortPath).foregroundStyle(theme.inkMuted)
                        if session.branch != "-" && !session.branch.isEmpty {
                            Text("·").foregroundStyle(theme.inkSubtle)
                            Text(session.branch).foregroundStyle(theme.inkSecondary)
                        }
                        Text("·").foregroundStyle(theme.inkSubtle)
                        Text("#\(session.shortId)")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(theme.inkMuted)
                        if !session.lastModified.isEmpty {
                            Text("·").foregroundStyle(theme.inkSubtle)
                            Text(session.lastModified)
                                .foregroundStyle(theme.inkMuted)
                                .monospacedDigit()
                        }
                    }
                    .font(.system(size: 12))
                    .lineLimit(1)
                }

                Spacer()

                ToolButton(
                    title: STCopy.Action.copyId,
                    theme: theme,
                    style: .secondary,
                    action: onCopyId
                )
            }
            .padding(.bottom, 30)

            // Layer 1: 4 Borderless Hero KPI Numbers
            HStack(alignment: .top, spacing: 0) {
                STMetricColumn(
                    label: STCopy.Inspector.contextUsage,
                    value: "\(session.ctxPct)%",
                    valueColor: occTextColor,
                    sub: "\(STCopy.tokens(session.ctxUsedTokens)) / \(STCopy.tokens(session.ctxLimitTokens))",
                    theme: theme
                )
                STMetricColumn(
                    label: STCopy.Inspector.totalInput,
                    value: STCopy.tokens(session.totalInputTokens),
                    valueColor: theme.inkPrimary,
                    sub: "\(STCopy.Inspector.cache) \(STCopy.tokens(session.totalCacheReadTokens))",
                    theme: theme
                )
                STMetricColumn(
                    label: STCopy.Inspector.cacheHit,
                    value: "\(session.cacheHitPct)%",
                    valueColor: theme.inkPrimary,
                    sub: "\(STCopy.Inspector.output) \(STCopy.tokens(session.totalOutputTokens))",
                    theme: theme
                )
                STMetricColumn(
                    label: STCopy.Inspector.estimatedCost,
                    value: String(format: "$%.2f", session.costUsd),
                    valueColor: theme.inkPrimary,
                    sub: session.totalThinkingTokens > 0
                        ? "思考 \(STCopy.tokens(session.totalThinkingTokens))"
                        : STCopy.Inspector.referenceRate,
                    theme: theme
                )
            }
            .padding(.bottom, 26)

            // Layer 2: 6px Context Composition Bar + Quiet Tabular Legend
            VStack(alignment: .leading, spacing: 9) {
                ContextCompositionBar(
                    breakdown: session.breakdown,
                    totalK: max(session.ctxTotalK, 1),
                    accent: barColor,
                    theme: theme
                )

                HStack(spacing: 18) {
                    LegendDatum(color: barColor, label: "\(STCopy.Inspector.rules) \(session.breakdown.rulesK)k", theme: theme)
                    LegendDatum(color: barColor.opacity(0.62), label: "\(STCopy.Inspector.cache) \(session.breakdown.cacheK)k", theme: theme)
                    LegendDatum(color: barColor.opacity(0.36), label: "\(STCopy.Inspector.freshInput) \(session.breakdown.freshInputK)k", theme: theme)
                    LegendDatum(color: barColor.opacity(0.18), label: "\(STCopy.Inspector.output) \(session.breakdown.outputK)k", theme: theme)
                    Spacer()
                    Text("\(STCopy.Inspector.remaining) \(session.breakdown.freeK)k")
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(session.ctxPct > 80 ? theme.alertRed : theme.inkMuted)
                }
            }
            .padding(.bottom, 28)

            HairlineDivider(theme: theme, axis: .horizontal)
                .padding(.bottom, 22)

            // Layer 3: macOS Inspector Two-Column Canonical Key-Value List
            Text(STCopy.Inspector.telemetrySection)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(theme.inkMuted)
                .padding(.bottom, 12)

            HStack(alignment: .top, spacing: 48) {
                VStack(spacing: 0) {
                    STInspectorRow(key: STCopy.Inspector.currentModel, value: session.model, theme: theme)
                    STInspectorRow(key: STCopy.Inspector.stepsAndTurns, value: "\(session.stepCount) / \(session.llmTurns)", theme: theme)
                    STInspectorRow(key: STCopy.Inspector.userAndAssistant, value: "\(session.userTurns) / \(session.assistantTurns)", theme: theme)
                    STInspectorRow(key: STCopy.Inspector.toolsAndCheckpoints, value: "\(session.toolCallCount) / \(session.checkpointCount)", theme: theme)
                    STInspectorRow(key: STCopy.Inspector.subagents, value: "\(session.subagentCount)", theme: theme)
                    STInspectorRow(
                        key: STCopy.Inspector.tags,
                        value: session.tags.isEmpty ? STCopy.State.none : session.tags.joined(separator: ", "),
                        theme: theme
                    )
                    STInspectorRow(
                        key: STCopy.Inspector.sessionStatus,
                        value: session.isArchived ? "\(session.status) · \(STCopy.State.archivedFull)" : session.status,
                        isLast: true,
                        theme: theme
                    )
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 0) {
                    STInspectorRow(
                        key: STCopy.Inspector.topTools,
                        value: session.topTools.isEmpty
                            ? STCopy.State.none
                            : session.topTools.prefix(3).map { "\($0.name) ×\($0.count)" }.joined(separator: "  "),
                        theme: theme
                    )
                    STInspectorRow(
                        key: STCopy.Inspector.modelsUsed,
                        value: session.modelsUsed.isEmpty ? session.model : session.modelsUsed.prefix(2).joined(separator: ", "),
                        theme: theme
                    )
                    STInspectorRow(
                        key: STCopy.Inspector.artifacts,
                        value: session.artifactFiles.isEmpty ? STCopy.State.none : session.artifactFiles.prefix(3).joined(separator: ", "),
                        theme: theme
                    )
                    STInspectorRow(
                        key: STCopy.Inspector.ruleFiles,
                        value: session.workspaceRuleFiles.isEmpty ? STCopy.State.none : session.workspaceRuleFiles.joined(separator: ", "),
                        theme: theme
                    )
                    STInspectorRow(
                        key: STCopy.Inspector.thinkingTokens,
                        value: STCopy.tokens(session.totalThinkingTokens),
                        theme: theme
                    )
                    STInspectorRow(
                        key: STCopy.Inspector.dataSource,
                        value: STCopy.telemetryOrigin(session.telemetryOrigin),
                        monospace: true,
                        isLast: true,
                        theme: theme
                    )
                }
                .frame(maxWidth: .infinity)
            }

            if !session.lastUserPrompt.isEmpty {
                HairlineDivider(theme: theme, axis: .horizontal)
                    .padding(.vertical, 20)

                VStack(alignment: .leading, spacing: 6) {
                    Text(STCopy.Inspector.recentPrompt)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(theme.inkMuted)
                    Text(session.lastUserPrompt)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.inkSecondary)
                        .lineSpacing(3)
                        .lineLimit(3)
                }
            }
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 28)
        .frame(maxWidth: 1020, alignment: .leading)
    }
}

// MARK: - View B: Project Overview

private struct ProjectFolderOverviewView: View {
    let project: NativeProject
    let sessions: [SessionTelemetry]
    let theme: MonochromeTheme
    let onSelectSession: (String) -> Void

    var body: some View {
        let activeCount = sessions.filter { $0.isLiveActive }.count
        let maxCtxSession = sessions.max(by: { $0.ctxPct < $1.ctxPct })
        let totalSteps = sessions.reduce(UInt32(0)) { $0 + $1.stepCount }
        let totalTurns = sessions.reduce(UInt32(0)) { $0 + $1.llmTurns }
        let totalCost = sessions.reduce(0.0) { $0 + $1.costUsd }
        let totalTokens = sessions.reduce(UInt64(0)) { $0 + $1.totalInputTokens + $1.totalCacheReadTokens + $1.totalOutputTokens }

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(theme.inkMuted)
                    Text(project.name)
                        .font(.system(size: 20, weight: .semibold))
                        .tracking(-0.35)
                        .foregroundStyle(theme.inkPrimary)
                }

                HStack(spacing: 8) {
                    if let folder = project.folderPath, !folder.isEmpty {
                        Text(STCopy.abbreviateHome(folder))
                            .foregroundStyle(theme.inkMuted)
                        Text("·").foregroundStyle(theme.inkSubtle)
                    }
                    Text("\(sessions.count) 会话")
                        .foregroundStyle(theme.inkSecondary)
                        .monospacedDigit()
                    if !project.lastModified.isEmpty {
                        Text("·").foregroundStyle(theme.inkSubtle)
                        Text(project.lastModified)
                            .foregroundStyle(theme.inkMuted)
                            .monospacedDigit()
                    }
                }
                .font(.system(size: 12))
            }
            .padding(.bottom, 28)

            HStack(alignment: .top, spacing: 0) {
                STMetricColumn(
                    label: STCopy.Folder.totalSessions,
                    value: "\(sessions.count)",
                    valueColor: theme.inkPrimary,
                    sub: activeCount > 0 ? "\(activeCount) \(STCopy.State.active)" : STCopy.Folder.allIdle,
                    theme: theme
                )
                STMetricColumn(
                    label: STCopy.Folder.peakContext,
                    value: maxCtxSession.map { "\($0.ctxPct)%" } ?? "--",
                    valueColor: maxCtxSession.map { theme.occupancyTextColor(ctxPct: $0.ctxPct) } ?? theme.inkMuted,
                    sub: maxCtxSession.map { "\($0.ctxUsedK)k / \($0.ctxTotalK)k" } ?? STCopy.Folder.noData,
                    theme: theme
                )
                STMetricColumn(
                    label: STCopy.Folder.totalSteps,
                    value: NumberFormatter.localizedString(from: NSNumber(value: totalSteps), number: .decimal),
                    valueColor: theme.inkPrimary,
                    sub: "\(totalTurns) 轮次",
                    theme: theme
                )
                STMetricColumn(
                    label: STCopy.Folder.totalCost,
                    value: String(format: "$%.2f", totalCost),
                    valueColor: theme.inkPrimary,
                    sub: "吞吐 \(STCopy.tokens(totalTokens))",
                    theme: theme
                )
            }
            .padding(.bottom, 26)

            HairlineDivider(theme: theme, axis: .horizontal)
                .padding(.bottom, 18)

            HStack {
                Text(STCopy.Folder.tableTitle)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(theme.inkMuted)
                Spacer()
                Text(STCopy.Folder.colContext)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.inkSubtle)
                    .frame(width: 132, alignment: .trailing)
                Text(STCopy.Folder.colSteps)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.inkSubtle)
                    .frame(width: 60, alignment: .trailing)
                Text(STCopy.Folder.colCost)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.inkSubtle)
                    .frame(width: 64, alignment: .trailing)
                Text(STCopy.Folder.colUpdated)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.inkSubtle)
                    .frame(width: 108, alignment: .trailing)
                Spacer().frame(width: 18)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            if sessions.isEmpty {
                Text(STCopy.Folder.empty)
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.inkMuted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 28)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { idx, s in
                        if idx > 0 {
                            HairlineDivider(theme: theme, axis: .horizontal, subtle: true)
                        }
                        FolderSessionTableRow(session: s, theme: theme) {
                            onSelectSession(s.id)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 28)
        .frame(maxWidth: 1020, alignment: .leading)
    }
}

private struct FolderSessionTableRow: View {
    let session: SessionTelemetry
    let theme: MonochromeTheme
    let action: () -> Void

    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Circle()
                    .fill(theme.activeDotColor(isActive: session.isLiveActive))
                    .frame(width: 6, height: 6)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(session.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(theme.inkPrimary)
                            .lineLimit(1)
                        if session.isStarred {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8.5))
                                .foregroundStyle(theme.inkMuted)
                        }
                        if session.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 8.5))
                                .foregroundStyle(theme.inkSubtle)
                        }
                        if session.isArchived {
                            Text(STCopy.State.archivedFull)
                                .font(.system(size: 10))
                                .foregroundStyle(theme.inkSubtle)
                        }
                    }

                    HStack(spacing: 6) {
                        Text(session.model)
                            .foregroundStyle(theme.inkMuted)
                        Text("·").foregroundStyle(theme.inkSubtle)
                        Text("#\(session.shortId)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.inkSubtle)
                        if !session.lastUserPrompt.isEmpty {
                            Text("·").foregroundStyle(theme.inkSubtle)
                            Text(session.lastUserPrompt)
                                .foregroundStyle(theme.inkMuted)
                                .lineLimit(1)
                        }
                    }
                    .font(.system(size: 11))
                    .lineLimit(1)
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    ToolProgressBar(
                        progress: Double(session.ctxPct) / 100.0,
                        fillColor: theme.occupancyBarColor(ctxPct: session.ctxPct),
                        theme: theme,
                        height: 3
                    )
                    .frame(width: 54)

                    Text(session.ctxUsedK > 0 ? "\(session.ctxPct)% · \(session.ctxUsedK)k" : "--")
                        .font(.system(size: 11.5, weight: session.ctxPct > 80 ? .semibold : .regular).monospacedDigit())
                        .foregroundStyle(theme.occupancyTextColor(ctxPct: session.ctxPct, secondaryWhenNormal: true))
                        .frame(width: 70, alignment: .trailing)
                }
                .frame(width: 132, alignment: .trailing)

                Text("\(session.stepCount)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(theme.inkSecondary)
                    .frame(width: 60, alignment: .trailing)

                Text(String(format: "$%.2f", session.costUsd))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(theme.inkSecondary)
                    .frame(width: 64, alignment: .trailing)

                Text(session.lastModified.isEmpty ? "--" : session.lastModified)
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(theme.inkMuted)
                    .frame(width: 108, alignment: .trailing)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(hover.isHovered ? theme.inkPrimary : theme.inkSubtle)
                    .frame(width: 12)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(hover.isHovered ? theme.bgHover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.isHovered = $0 }
    }
}

private struct ContextCompositionBar: View {
    let breakdown: ContextBreakdown
    let totalK: UInt32
    let accent: Color
    let theme: MonochromeTheme

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let denom = Double(max(totalK, 1))
            let wRules = w * min(1.0, Double(breakdown.rulesK) / denom)
            let wCache = w * min(1.0, Double(breakdown.cacheK) / denom)
            let wFresh = w * min(1.0, Double(breakdown.freshInputK) / denom)
            let wOut = w * min(1.0, Double(breakdown.outputK) / denom)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(theme.trackBg)
                HStack(spacing: 1) {
                    if wRules > 0.5 { Rectangle().fill(accent).frame(width: wRules) }
                    if wCache > 0.5 { Rectangle().fill(accent.opacity(0.62)).frame(width: wCache) }
                    if wFresh > 0.5 { Rectangle().fill(accent.opacity(0.36)).frame(width: wFresh) }
                    if wOut > 0.5 { Rectangle().fill(accent.opacity(0.18)).frame(width: wOut) }
                    Spacer(minLength: 0)
                }
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            }
        }
        .frame(height: 6)
    }
}

private struct LegendDatum: View {
    let color: Color
    let label: String
    let theme: MonochromeTheme

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(theme.inkMuted)
        }
    }
}
