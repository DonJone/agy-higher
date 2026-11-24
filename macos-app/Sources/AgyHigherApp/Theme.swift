import AppKit
import SwiftUI

enum AppThemeMode: String, CaseIterable {
    case dark
    case light
}

/// Linear / Raycast / Cursor desktop-grade carbon gray theme.
/// Dark recipe:
/// - Sidebar & Header: #101012
/// - Main Canvas: #161618
/// - Hairline dividers: rgba(255,255,255,0.06)
/// - Primary Ink: #EDEDEF (never harsh #FFFFFF)
/// - Secondary Ink: #7E828C
/// - Control / Selected: rgba(255,255,255,0.07) + 1px solid rgba(255,255,255,0.08)
/// - Healthy progress bars: rgba(255,255,255,0.75) (zero neon green!)
/// - Restrained alerts ONLY on warning/critical: muted crimson #D45252 / amber #D4943A.
struct MonochromeTheme {
    let mode: AppThemeMode

    // Carbon gray surface elevation
    var bgSidebar: Color { mode == .light ? Color(hex: 0xF5F5F7) : Color(hex: 0x101012) }
    var bgHeader: Color { mode == .light ? Color(hex: 0xF5F5F7) : Color(hex: 0x101012) }
    var bgCanvas: Color { mode == .light ? Color(hex: 0xFFFFFF) : Color(hex: 0x161618) }
    var bgElevated: Color { mode == .light ? Color(hex: 0xFFFFFF) : Color(hex: 0x1C1C1F) }
    var bgSurface: Color { mode == .light ? Color(hex: 0xF5F5F7) : Color(hex: 0x1B1B1E) }
    var bgInput: Color { mode == .light ? Color(hex: 0xFFFFFF) : Color(hex: 0x141417) }

    // Interactive fills (exact translucent layering)
    var bgSelected: Color { mode == .light ? Color(hex: 0x000000, alpha: 0.055) : Color(hex: 0xFFFFFF, alpha: 0.07) }
    var bgControl: Color { mode == .light ? Color(hex: 0x000000, alpha: 0.045) : Color(hex: 0xFFFFFF, alpha: 0.07) }
    var bgHover: Color { mode == .light ? Color(hex: 0x000000, alpha: 0.035) : Color(hex: 0xFFFFFF, alpha: 0.04) }

    // Soft ink hierarchy
    var inkPrimary: Color { mode == .light ? Color(hex: 0x18181B) : Color(hex: 0xEDEDEF) }
    var inkSecondary: Color { mode == .light ? Color(hex: 0x52525B) : Color(hex: 0xA8ACB6) }
    var inkMuted: Color { mode == .light ? Color(hex: 0x71717A) : Color(hex: 0x7E828C) }
    var inkSubtle: Color { mode == .light ? Color(hex: 0xA1A1AA) : Color(hex: 0x555863) }

    // Primary button contrast
    var ctaBg: Color { mode == .light ? Color(hex: 0x18181B) : Color(hex: 0xEDEDEF) }
    var ctaFg: Color { mode == .light ? Color(hex: 0xFFFFFF) : Color(hex: 0x101012) }

    // Whisper-thin translucent boundaries
    var border: Color { mode == .light ? Color(hex: 0x000000, alpha: 0.065) : Color(hex: 0xFFFFFF, alpha: 0.06) }
    var borderControl: Color { mode == .light ? Color(hex: 0x000000, alpha: 0.09) : Color(hex: 0xFFFFFF, alpha: 0.08) }
    var borderSubtle: Color { mode == .light ? Color(hex: 0x000000, alpha: 0.045) : Color(hex: 0xFFFFFF, alpha: 0.045) }
    var borderHover: Color { mode == .light ? Color(hex: 0x000000, alpha: 0.16) : Color(hex: 0xFFFFFF, alpha: 0.14) }

    // Quiet progress tracks & default neutral fills (NO fluorescent green!)
    var trackBg: Color { mode == .light ? Color(hex: 0x000000, alpha: 0.07) : Color(hex: 0xFFFFFF, alpha: 0.08) }
    var barNeutral: Color { mode == .light ? Color(hex: 0x18181B, alpha: 0.72) : Color(hex: 0xFFFFFF, alpha: 0.75) }

    // Restrained alert-only semantic tones (dark crimson & warm amber; silent when healthy)
    var alertRed: Color { mode == .light ? Color(hex: 0xC43838) : Color(hex: 0xD45252) }
    var alertAmber: Color { mode == .light ? Color(hex: 0xB87318) : Color(hex: 0xD4943A) }

    // Quiet neutral indicators
    var dotActive: Color { mode == .light ? Color(hex: 0x18181B) : Color(hex: 0xEDEDEF) }
    var dotIdle: Color { mode == .light ? Color(hex: 0xD4D4D8) : Color(hex: 0x3D4049) }

    var preferredColorScheme: ColorScheme {
        mode == .dark ? .dark : .light
    }

    /// Remaining quota bar fill:
    /// Quiet translucent white when healthy (>= 30%); amber 15..29%; muted crimson < 15%.
    func quotaBarColor(remainingPct: UInt32) -> Color {
        if remainingPct < 15 {
            return alertRed
        } else if remainingPct < 30 {
            return alertAmber
        }
        return barNeutral
    }

    /// Remaining quota numeric text color:
    /// Quiet #EDEDEF when healthy; amber 15..29%; muted crimson < 15%.
    func quotaTextColor(remainingPct: UInt32) -> Color {
        if remainingPct < 15 {
            return alertRed
        } else if remainingPct < 30 {
            return alertAmber
        }
        return inkPrimary
    }

    /// Context occupancy bar fill:
    /// Quiet translucent white when normal (< 70%); amber 70..80%; muted crimson > 80%.
    func occupancyBarColor(ctxPct: UInt32) -> Color {
        if ctxPct > 80 {
            return alertRed
        } else if ctxPct >= 70 {
            return alertAmber
        }
        return barNeutral
    }

    /// Context occupancy numeric text color:
    /// Quiet neutral when normal (< 70%); amber 70..80%; muted crimson > 80%.
    func occupancyTextColor(ctxPct: UInt32, secondaryWhenNormal: Bool = false) -> Color {
        if ctxPct > 80 {
            return alertRed
        } else if ctxPct >= 70 {
            return alertAmber
        }
        return secondaryWhenNormal ? inkMuted : inkPrimary
    }

    func activeDotColor(isActive: Bool) -> Color {
        isActive ? dotActive : dotIdle
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

// MARK: - Shared Desktop Tool Primitives (Strict 4px-6px Radii, Whisper Hairlines)

@MainActor
final class HoverState: ObservableObject {
    @Published var isHovered: Bool = false
}

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
                .help("清空")
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
        // Normalize glyph bounds (0.222..0.778 x 0.188..0.812) tightly into rect
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
