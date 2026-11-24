import SwiftUI

/// Main Content Area (#161618) — 100% dedicated to the currently selected item:
/// - Session selected -> Linear/Raycast style Session Inspector (4 borderless KPIs + 6px context bar + 2-column KV Inspector)
/// - Project folder selected -> Project Folder Overview listing all sessions inside that folder
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
                    Text("选择左侧项目或会话")
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

// MARK: - View A: Session Inspector (100% Focused on Selected Session)

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
                    title: "复制 ID",
                    theme: theme,
                    style: .secondary,
                    action: onCopyId
                )
            }
            .padding(.bottom, 30)

            // Layer 1: 4 Borderless Hero KPI Numbers separated purely by whitespace (ZERO lines, ZERO boxes)
            HStack(alignment: .top, spacing: 0) {
                HeroMetricColumn(
                    label: "上下文占用",
                    value: "\(session.ctxPct)%",
                    valueColor: occTextColor,
                    sub: "\(formatCompactTokens(session.ctxUsedTokens)) / \(formatCompactTokens(session.ctxLimitTokens))",
                    theme: theme
                )
                HeroMetricColumn(
                    label: "累计输入",
                    value: formatCompactTokens(session.totalInputTokens),
                    valueColor: theme.inkPrimary,
                    sub: "缓存读取 \(formatCompactTokens(session.totalCacheReadTokens))",
                    theme: theme
                )
                HeroMetricColumn(
                    label: "缓存命中",
                    value: "\(session.cacheHitPct)%",
                    valueColor: theme.inkPrimary,
                    sub: "输出 \(formatCompactTokens(session.totalOutputTokens))",
                    theme: theme
                )
                HeroMetricColumn(
                    label: "估算费用",
                    value: String(format: "$%.2f", session.costUsd),
                    valueColor: theme.inkPrimary,
                    sub: session.totalThinkingTokens > 0
                        ? "思考 \(formatCompactTokens(session.totalThinkingTokens))"
                        : "按公开费率",
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
                    LegendDatum(color: barColor, label: "规则 \(session.breakdown.rulesK)k", theme: theme)
                    LegendDatum(color: barColor.opacity(0.62), label: "缓存 \(session.breakdown.cacheK)k", theme: theme)
                    LegendDatum(color: barColor.opacity(0.36), label: "新增 \(session.breakdown.freshInputK)k", theme: theme)
                    LegendDatum(color: barColor.opacity(0.18), label: "输出 \(session.breakdown.outputK)k", theme: theme)
                    Spacer()
                    Text("剩余 \(session.breakdown.freeK)k")
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(session.ctxPct > 80 ? theme.alertRed : theme.inkMuted)
                }
            }
            .padding(.bottom, 28)

            HairlineDivider(theme: theme, axis: .horizontal)
                .padding(.bottom, 22)

            // Layer 3: macOS "显示简介 / Inspector" Two-Column Key-Value Detail List
            Text("遥测明细")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(theme.inkMuted)
                .padding(.bottom, 12)

            HStack(alignment: .top, spacing: 48) {
                VStack(spacing: 0) {
                    InspectorKVRow(key: "当前模型", value: session.model, theme: theme)
                    InspectorKVRow(key: "步数 / LLM 轮次", value: "\(session.stepCount) / \(session.llmTurns)", theme: theme)
                    InspectorKVRow(key: "提问 / 回复", value: "\(session.userTurns) / \(session.assistantTurns)", theme: theme)
                    InspectorKVRow(key: "工具调用 / 压缩", value: "\(session.toolCallCount) / \(session.checkpointCount)", theme: theme)
                    InspectorKVRow(key: "子 Agent", value: "\(session.subagentCount)", theme: theme)
                    InspectorKVRow(
                        key: "标签",
                        value: session.tags.isEmpty ? "无" : session.tags.joined(separator: ", "),
                        theme: theme
                    )
                    InspectorKVRow(
                        key: "会话状态",
                        value: session.isArchived ? "\(session.status) · 已归档" : session.status,
                        isLast: true,
                        theme: theme
                    )
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 0) {
                    InspectorKVRow(
                        key: "高频工具",
                        value: session.topTools.isEmpty
                            ? "无"
                            : session.topTools.prefix(3).map { "\($0.name) ×\($0.count)" }.joined(separator: "  "),
                        theme: theme
                    )
                    InspectorKVRow(
                        key: "已用模型",
                        value: session.modelsUsed.isEmpty ? session.model : session.modelsUsed.prefix(2).joined(separator: ", "),
                        theme: theme
                    )
                    InspectorKVRow(
                        key: "产出文件",
                        value: session.artifactFiles.isEmpty ? "无" : session.artifactFiles.prefix(3).joined(separator: ", "),
                        theme: theme
                    )
                    InspectorKVRow(
                        key: "规则文件",
                        value: session.workspaceRuleFiles.isEmpty ? "无" : session.workspaceRuleFiles.joined(separator: ", "),
                        theme: theme
                    )
                    InspectorKVRow(
                        key: "思考 Token",
                        value: formatCompactTokens(session.totalThinkingTokens),
                        theme: theme
                    )
                    InspectorKVRow(
                        key: "数据源",
                        value: telemetryOriginShort(session.telemetryOrigin),
                        isLast: true,
                        theme: theme
                    )
                }
                .frame(maxWidth: .infinity)
            }

            // Recent Prompt Strip
            if !session.lastUserPrompt.isEmpty {
                HairlineDivider(theme: theme, axis: .horizontal)
                    .padding(.vertical, 20)

                VStack(alignment: .leading, spacing: 6) {
                    Text("最近输入")
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

    private func telemetryOriginShort(_ origin: String) -> String {
        switch origin {
        case "db+gen_metadata": return "gen_metadata"
        case "db-steps": return "steps"
        default: return "summary"
        }
    }
}

// MARK: - View B: Project Folder Overview (Shows All Sessions in Selected Folder)

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
            // Folder header
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
                        Text(abbreviateHome(folder))
                            .foregroundStyle(theme.inkMuted)
                        Text("·").foregroundStyle(theme.inkSubtle)
                    }
                    Text("\(sessions.count) 个会话")
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

            // 4 Borderless Aggregate KPI Numbers
            HStack(alignment: .top, spacing: 0) {
                HeroMetricColumn(
                    label: "会话总数",
                    value: "\(sessions.count)",
                    valueColor: theme.inkPrimary,
                    sub: activeCount > 0 ? "\(activeCount) 活跃" : "全部空闲",
                    theme: theme
                )
                HeroMetricColumn(
                    label: "最高上下文",
                    value: maxCtxSession.map { "\($0.ctxPct)%" } ?? "--",
                    valueColor: maxCtxSession.map { theme.occupancyTextColor(ctxPct: $0.ctxPct) } ?? theme.inkMuted,
                    sub: maxCtxSession.map { "\($0.ctxUsedK)k / \($0.ctxTotalK)k" } ?? "无数据",
                    theme: theme
                )
                HeroMetricColumn(
                    label: "累计步数",
                    value: NumberFormatter.localizedString(from: NSNumber(value: totalSteps), number: .decimal),
                    valueColor: theme.inkPrimary,
                    sub: "\(totalTurns) LLM 轮次",
                    theme: theme
                )
                HeroMetricColumn(
                    label: "合计估算",
                    value: String(format: "$%.2f", totalCost),
                    valueColor: theme.inkPrimary,
                    sub: "总吞吐 \(formatCompactTokens(totalTokens))",
                    theme: theme
                )
            }
            .padding(.bottom, 26)

            HairlineDivider(theme: theme, axis: .horizontal)
                .padding(.bottom, 18)

            // Sessions table inside this folder
            HStack {
                Text("文件夹下会话")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(theme.inkMuted)
                Spacer()
                Text("上下文")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.inkSubtle)
                    .frame(width: 132, alignment: .trailing)
                Text("步数")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.inkSubtle)
                    .frame(width: 60, alignment: .trailing)
                Text("估算")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.inkSubtle)
                    .frame(width: 64, alignment: .trailing)
                Text("更新时间")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.inkSubtle)
                    .frame(width: 108, alignment: .trailing)
                Spacer().frame(width: 18)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            if sessions.isEmpty {
                Text("该项目文件夹下暂无会话")
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

    private func abbreviateHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
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
                            Text("已归档")
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

                // Context bar + tabular %
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

// MARK: - Subcomponents

private struct HeroMetricColumn: View {
    let label: String
    let value: String
    let valueColor: Color
    let sub: String
    let theme: MonochromeTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(theme.inkMuted)
            Text(value)
                .font(.system(size: 28, weight: .semibold).monospacedDigit())
                .tracking(-0.6)
                .foregroundStyle(valueColor)
                .lineLimit(1)
            Text(sub)
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(theme.inkMuted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InspectorKVRow: View {
    let key: String
    let value: String
    var isLast: Bool = false
    let theme: MonochromeTheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(key)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.inkMuted)
                Spacer(minLength: 12)
                Text(value)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(theme.inkPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.vertical, 9.5)

            if !isLast {
                HairlineDivider(theme: theme, axis: .horizontal, subtle: true)
            }
        }
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
                    if wRules > 0.5 {
                        Rectangle().fill(accent).frame(width: wRules)
                    }
                    if wCache > 0.5 {
                        Rectangle().fill(accent.opacity(0.62)).frame(width: wCache)
                    }
                    if wFresh > 0.5 {
                        Rectangle().fill(accent.opacity(0.36)).frame(width: wFresh)
                    }
                    if wOut > 0.5 {
                        Rectangle().fill(accent.opacity(0.18)).frame(width: wOut)
                    }
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

func formatCompactTokens(_ count: UInt64) -> String {
    if count >= 1_000_000 {
        return String(format: "%.2fM", Double(count) / 1_000_000.0)
    } else if count >= 1_000 {
        return String(format: "%.1fk", Double(count) / 1_000.0)
    }
    return "\(count)"
}
