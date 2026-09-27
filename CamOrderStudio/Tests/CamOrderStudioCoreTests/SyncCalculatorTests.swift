import XCTest
@testable import CamOrderStudioCore

final class SyncCalculatorTests: XCTestCase {
    func testMillisecondsMoveDelayedVideoEarlierAndRefineExistingOffset() throws {
        let value = try SyncCalculator.compare(logic: "00:36.240", video: "00:36.160", format: .decimalSeconds)
        XCTAssertEqual(value.milliseconds, -80, accuracy: 0.000001)
        XCTAssertEqual(value.resultingOffset(from: -82), -162, accuracy: 0.000001)
        XCTAssertEqual(try SyncCalculator.compare(logic: "01:00:36.160", video: "01:00:36.240", format: .decimalSeconds).milliseconds, 80, accuracy: 0.000001)
    }
    func testMillisecondsCrossSecondMinuteAndHourBoundaries() throws {
        for (logic, video) in [("00:01.020", "00:00.980"), ("01:00.020", "00:59.980"), ("01:00:00.020", "00:59:59.980")] {
            XCTAssertEqual(try SyncCalculator.compare(logic: logic, video: video, format: .decimalSeconds).milliseconds, -40, accuracy: 0.000001)
        }
        XCTAssertEqual(try SyncCalculator.parse("  00:36.16036\n", format: .decimalSeconds).seconds, 36.16036, accuracy: 0.000001)
    }
    func testFramesRequireAnExplicitRateAndConvertByThatRate() throws {
        XCTAssertThrowsError(try SyncCalculator.parse("00:36:16", format: .frames))
        for rate in SyncClockRate.allCases {
            let value = try SyncCalculator.compare(logic: "01:00:36:16", video: "01:00:36:14", format: .frames, rate: rate)
            XCTAssertEqual(value.milliseconds, -2000 / rate.fps, accuracy: 0.000001)
        }
        XCTAssertEqual(SyncClockRate.fps23_976.fps, 23.976023976, accuracy: 0.000001)
    }
    func testBitsAreEightyFractionsPerFrameRatherThanMilliseconds() throws {
        let value = try SyncCalculator.compare(logic: "00:36:16.40", video: "00:36:16.00", format: .framesAndBits, rate: .fps25)
        XCTAssertEqual(value.milliseconds, -20, accuracy: 0.000001)
        XCTAssertThrowsError(try SyncCalculator.parse("00:36:16.80", format: .framesAndBits, rate: .fps25))
        XCTAssertThrowsError(try SyncCalculator.parse("00:36.16036", format: .framesAndBits, rate: .fps25), "Do not silently split an ambiguous decimal tail")
    }
    func testSamplesUseTheSelectedSampleRateAndExplicitFormat() throws {
        let value = try SyncCalculator.parse("00:36.16036", format: .secondsAndSamples, sampleRate: 48000)
        XCTAssertEqual(value.seconds, 36 + 16036.0 / 48000, accuracy: 0.000001)
        XCTAssertNotEqual(value.seconds, 36.16036)
        let delta = try SyncCalculator.compare(logic: "00:36.20000", video: "00:36.16064", format: .secondsAndSamples, sampleRate: 48000)
        XCTAssertEqual(delta.milliseconds, -82, accuracy: 0.000001)
        XCTAssertThrowsError(try SyncCalculator.parse("00:36.16036", format: .secondsAndSamples))
        XCTAssertThrowsError(try SyncCalculator.parse("00:36.48000", format: .secondsAndSamples, sampleRate: 48000))
    }
    func testFractionalFrameSamplesAndMilliseconds() throws {
        XCTAssertEqual(try SyncCalculator.parse("00:36:16.480", format: .framesAndSamples, rate: .fps30, sampleRate: 48000).seconds,
            36 + 16.0 / 30 + 0.01, accuracy: 0.000001)
        XCTAssertEqual(try SyncCalculator.parse("00:36:16.020", format: .framesAndMilliseconds, rate: .fps25).seconds, 36.66, accuracy: 0.000001)
        XCTAssertThrowsError(try SyncCalculator.parse("00:36:16.040", format: .framesAndMilliseconds, rate: .fps25))
        XCTAssertThrowsError(try SyncCalculator.parse("00:36:16.1600", format: .framesAndSamples, rate: .fps30, sampleRate: 48000))
    }
    func testDropFrameMinuteBoundaryAndInvalidLabels() throws {
        let value = try SyncCalculator.compare(logic: "00:01:00;02", video: "00:00:59;29", format: .frames, rate: .fps29_97DF)
        XCTAssertEqual(value.milliseconds, -1000 * 1001 / 30000, accuracy: 0.000001)
        XCTAssertThrowsError(try SyncCalculator.parse("00:01:00;01", format: .frames, rate: .fps29_97DF))
        XCTAssertNoThrow(try SyncCalculator.parse("00:10:00;00", format: .frames, rate: .fps29_97DF))
        XCTAssertThrowsError(try SyncCalculator.parse("00:01:00;02", format: .frames, rate: .fps29_97))
    }
    func testInvalidReadingsFailWithoutNormalizingOrCrashing() {
        for text in ["", "NaN", "00:60.000", "24:00:00.000", "00:36.-1", "00:36.1e3", "00:36.", "00::36.160", "٠٠:٣٦.١٦٠", "1000000000000000000000000000:00.0"] {
            XCTAssertThrowsError(try SyncCalculator.parse(text, format: .decimalSeconds), text)
        }
        XCTAssertThrowsError(try SyncCalculator.parse("00:36:30", format: .frames, rate: .fps30))
        XCTAssertThrowsError(try SyncCalculator.compare(logic: "bad", video: "00:36.160", format: .decimalSeconds)) {
            XCTAssertTrue($0.localizedDescription.hasPrefix("Logic time:"))
        }
    }
}
