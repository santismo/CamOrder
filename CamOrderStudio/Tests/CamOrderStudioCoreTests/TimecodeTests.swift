import XCTest
@testable import CamOrderStudioCore

final class TimecodeTests: XCTestCase {
    func testTimecodeTotalFramesAndSeconds() {
        let timecode = Timecode(hours: 0, minutes: 1, seconds: 23, frames: 12, frameRate: .fps30)
        XCTAssertEqual(timecode.totalFrames, 2_502)
        XCTAssertEqual(timecode.secondsValue, 83.4, accuracy: 0.0001)
        XCTAssertEqual(timecode.description, "00:01:23:12")
    }

    func testTimecodeFromSecondsUsesFrameRate() {
        let timecode = Timecode.from(seconds: 83.4, frameRate: .fps30)
        XCTAssertEqual(timecode, Timecode(hours: 0, minutes: 1, seconds: 23, frames: 12, frameRate: .fps30))
    }
}
