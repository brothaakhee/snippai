import SwiftUI
import AppKit
import SnippAIKit

/// Maps abstract `TermColor` values to concrete colors using a dark theme and
/// the standard xterm-256 palette. Tuned to read like a modern terminal so the
/// mirror "looks like Claude's TUI."
enum TerminalPalette {
    static let defaultForegroundRGB: (Double, Double, Double) = (0.86, 0.87, 0.89)
    static let defaultBackgroundRGB: (Double, Double, Double) = (0.07, 0.08, 0.10)

    static var defaultForeground: Color { color(defaultForegroundRGB) }
    static var defaultBackground: Color { color(defaultBackgroundRGB) }
    static var defaultBackgroundNS: NSColor { nsColor(defaultBackgroundRGB) }

    /// RGB components (0...1) for a terminal color.
    static func rgbComponents(_ term: TermColor) -> (Double, Double, Double) {
        switch term {
        case .defaultForeground: return defaultForegroundRGB
        case .defaultBackground: return defaultBackgroundRGB
        case .rgb(let r, let g, let b): return (Double(r) / 255, Double(g) / 255, Double(b) / 255)
        case .palette(let idx): return paletteRGB(idx)
        }
    }

    static func color(_ term: TermColor, isForeground: Bool = true) -> Color {
        color(rgbComponents(term))
    }

    static func nsColor(_ term: TermColor) -> NSColor {
        nsColor(rgbComponents(term))
    }

    private static func color(_ c: (Double, Double, Double)) -> Color {
        Color(red: c.0, green: c.1, blue: c.2)
    }
    private static func nsColor(_ c: (Double, Double, Double)) -> NSColor {
        NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
    }

    /// The standard 16-color ANSI set (first 16 indices), in a balanced dark scheme.
    private static let ansi16: [(Double, Double, Double)] = [
        (0.18, 0.20, 0.23),   // 0 black (slightly lifted)
        (0.94, 0.38, 0.42),   // 1 red
        (0.40, 0.82, 0.48),   // 2 green
        (0.92, 0.79, 0.40),   // 3 yellow
        (0.40, 0.62, 0.96),   // 4 blue
        (0.78, 0.52, 0.96),   // 5 magenta
        (0.36, 0.82, 0.86),   // 6 cyan
        (0.86, 0.87, 0.89),   // 7 white
        (0.42, 0.45, 0.50),   // 8 bright black
        (0.98, 0.50, 0.54),   // 9 bright red
        (0.55, 0.90, 0.60),   // 10 bright green
        (0.98, 0.87, 0.52),   // 11 bright yellow
        (0.54, 0.72, 0.99),   // 12 bright blue
        (0.86, 0.64, 0.99),   // 13 bright magenta
        (0.52, 0.90, 0.93),   // 14 bright cyan
        (0.98, 0.99, 1.00),   // 15 bright white
    ]

    private static func paletteRGB(_ idx: Int) -> (Double, Double, Double) {
        if idx < 16 { return ansi16[max(0, min(15, idx))] }
        if idx < 232 {
            let i = idx - 16
            let r = (i / 36) % 6, g = (i / 6) % 6, b = i % 6
            func comp(_ v: Int) -> Double { v == 0 ? 0 : (Double(v) * 40 + 55) / 255 }
            return (comp(r), comp(g), comp(b))
        }
        let level = (Double(idx - 232) * 10 + 8) / 255
        return (level, level, level)
    }
}
