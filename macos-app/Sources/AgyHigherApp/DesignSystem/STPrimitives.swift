import AppKit
import SwiftUI

// MARK: - STE-STC Atomic Layout & Control Primitives (4px-6px Radii, Whisper Hairlines)

struct HairlineDivider: View {
    let theme: MonochromeTheme
    var axis: Axis = .horizontal
    var subtle: Bool = false

    var body: some View {
        Rectangle()
            .fill(subtle ? theme.borderSubtle : theme.border)
            .frame(
                width: axis == .vertical ? 1 : nil,
                height: axis == .horizontal ? 1 : nil
            )
    }
}

struct STSectionHeader<Trailing: View>: View {
    let title: String
    var meta: String? = nil
    var metaColor: Color? = nil
    let theme: MonochromeTheme
    @ViewBuilder let trailing: Trailing

    init(
        title: String,
        meta: String? = nil,
        metaColor: Color? = nil,
        theme: MonochromeTheme,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.meta = meta
        self.metaColor = metaColor
        self.theme = theme
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(theme.inkPrimary)

            if let meta, !meta.isEmpty {
                Text(meta)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(metaColor ?? theme.inkMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)
            trailing
        }
        .padding(.bottom, 16)
    }
}

struct STSettingRow<Control: View>: View {
    let title: String
    var spec: String = ""
    let theme: MonochromeTheme
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.inkPrimary)
                if !spec.isEmpty {
                    Text(spec)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(theme.inkMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.vertical, 13)
    }
}

struct STInspectorRow: View {
    let key: String
    let value: String
    var valueColor: Color? = nil
    var monospace: Bool = false
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
                    .font(
                        monospace
                            ? .system(size: 11.5, weight: .medium, design: .monospaced)
                            : .system(size: 12, weight: .medium).monospacedDigit()
                    )
                    .foregroundStyle(valueColor ?? theme.inkPrimary)
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

struct STMetricColumn: View {
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

struct STSegmentControl<Value: Hashable>: View {
    let options: [(title: String, value: Value)]
    let selection: Value
    let theme: MonochromeTheme
    let onSelect: (Value) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                let isActive = opt.value == selection
                Button {
                    onSelect(opt.value)
                } label: {
                    Text(opt.title)
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
}

struct ToolProgressBar: View {
    let progress: Double
    let fillColor: Color
    let theme: MonochromeTheme
    var height: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            let clamped = max(0, min(1, progress))
            let radius = min(height / 2.0, 3.0)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(theme.trackBg)
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fillColor)
                    .frame(width: max(clamped > 0 ? 2 : 0, geo.size.width * clamped))
                    .animation(.easeInOut(duration: 0.2), value: clamped)
            }
        }
        .frame(height: height)
    }
}

struct ToolButton: View {
    enum Style {
        case primary
        case secondary
        case ghost
        case danger
    }

    let title: String
    let theme: MonochromeTheme
    var style: Style = .secondary
    var isDisabled: Bool = false
    var action: () -> Void

    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(foreground)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: 1)
                )
                .opacity(isDisabled ? 0.45 : (style == .primary && hover.isHovered ? 0.9 : 1.0))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hover.isHovered = $0 }
    }

    private var foreground: Color {
        switch style {
        case .primary: return theme.ctaFg
        case .secondary: return hover.isHovered ? theme.inkPrimary : theme.inkSecondary
        case .ghost: return hover.isHovered ? theme.inkPrimary : theme.inkMuted
        case .danger: return hover.isHovered ? theme.alertRed : theme.inkMuted
        }
    }

    private var background: Color {
        switch style {
        case .primary: return theme.ctaBg
        case .secondary: return hover.isHovered ? theme.bgSelected : theme.bgControl
        case .ghost: return hover.isHovered ? theme.bgHover : Color.clear
        case .danger: return hover.isHovered ? theme.alertRed.opacity(0.10) : Color.clear
        }
    }

    private var borderColor: Color {
        switch style {
        case .primary: return Color.clear
        case .secondary: return hover.isHovered ? theme.borderHover : theme.borderControl
        case .ghost: return Color.clear
        case .danger: return hover.isHovered ? theme.alertRed.opacity(0.32) : theme.borderControl
        }
    }
}

