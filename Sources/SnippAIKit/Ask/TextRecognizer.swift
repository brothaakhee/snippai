import CoreGraphics
import Vision

/// On-device OCR for a captured screen region (Apple Vision — no network, no
/// new dependencies). Spike-validated: a full Retina screen recognizes in ~1.1s;
/// the small regions Ask captures land well under 300 ms.
public enum TextRecognizer {
    /// Recognized lines joined in reading order. Language correction is OFF —
    /// screen text is identifiers, flags, and jargon, not prose to "fix".
    public static func recognize(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
