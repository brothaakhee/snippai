import AVFoundation
import XCTest

@testable import SnippAIKit

final class VoiceTranscriberTests: XCTestCase {

    // MARK: - Model cache detection

    func testModelsCachedFalseForEmptyDirectory() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        XCTAssertFalse(VoiceTranscriber.modelsCached(in: empty))
    }

    func testDefaultModelsDirectoryIsAppSupportFluidAudio() {
        let dir = VoiceTranscriber.defaultModelsDirectory
        XCTAssertTrue(dir.path.contains("Application Support"))
        XCTAssertTrue(dir.path.contains("FluidAudio"))
    }

    // MARK: - End-to-end transcription (uses the real cached models; skips when absent
    // so CI and fresh checkouts stay green)

    func testTranscribesSynthesizedSpeech() async throws {
        try XCTSkipUnless(
            VoiceTranscriber.modelsCached(in: VoiceTranscriber.defaultModelsDirectory),
            "Parakeet models not cached — run `swift run fluid-spike` once to download")

        let expected = "open the settings window and check the license status"
        let samples = try Self.synthesize(expected)

        let transcriber = VoiceTranscriber()
        try await transcriber.load()
        let text = try await transcriber.transcribe(samples)

        let got = Set(text.lowercased().filter { $0.isLetter || $0.isWhitespace }
            .split(separator: " ").map(String.init))
        let want = Set(expected.split(separator: " ").map(String.init))
        let recall = Double(want.intersection(got).count) / Double(want.count)
        XCTAssertGreaterThanOrEqual(recall, 0.8, "poor transcription: \"\(text)\"")
    }

    func testTranscribeBeforeLoadThrows() async throws {
        let transcriber = VoiceTranscriber()
        do {
            _ = try await transcriber.transcribe([Float](repeating: 0, count: 16000))
            XCTFail("expected an error before load()")
        } catch { /* expected */ }
    }

    // MARK: - Helpers

    /// `say` → 16 kHz mono Float32 samples (same pipeline as fluid-spike).
    private static func synthesize(_ text: String) throws -> [Float] {
        let tmp = FileManager.default.temporaryDirectory
        let aiff = tmp.appendingPathComponent("voice-test-\(UUID().uuidString).aiff")
        let wav = aiff.deletingPathExtension().appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: aiff); try? FileManager.default.removeItem(at: wav) }

        for (path, args) in [
            ("/usr/bin/say", ["-o", aiff.path, text]),
            ("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path]),
        ] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            try p.run()
            p.waitUntilExit()
        }
        let file = try AVAudioFile(forReading: wav)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buf)
        return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
    }
}
