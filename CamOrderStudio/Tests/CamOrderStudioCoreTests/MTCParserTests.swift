import XCTest
@testable import CamOrderStudioCore

final class MTCParserTests: XCTestCase {
    func testQuarterFrameParserReconstructsTimecode() {
        let parser = MTCParser()
        let messages: [UInt8] = [
            0xF1, 0x0C,
            0xF1, 0x10,
            0xF1, 0x23,
            0xF1, 0x31,
            0xF1, 0x41,
            0xF1, 0x50,
            0xF1, 0x60,
            0xF1, 0x76
        ]

        let outputs = parser.receive(bytes: messages)

        XCTAssertEqual(outputs.last?.timecode, Timecode(hours: 0, minutes: 1, seconds: 19, frames: 12, frameRate: .fps30))
        XCTAssertEqual(outputs.last?.state, .chasing)
    }

    func testFullFrameParserEmitsLocateState() {
        let parser = MTCParser()
        let output = parser.receive(bytes: [0xF0, 0x7F, 0x7F, 0x01, 0x01, 0x60, 0x01, 0x23, 0x12, 0xF7]).last

        XCTAssertEqual(output?.timecode, Timecode(hours: 0, minutes: 1, seconds: 35, frames: 18, frameRate: .fps30))
        XCTAssertEqual(output?.state, .locating)
    }
}