/// Restrained neutral toggle switch (zero fluorescent green).
struct ToolSwitch: View {
    let isOn: Bool
    let theme: MonochromeTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isOn ? theme.ctaBg : theme.trackBg)
                    .frame(width: 34, height: 18)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(isOn ? theme.ctaFg : theme.inkMuted)
                    .frame(width: 14, height: 14)
                    .padding(2)
            }
            .animation(.easeInOut(duration: 0.14), value: isOn)
        }
        .buttonStyle(.plain)
    }
}

struct ToolSearchField: View {
    let placeholder: String
    @Binding var text: String
    let theme: MonochromeTheme

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.inkMuted)

            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.inkSubtle)
                        .allowsHitTesting(false)
                }
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.inkPrimary)
                    .tint(theme.inkPrimary)
                    .focused($isFocused)
            }

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(theme.inkMuted)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help(STCopy.Action.clearSearch)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5.5)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(theme.bgInput)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(isFocused ? theme.borderHover : theme.borderControl, lineWidth: 1)
        )
    }
}

/// Aerodynamic floating "C" mark inspired by Google Antigravity's calligraphic arch.
struct AntigravityMark: Shape {
    func path(in rect: CGRect) -> Path {
        let minX: CGFloat = 0.205
        let maxX: CGFloat = 0.790
        let minY: CGFloat = 0.195
        let maxY: CGFloat = 0.805
        let w = maxX - minX
        let h = maxY - minY
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: rect.minX + ((x - minX) / w) * rect.width,
                y: rect.minY + ((y - minY) / h) * rect.height
            )
        }

        var path = Path()
        path.move(to: pt(0.752, 0.244))
        path.addCurve(to: pt(0.738, 0.296), control1: pt(0.778, 0.258), control2: pt(0.770, 0.292))
        path.addCurve(to: pt(0.506, 0.382), control1: pt(0.652, 0.304), control2: pt(0.562, 0.332))
        path.addCurve(to: pt(0.448, 0.500), control1: pt(0.460, 0.422), control2: pt(0.448, 0.458))
        path.addCurve(to: pt(0.506, 0.618), control1: pt(0.448, 0.542), control2: pt(0.460, 0.578))
        path.addCurve(to: pt(0.738, 0.704), control1: pt(0.562, 0.668), control2: pt(0.652, 0.696))
        path.addCurve(to: pt(0.752, 0.756), control1: pt(0.770, 0.708), control2: pt(0.778, 0.742))
        path.addCurve(to: pt(0.415, 0.770), control1: pt(0.680, 0.794), control2: pt(0.545, 0.812))
        path.addCurve(to: pt(0.222, 0.500), control1: pt(0.285, 0.728), control2: pt(0.222, 0.625))
        path.addCurve(to: pt(0.415, 0.230), control1: pt(0.222, 0.375), control2: pt(0.285, 0.272))
        path.addCurve(to: pt(0.752, 0.244), control1: pt(0.545, 0.188), control2: pt(0.680, 0.206))
        path.closeSubpath()
        return path
    }
}

enum BrandIconFactory {
    /// Crisp Retina template NSImage of the aerodynamic "C" emblem for the macOS menu bar.
    static let menuBarTemplateImage: NSImage = {
        let size = NSSize(width: 14, height: 14)
        let img = NSImage(size: size, flipped: true) { rect in
            let inset = rect.insetBy(dx: 0.8, dy: 0.6)
            let cgPath = AntigravityMark().path(in: inset).cgPath
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.addPath(cgPath)
                ctx.setFillColor(NSColor.labelColor.cgColor)
                ctx.fillPath()
            }
            return true
        }
        img.isTemplate = true
        return img
    }()
}
