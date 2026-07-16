import SwiftUI
import SnippAIKit

// Voice input controls shared by the compose bar and the Ask question bar.

/// A live input waveform: a fixed window of bars scrolls left ~11×/s while
/// recording, heights driven by the mic level — so silence still visibly moves
/// (flat bars scrolling) and speech visibly dances. Standalone view: its timer
/// tick re-renders only this view, not the compose body.
struct VoiceWaveform: View {
    let voice: VoiceController
    @State private var bars: [Float] = Array(repeating: 0, count: 26)
    @State private var phase = 0.0
    /// One constant for both the timer and the animation duration — they must match
    /// or the scroll stutters. (The subscription tears down with the view, so the
    /// timer stops when recording ends and the waveform is removed.)
    private static let tickInterval = 0.09
    private let tick = Timer.publish(every: tickInterval, on: .main, in: .common).autoconnect()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 3) {
            ForEach(bars.indices, id: \.self) { i in
                Capsule()
                    .fill(PanelStyle.accent.opacity(0.45 + 0.55 * Double(bars[i])))
                    .frame(width: 2.5, height: barHeight(i))
            }
            Text("listening")
                .scaledFont(11).foregroundStyle(PanelStyle.accent.opacity(0.7))
                .padding(.leading, 6)
        }
        .frame(height: 20, alignment: .center)
        .onReceive(tick) { _ in
            guard !reduceMotion else { bars = Array(repeating: voice.level, count: 26); return }
            bars.removeFirst()
            bars.append(voice.level)
            phase += 0.45
        }
        .animation(reduceMotion ? nil : .linear(duration: Self.tickInterval), value: bars)
        .accessibilityLabel("Listening")
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// Voice level drives the height; a small traveling ripple keeps the strip
    /// visibly alive in silence — scrolling *flat* bars is indistinguishable from
    /// a frozen UI, which defeats the whole "am I being recorded?" signal.
    private func barHeight(_ i: Int) -> CGFloat {
        let idle = reduceMotion ? 0 : (sin(Double(i) * 0.55 + phase) + 1) * 1.6
        return 3 + idle + CGFloat(bars[i]) * 15
    }
}

/// The mic control: idle → start listening; listening → stop & review (pulsing
/// with the live input level); transcribing → spinner. Hidden while voice is off
/// or setting up. A standalone view so the ~10 Hz `voice.level` updates re-render
/// only this button — not the whole compose body (mirror included).
struct MicButton: View {
    @Bindable var voice: VoiceController
    let size: CGFloat
    let rowHeight: CGFloat
    var onStopAndReview: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isRecording = voice.phase == .recording
        switch voice.phase {
        case .ready, .recording, .transcribing:
            Button(action: toggle) {
                Group {
                    if voice.phase == .transcribing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: isRecording ? "mic.fill" : "mic")
                            .scaledFont(14, weight: .semibold)
                    }
                }
                .frame(width: size, height: size)
                .background(
                    isRecording
                        ? PanelStyle.accent.opacity(0.25 + 0.5 * Double(voice.level))
                        : Color.primary.opacity(0.12),
                    in: Circle())
                // A ring that swells with the input level — motion outside the
                // circle's bounds reads as "live" even at a glance.
                .overlay(
                    Circle()
                        .strokeBorder(PanelStyle.accent.opacity(isRecording ? 0.35 + 0.45 * Double(voice.level) : 0), lineWidth: 1.5)
                        .scaleEffect(isRecording ? 1.15 + CGFloat(voice.level) * 0.45 : 1)
                )
                .foregroundStyle(isRecording ? PanelStyle.accent : .secondary)
                .frame(height: rowHeight)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: voice.level)
            }
            .buttonStyle(.plain)
            .help(isRecording ? "Stop & review (Return)" : "Speak your message")
            .accessibilityLabel(isRecording ? "Stop listening" : "Start voice input")
        default:
            EmptyView()
        }
    }

    private func toggle() {
        switch voice.phase {
        case .ready:     Task { await voice.beginRecording() }
        case .recording: onStopAndReview()
        default:         break
        }
    }
}
