import SwiftUI
import SnippAIKit

/// Maps abstract `TermColor` values to concrete colors using a dark theme and
/// the standard xterm-256 palette. Tuned to read like a modern terminal so the
/// mirror "looks like Claude's TUI."
enum TerminalPalette {
    static let defaultForeground = Color(red: 0.86, green: 0.87, blue: 0.89)
    static let defaultBackground = Color(red: 0.07, green: 0.08, blue: 0.10)

    static func color(_ term: TermColor, isForeground: Bool) -> Color {
        switch term {
        case .defaultForeground: return defaultForeground
        case .defaultBackground: return defaultBackground
        case .rgb(let r, let g, let b):
            return Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
        case .palette(let idx): return paletteColor(idx)
        }
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

    private static func paletteColor(_ idx: Int) -> Color {
        if idx < 16 {
            let c = ansi16[max(0, min(15, idx))]
            return Color(red: c.0, green: c.1, blue: c.2)
        }
        if idx < 232 {
            // 6×6×6 color cube.
            let i = idx - 16
            let r = (i / 36) % 6, g = (i / 6) % 6, b = i % 6
            func comp(_ v: Int) -> Double { v == 0 ? 0 : (Double(v) * 40 + 55) / 255 }
            return Color(red: comp(r), green: comp(g), blue: comp(b))
        }
        // 24-step grayscale ramp.
        let level = (Double(idx - 232) * 10 + 8) / 255
        return Color(red: level, green: level, blue: level)
    }
}
