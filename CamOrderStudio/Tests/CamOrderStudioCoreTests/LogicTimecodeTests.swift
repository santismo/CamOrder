import XCTest
@testable import CamOrderStudioCore

final class LogicTimecodeTests: XCTestCase {
    private func quarter(_ hour: UInt8, _ second: UInt8, _ frame: UInt8 = 0) -> [UInt8] {
        let values: [UInt8] = [frame & 15, frame >> 4, second & 15, second >> 4, 0, 0, hour & 15, (hour >> 4) | 6]
        return values.enumerated().flatMap { [0xF1, UInt8($0.offset << 4) | $0.element] }
    }
    func testLocateMovesStoppedPlayheadWithoutRecording() throws {
        var decoder = LogicTimecodeDecoder()
        decoder.receive([0xF0,0x7F,0x7F,1,1,0x61,0,12,0,0xF7], hostTime: 100)
        let result = try XCTUnwrap(decoder.snapshot(now: 100))
        XCTAssertEqual(result.seconds, 3612)
        XCTAssertFalse(result.playing)
        decoder.receive([0xF0,0x7F,0x7F,6,6,0xF7], hostTime: 101) // MMC Record strobe is not playback.
        XCTAssertFalse(try XCTUnwrap(decoder.snapshot(now: 101)).playing)
        decoder.receive([0xF0,0x7F,0x7F,6,0x44,6,1,0x61,0,22,0,0,0xF7], hostTime: 102)
        XCTAssertEqual(decoder.snapshot(now: 102)?.seconds, 3622)
    }
    func testFragmentedQuarterFramesStartAndStopWithNoAUCallbacks() throws {
        var decoder = LogicTimecodeDecoder()
        let bytes = quarter(1, 12)
        for (i, byte) in bytes.enumerated() { decoder.receive([byte], hostTime: 100 + Double(i / 2) / 120) }
        let result = try XCTUnwrap(decoder.snapshot(now: 100.06))
        XCTAssertTrue(result.playing)
        XCTAssertEqual(result.startSeconds, 3612)
        XCTAssertEqual(result.startHostTime, 100)
        XCTAssertEqual(result.seconds, 3612.0683, accuracy: 0.002)
        let stopped = try XCTUnwrap(decoder.snapshot(now: 130))
        XCTAssertFalse(stopped.playing)
        XCTAssertLessThan(stopped.seconds, 3612.15)
        decoder.receive(quarter(1, 25), hostTime: 131)
        XCTAssertEqual(decoder.snapshot(now: 131)?.startSeconds, 3625)
    }
    func testMMCStopFreezesClockAndSplitSysExIsReassembled() throws {
        var decoder = LogicTimecodeDecoder()
        decoder.receive(quarter(1, 12), hostTime: 100)
        decoder.receive([0xF0,0x7F,0x7F], hostTime: 100.01)
        decoder.receive([6,1,0xF7], hostTime: 100.02)
        let stopped = try XCTUnwrap(decoder.snapshot(now: 101))
        XCTAssertFalse(stopped.playing)
        XCTAssertEqual(stopped.seconds, 3612 + 2.0 / 30 + 0.02, accuracy: 0.0001)
        XCTAssertEqual(decoder.snapshot(now: 200)?.seconds, stopped.seconds)
    }
    func testDropFrameAndIncompleteMessages() {
        var decoder = LogicTimecodeDecoder()
        decoder.receive([0xF1,0x76], hostTime: 100)
        XCTAssertNil(decoder.snapshot(now: 100))
        decoder.receive([0xF0,0x7F,0x7F,1,1,0x41,0,0,0,0xF7], hostTime: 101)
        XCTAssertEqual(decoder.snapshot(now: 101)!.seconds, 3599.9964, accuracy: 0.0001)
        decoder.receive([0xF0,0x7F,0x7F,1,1,0x61,88,0,0,0xF7], hostTime: 102)
        XCTAssertEqual(decoder.messageCount, 1)
    }
    func testCornerResizeKeepsIndependentAxesAndScale() {
        let drag = CanvasResize(pixels: CGSize(width: 3840, height: 2160), display: CGSize(width: 384, height: 216), left: false, top: false)
        XCTAssertEqual(drag.size(translation: CGSize(width: 20, height: 0)), CGSize(width: 4240, height: 2160))
        XCTAssertEqual(drag.size(translation: CGSize(width: 0, height: -10)), CGSize(width: 3840, height: 1960))
        let opposite = CanvasResize(pixels: drag.pixels, display: drag.display, left: true, top: true)
        XCTAssertEqual(opposite.size(translation: CGSize(width: -20, height: 10)), CGSize(width: 4240, height: 1960))
        XCTAssertEqual(drag.size(translation: CGSize(width: -9999, height: 9999)), CGSize(width: 320, height: 4320))
    }
}
