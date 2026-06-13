import XCTest
@testable import SnippAIKit

/// Exercises the hand-rolled RFC 6455 frame decoder directly — the riskiest code,
/// verifiable without a live iTerm2 connection or a display.
final class WebSocketFramingTests: XCTestCase {
    typealias WS = ITermWebSocket

    private func decode(_ bytes: [UInt8], from: Int = 0, max: Int = 1 << 20) -> WS.DecodeResult {
        WS.decodeFrame(bytes, from: from, maxSize: max)
    }

    func testSingleBinaryFrame() {
        let payload: [UInt8] = [1, 2, 3, 4]
        let frame: [UInt8] = [0x82, 0x04] + payload   // FIN + binary, len 4, unmasked
        guard case .frame(let f, let next) = decode(frame) else { return XCTFail("expected frame") }
        XCTAssertTrue(f.fin)
        XCTAssertEqual(f.opcode, 0x2)
        XCTAssertEqual([UInt8](f.payload), payload)
        XCTAssertEqual(next, 6)
    }

    func testMultipleFramesInOneBuffer() {
        let buffer: [UInt8] = [0x82, 0x02, 0xAA, 0xBB,   // frame 1
                               0x82, 0x01, 0xCC]         // frame 2
        guard case .frame(let f1, let next1) = decode(buffer) else { return XCTFail() }
        XCTAssertEqual([UInt8](f1.payload), [0xAA, 0xBB])
        guard case .frame(let f2, let next2) = decode(buffer, from: next1) else { return XCTFail() }
        XCTAssertEqual([UInt8](f2.payload), [0xCC])
        XCTAssertEqual(next2, buffer.count)
    }

    func testIncompleteHeaderAndPayload() {
        if case .incomplete = decode([0x82]) {} else { XCTFail("1 byte should be incomplete") }
        // Claims 10 payload bytes but only 3 present.
        if case .incomplete = decode([0x82, 0x0A, 1, 2, 3]) {} else { XCTFail("short payload should be incomplete") }
    }

    func testFragmentedMessageOpcodes() {
        // First fragment: text, FIN=0.
        guard case .frame(let f1, _) = decode([0x01, 0x01, 0x41]) else { return XCTFail() }
        XCTAssertFalse(f1.fin)
        XCTAssertEqual(f1.opcode, 0x1)
        // Continuation: FIN=1.
        guard case .frame(let f2, _) = decode([0x80, 0x01, 0x42]) else { return XCTFail() }
        XCTAssertTrue(f2.fin)
        XCTAssertEqual(f2.opcode, 0x0)
    }

    func test16BitLength() {
        let len = 300
        let payload = [UInt8](repeating: 0x7E, count: len)
        let header: [UInt8] = [0x82, 126, UInt8(len >> 8), UInt8(len & 0xFF)]
        guard case .frame(let f, let next) = decode(header + payload) else { return XCTFail() }
        XCTAssertEqual(f.payload.count, len)
        XCTAssertEqual(next, header.count + len)
    }

    func testMaskedServerFrameRejected() {
        // Mask bit set on a server frame is a protocol violation.
        if case .error = decode([0x82, 0x81, 0, 0, 0, 0, 0xAB]) {} else {
            XCTFail("masked server frame must error")
        }
    }

    func testReservedOpcodeRejected() {
        if case .error = decode([0x83, 0x00]) {} else { XCTFail("reserved opcode 0x3 must error") }
    }

    func testReservedRSVBitsRejected() {
        if case .error = decode([0xC2, 0x00]) {} else { XCTFail("RSV1 set must error") }
    }

    func testOversizedControlFrameRejected() {
        // Ping (0x9) declaring a 200-byte payload via 16-bit length: control frames must be <= 125.
        if case .error = decode([0x89, 126, 0x00, 0xC8]) {} else { XCTFail("oversized control frame must error") }
    }

    func testNonFinalControlFrameRejected() {
        // Ping with FIN=0 (0x09) is illegal.
        if case .error = decode([0x09, 0x00]) {} else { XCTFail("fragmented control frame must error") }
    }

    func test64BitLengthOverMaxRejected() {
        // 64-bit length of 2000 with maxSize 1000 must be rejected before buffering.
        var header: [UInt8] = [0x82, 127]
        let len: UInt64 = 2000
        for shift in stride(from: 56, through: 0, by: -8) { header.append(UInt8((len >> shift) & 0xFF)) }
        if case .error = decode(header, max: 1000) {} else { XCTFail("over-max 64-bit length must error") }
    }

    func testControlPingValid() {
        guard case .frame(let f, _) = decode([0x89, 0x02, 0x12, 0x34]) else { return XCTFail() }
        XCTAssertEqual(f.opcode, 0x9)
        XCTAssertTrue(f.fin)
        XCTAssertEqual([UInt8](f.payload), [0x12, 0x34])
    }
}
