import AVFoundation
import FluidAudio
import Foundation

// De-risking spike: prove local ASR end-to-end and measure what a user would feel.
//   1. Synthesize a known sentence with `say` (no mic/TCC needed for automation).
//   2. Download + load the Parakeet CoreML models (first run downloads from HuggingFace).
//   3. Transcribe and report: download/load/transcribe wall times + accuracy vs the known text.

let expected = "fix the database connection and use the variables in this screenshot"

func run(_ path: String, _ args: [String]) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw NSError(domain: "spike", code: Int(p.terminationStatus)) }
}

func stamp(_ label: String, since: Date) {
    print(String(format: "[%6.2fs] %@", Date().timeIntervalSince(since), label))
}

let t0 = Date()
let tmp = FileManager.default.temporaryDirectory
let aiff = tmp.appendingPathComponent("fluid-spike.aiff")
let wav = tmp.appendingPathComponent("fluid-spike.wav")

// 1. Synthesize + convert to what Parakeet expects: 16 kHz mono.
try run("/usr/bin/say", ["-o", aiff.path, expected])
try run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path])
stamp("synthesized test speech (\(expected.split(separator: " ").count) words)", since: t0)

// Load samples as Float32 [-1, 1].
let file = try AVAudioFile(forReading: wav)
let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
try file.read(into: buf)
let samples = Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
print("           audio: \(String(format: "%.1f", Double(samples.count) / 16000))s, \(samples.count) samples")

// 2. Download (first run) + load the Parakeet Unified models — measures the
//    first-run wait a user would experience, then warm loads on later runs.
let tDownload = Date()
let manager = UnifiedAsrManager()
try await manager.loadModels()
stamp("models ready (\(String(format: "%.1f", Date().timeIntervalSince(tDownload)))s for download+load)", since: t0)

// 3. Transcribe (twice — the first call includes ANE warmup).
var lastText = ""
for pass in 1...2 {
    let tx = Date()
    lastText = try await manager.transcribe(samples)
    let ms = Date().timeIntervalSince(tx) * 1000
    print(String(format: "           pass %d: %.0fms → \"%@\"", pass, ms, lastText))
}

// Accuracy: crude word overlap vs the known sentence.
let got = Set(lastText.lowercased().filter { $0.isLetter || $0.isWhitespace }.split(separator: " ").map(String.init))
let want = Set(expected.split(separator: " ").map(String.init))
print("           word recall: \(want.intersection(got).count)/\(want.count)")
stamp("done", since: t0)
