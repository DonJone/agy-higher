import SwiftUI

enum AppThemeMode: String, CaseIterable {
    case dark
    case light
}

/// Linear / Raycast / Cursor carbon-gray design tokens.
/// Pure theme layer (UI primitives live in DesignSystem/STPrimitives.swift).
struct MonochromeTheme {
    let mode: AppThemeMode

    // Carbon gray surface elevation
    var bgSidebar: Color { mode == .light ? Color(hex: 0xF5F5F7) : Color(hex: 0x101012) }
    var bgHeader: Color { mode == .light ? Color(hex: 0xF5F5F7) : Color(hex: 0x101012) }
    var bgCanvas: Color { mode == .light ? Color(hex: 0xFFFFFF) : Color(hex: 0x161618) }
    var bgElevated: Color { mode == .light ? Color(hex: 0xFFFFFF) : Color(hex: 0x1C1C1F) }
    var bgSurface: Color { mode == .light ? Color(hex: 0xF5F5F7) : Color(hex: 0x1B1B1E) }
    var bgInput: Color { mode == .light ? Color(hex: 0xFFFFFF) : Color(hex: 0x141417) }

    // Interactive fills (translucent layering)
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

    // Quiet progress tracks & default neutral fills (zero fluorescent green)
    var trackBg: Color { mode == .light ? Color(hex: 0x000000, alpha: 0.07) : Color(hex: 0xFFFFFF, alpha: 0.08) }
    var barNeutral: Color { mode == .light ? Color(hex: 0x18181B, alpha: 0.72) : Color(hex: 0xFFFFFF, alpha: 0.75) }

    // Restrained alert-only semantic tones (muted crimson & warm amber; silent when healthy)
    var alertRed: Color { mode == .light ? Color(hex: 0xC43838) : Color(hex: 0xD45252) }
    var alertAmber: Color { mode == .light ? Color(hex: 0xB87318) : Color(hex: 0xD4943A) }

    // Quiet neutral indicators
    var dotActive: Color { mode == .light ? Color(hex: 0x18181B) : Color(hex: 0xEDEDEF) }
    var dotIdle: Color { mode == .light ? Color(hex: 0xD4D4D8) : Color(hex: 0x3D4049) }

    var preferredColorScheme: ColorScheme {
        mode == .dark ? .dark : .light
    }

    func quotaBarColor(remainingPct: UInt32) -> Color {
        if remainingPct < 15 { return alertRed }
        if remainingPct < 30 { return alertAmber }
        return barNeutral
    }

    func quotaTextColor(remainingPct: UInt32) -> Color {
        if remainingPct < 15 { return alertRed }
        if remainingPct < 30 { return alertAmber }
        return inkPrimary
    }

    func occupancyBarColor(ctxPct: UInt32) -> Color {
        if ctxPct > 80 { return alertRed }
        if ctxPct >= 70 { return alertAmber }
        return barNeutral
    }

    func occupancyTextColor(ctxPct: UInt32, secondaryWhenNormal: Bool = false) -> Color {
        if ctxPct > 80 { return alertRed }
        if ctxPct >= 70 { return alertAmber }
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

@MainActor
final class HoverState: ObservableObject {
    @Published var isHovered: Bool = false
}
