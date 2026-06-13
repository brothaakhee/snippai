import SwiftUI

/// Shared visual constants so every section of the panel hangs off one rhythm.
enum PanelStyle {
    /// The single horizontal content inset every section aligns to.
    static let contentInset: CGFloat = 16
    /// Radius ramp: inner controls / cards / panel.
    static let controlRadius: CGFloat = 8
    static let cardRadius: CGFloat = 10
    static let panelRadius: CGFloat = 14

    /// Dynamic Type band the compact panel/onboarding support. We honor the full
    /// standard text-size slider but cap the giant accessibility sizes, which would
    /// need a fundamentally different layout than a fixed-width utility panel.
    static let typeRange: ClosedRange<DynamicTypeSize> = .xSmall ... .accessibility1

    /// Debug-only forced Dynamic Type size (SNIPPAI_TYPE_SIZE) for screenshots.
    static var debugTypeSize: DynamicTypeSize? {
        switch ProcessInfo.processInfo.environment["SNIPPAI_TYPE_SIZE"] {
        case "xSmall": return .xSmall
        case "small": return .small
        case "large": return .large
        case "xLarge": return .xLarge
        case "xxLarge": return .xxLarge
        case "xxxLarge": return .xxxLarge
        case "accessibility1", "a1": return .accessibility1
        case "accessibility3", "a3": return .accessibility3
        default: return nil
        }
    }
}

extension View {
    /// Clamps Dynamic Type to the band the compact UI supports (and applies the
    /// debug override when set).
    func snippaiDynamicTypeClamp() -> some View {
        dynamicTypeSize(PanelStyle.typeRange)
            .modifier(DebugDynamicTypeModifier())
    }
}

private struct DebugDynamicTypeModifier: ViewModifier {
    func body(content: Content) -> some View {
        if let size = PanelStyle.debugTypeSize {
            content.dynamicTypeSize(size)
        } else {
            content
        }
    }
}

extension View {
    /// Applies a system font at exactly `size` at the default text setting, scaling
    /// it relative to `.body` with Dynamic Type. Unlike mapping to a text style, this
    /// preserves the tuned sizes pixel-for-pixel at default while still honoring the
    /// user's text-size / accessibility-text setting.
    func scaledFont(_ size: CGFloat, weight: Font.Weight = .regular,
                    design: Font.Design = .default) -> some View {
        modifier(ScaledFontModifier(size: size, weight: weight, design: design))
    }
}

private struct ScaledFontModifier: ViewModifier {
    @ScaledMetric private var size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    init(size: CGFloat, weight: Font.Weight, design: Font.Design) {
        self._size = ScaledMetric(wrappedValue: size, relativeTo: .body)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }
}
