import XCTest
import CoreGraphics
@testable import CamOrderStudioCore

final class AutomaticMotionTests: XCTestCase {
    private func clip() -> VideoClip {
        VideoClip(clipId: "test", mediaAssetId: "media", videoFile: "test.mov", armedLaneId: "lane_1",
                  logicStartTimecode: .from(seconds: 12, frameRate: .fps30), logicStartSeconds: 12,
                  durationSeconds: 10, frameRate: .fps30, trimInSeconds: 2,
                  framing: ClipFraming(), playbackSyncOffsetSeconds: -0.082, compositingLayer: 2, recordedSourceOriginSeconds: 10)
    }
    func testDirectionsZoomAndCoverageForDifferentAspectRatios() throws {
        let canvas = CGSize(width: 1920, height: 1080)
        for source in [canvas, CGSize(width: 1080, height: 1920), CGSize(width: 1000, height: 1000)] {
            for pan in MotionPan.allCases {
                for zoom in [MotionZoom.zoomIn, .zoomOut] {
                    var motion = AutomaticMotion(); motion.pan = pan; motion.zoom = zoom
                    motion.focalX = 0.8; motion.focalY = -0.7
                    let result = try motion.applying(to: clip(), sourceSize: source, canvasSize: canvas)
                    let first = result.automatedFraming(atLocalSecond: 0), last = result.automatedFraming(atLocalSecond: 10)
                    XCTAssertEqual(zoom == .zoomIn, last.zoom > first.zoom)
                    for step in 0...100 { assertCovered(result.automatedFraming(atLocalSecond: Double(step) / 10), source: source, canvas: canvas) }
                }
            }
        }
        var pan = AutomaticMotion(); pan.zoom = .none; pan.pan = .upRight
        let result = try pan.applying(to: clip(), sourceSize: canvas, canvasSize: canvas)
        XCTAssertLessThan(result.automatedFraming(atLocalSecond: 10).offsetX, result.automatedFraming(atLocalSecond: 0).offsetX)
        XCTAssertGreaterThan(result.automatedFraming(atLocalSecond: 10).offsetY, result.automatedFraming(atLocalSecond: 0).offsetY)
    }
    func testFocalPointStaysSteadyDuringZoomAndReplacementKeepsTiming() throws {
        var motion = AutomaticMotion(); motion.focalX = 0.7; motion.focalY = -0.6; motion.zoomAmount = 0.4
        let original = clip(), size = CGSize(width: 1920, height: 1080)
        let result = try motion.applying(to: original, sourceSize: size, canvasSize: size)
        let a = result.automatedFraming(atLocalSecond: 0), b = result.automatedFraming(atLocalSecond: 10)
        XCTAssertEqual((motion.focalX - a.offsetX) / a.zoom, (motion.focalX - b.offsetX) / b.zoom, accuracy: 1e-9)
        XCTAssertEqual((motion.focalY - a.offsetY) / a.zoom, (motion.focalY - b.offsetY) / b.zoom, accuracy: 1e-9)
        var withoutFraming = result
        withoutFraming.framing = original.framing; withoutFraming.automationMarkers = original.automationMarkers
        XCTAssertEqual(withoutFraming, original, "Motion cannot move, trim, relayer or resync the region")
        motion.combineWithExisting = false
        XCTAssertEqual(try motion.applying(to: result, sourceSize: size, canvasSize: size).automationMarkers.count, 2)
    }
    func testCombineRetainsExistingCurveAndRepeatedApplicationsHaveBoundedKeys() throws {
        var original = clip()
        original.automationMarkers = [ClipAutomationMarker(timeSeconds: 0, framing: ClipFraming(zoom: 1.1, offsetX: 0.1)),
                                      ClipAutomationMarker(timeSeconds: 10, framing: ClipFraming(zoom: 1.4, offsetX: 0.3))]
        var motion = AutomaticMotion(); motion.zoom = .none; motion.pan = .right; motion.keepEdgesCovered = false
        let size = CGSize(width: 1920, height: 1080)
        var result = try motion.applying(to: original, sourceSize: size, canvasSize: size)
        for step in 0...100 {
            let t = Double(step) / 100, ease = t * t * (3 - 2 * t)
            let old = original.automatedFraming(atLocalSecond: t * 10), new = result.automatedFraming(atLocalSecond: t * 10)
            XCTAssertEqual(new.zoom, old.zoom, accuracy: 0.002)
            XCTAssertEqual(new.offsetX, old.offsetX - 0.08 * (ease - 0.5), accuracy: 0.002)
        }
        let count = result.automationMarkers.count
        for _ in 0..<5 { result = try motion.applying(to: result, sourceSize: size, canvasSize: size) }
        XCTAssertLessThanOrEqual(result.automationMarkers.count, count + 2)
    }
    func testRotatingAndOffsetAnimationRemainsCoveredBetweenKeys() throws {
        var original = clip()
        original.automationMarkers = [ClipAutomationMarker(timeSeconds: 0, framing: ClipFraming(zoom: 1.2, offsetX: -0.12, rotationDegrees: -30)),
                                      ClipAutomationMarker(timeSeconds: 10, framing: ClipFraming(zoom: 1.4, offsetY: 0.2, rotationDegrees: 140))]
        var motion = AutomaticMotion(); motion.pan = .downLeft; motion.zoom = .zoomOut
        let size = CGSize(width: 1920, height: 1080)
        let result = try motion.applying(to: original, sourceSize: size, canvasSize: size)
        for step in 0...1000 { assertCovered(result.automatedFraming(atLocalSecond: Double(step) / 100), source: size, canvas: size) }
    }
    func testGeneratedAnimationSurvivesSplitTrimAndLegacyDecoding() throws {
        var motion = AutomaticMotion(); motion.pan = .left
        let original = try motion.applying(to: clip(), sourceSize: CGSize(width: 1920, height: 1080), canvasSize: CGSize(width: 1920, height: 1080))
        let (_, right) = try XCTUnwrap(original.split(at: 16))
        XCTAssertEqual(right.automatedFraming(atLocalSecond: 1), original.automatedFraming(atLocalSecond: 5))
        var trimmed = original; trimmed.trimLeftEdge(to: 15)
        XCTAssertEqual(trimmed.automatedFraming(atLocalSecond: 2), original.automatedFraming(atLocalSecond: 5))
        XCTAssertEqual(try JSONDecoder().decode(VideoClip.self, from: JSONEncoder().encode(right)), right)
        let legacy = Data(#"{"id":"old","timeSeconds":1,"framing":{"zoom":1}}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ClipAutomationMarker.self, from: legacy).interpolation)
    }
    func testInvalidAndImpossibleCoverageFailsWithoutChangingInput() {
        let original = clip(), size = CGSize(width: 1920, height: 1080)
        var motion = AutomaticMotion(); motion.zoomAmount = .nan
        XCTAssertThrowsError(try motion.applying(to: original, sourceSize: size, canvasSize: size))
        motion.zoomAmount = 0.08
        XCTAssertThrowsError(try motion.applying(to: original, sourceSize: CGSize(width: 1, height: 10000), canvasSize: size))
        motion.keepEdgesCovered = false
        XCTAssertNoThrow(try motion.applying(to: original, sourceSize: CGSize(width: 1, height: 10000), canvasSize: size))
        XCTAssertEqual(original.automationMarkers.count, 0)
    }
    func testAlreadyCoveredFramingDoesNotAccumulateExtraCrop() throws {
        var original = clip(); original.framing = ClipFraming(zoom: 2)
        var motion = AutomaticMotion(); motion.zoom = .none; motion.pan = .right
        let size = CGSize(width: 1920, height: 1080)
        let result = try motion.applying(to: original, sourceSize: size, canvasSize: size)
        XCTAssertEqual(result.automatedFraming(atLocalSecond: 0).zoom, 2)
        XCTAssertEqual(result.automatedFraming(atLocalSecond: 10).zoom, 2)
    }
    func testLinearAffineExportRampsKeepCornersCovered() throws {
        let canvas = CGSize(width: 1920, height: 1080), source = CGSize(width: 1080, height: 1920)
        var original = clip()
        original.automationMarkers = [ClipAutomationMarker(timeSeconds: 0, framing: ClipFraming(zoom: 1.2, offsetX: -0.2, rotationDegrees: 175)),
                                      ClipAutomationMarker(timeSeconds: 10, framing: ClipFraming(zoom: 1.4, offsetY: 0.3, rotationDegrees: -70))]
        var motion = AutomaticMotion(); motion.pan = .upRight; motion.zoom = .zoomOut
        motion.panAmount = 0.16; motion.zoomAmount = 0.35; motion.focalX = 0.7
        let result = try motion.applying(to: original, sourceSize: source, canvasSize: canvas)
        func matrix(_ pose: ClipFraming) -> [Double] {
            let s = Double(min(canvas.width / source.width, canvas.height / source.height)) * pose.zoom
            let angle = -pose.rotationDegrees * .pi / 180
            return [cos(angle) * s, sin(angle) * s, -sin(angle) * s, cos(angle) * s,
                    Double(canvas.width) * (1 + pose.offsetX) / 2, Double(canvas.height) * (1 + pose.offsetY) / 2]
        }
        for index in 0..<(result.automationMarkers.count - 1) {
            let a = matrix(result.automationMarkers[index].framing), b = matrix(result.automationMarkers[index + 1].framing)
            for step in 0...16 {
                let t = Double(step) / 16, m = zip(a, b).map { $0 + ($1 - $0) * t }
                let inverse = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5]).inverted()
                for x in [0.0, canvas.width] { for y in [0.0, canvas.height] {
                    let pixel = CGPoint(x: x, y: y).applying(inverse)
                    XCTAssertLessThanOrEqual(abs(pixel.x), source.width / 2)
                    XCTAssertLessThanOrEqual(abs(pixel.y), source.height / 2)
                } }
            }
        }
    }
    private func assertCovered(_ pose: ClipFraming, source: CGSize, canvas: CGSize, file: StaticString = #filePath, line: UInt = #line) {
        let scale = min(canvas.width / source.width, canvas.height / source.height) * pose.zoom
        let center = CGPoint(x: canvas.width * (1 + pose.offsetX) / 2, y: canvas.height * (1 + pose.offsetY) / 2)
        let inverseRotation = CGAffineTransform(rotationAngle: pose.rotationDegrees * .pi / 180)
        for x in [0.0, canvas.width] { for y in [0.0, canvas.height] {
            let point = CGPoint(x: x - center.x, y: y - center.y).applying(inverseRotation)
            XCTAssertLessThanOrEqual(abs(point.x), source.width * scale / 2 + 1e-6, file: file, line: line)
            XCTAssertLessThanOrEqual(abs(point.y), source.height * scale / 2 + 1e-6, file: file, line: line)
        } }
    }
}
