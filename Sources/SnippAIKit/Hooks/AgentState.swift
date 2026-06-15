import Foundation

/// The semantic lifecycle state of an agent session, derived from push hook events
/// (`Stop` → finished, `Notification` → waiting). This is pure ENRICHMENT layered
/// over the live mirror — it answers "does this session need me?", not what's on
/// screen. `.unknown` means no hook signal yet (hooks off, or not yet fired).
public enum AgentState: String, Sendable, Equatable, CaseIterable {
    case working
    case finished
    case waitingForInput
    case unknown

    /// Short human label for the badge.
    public var label: String {
        switch self {
        case .working: return "Working"
        case .finished: return "Done"
        case .waitingForInput: return "Needs you"
        case .unknown: return ""
        }
    }

    /// SF Symbol name for the badge dot/glyph.
    public var symbolName: String {
        switch self {
        case .working: return "circle.dotted"
        case .finished: return "checkmark.circle.fill"
        case .waitingForInput: return "exclamationmark.circle.fill"
        case .unknown: return "circle"
        }
    }

    /// Whether this state should pull the user's attention (drives the menu-bar dot).
    public var needsAttention: Bool {
        self == .finished || self == .waitingForInput
    }

    /// Maps a hook event name to a state. Unrecognized events leave state unchanged
    /// (returns nil) so schema drift degrades gracefully.
    public static func from(event: String) -> AgentState? {
        switch event {
        case "Stop": return .finished
        case "Notification": return .waitingForInput
        default: return nil
        }
    }
}

/// A timestamped state entry for one session.
public struct AgentStateEntry: Sendable, Equatable {
    public var state: AgentState
    public var lastEventAt: Date
    public var message: String?

    public init(state: AgentState, lastEventAt: Date, message: String? = nil) {
        self.state = state
        self.lastEventAt = lastEventAt
        self.message = message
    }
}
