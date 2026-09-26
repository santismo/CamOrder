import XCTest
@preconcurrency import AVFoundation
@testable import CamOrderStudioCore

private final class CaptureResult: @unchecked Sendable {
    let lock = NSLock()
    var hostTime: Double?
    var duration: Double = 0
    var error: String?
    var previewCount = 0
    func previewed() { lock.lock(); defer { lock.unlock() }; previewCount += 1 }
    func started(_ value: Double) { lock.lock(); defer { lock.unlock() }; hostTime = value }
    func finished(_ value: Double, _ message: String?) { lock.lock(); defer { lock.unlock() }; duration = value; error = message }
}
final class CaptureWriterTests: XCTestCase {
    func testWriterAnchorsToFirstFrameTimestampAndProducesPlayableMovie() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = CaptureWriter()
        let result = CaptureResult()
        let finished = expectation(description: "writer finalized")
        writer.onStarted = { result.started($0) }
        writer.onFinished = { _, duration, error in result.finished(duration, error); finished.fulfill() }
        writer.queue.async { writer.begin(url: url) }
        for frame in 0..<12 {
            let sample = try makeSample(seconds: 1000 + Double(frame) / 30)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                writer.queue.async {
                    writer.captureOutput(AVCaptureVideoDataOutput(), didOutput: sample, from: AVCaptureConnection(inputPorts: [], output: AVCaptureVideoDataOutput()))
                    continuation.resume()
                }
            }
            try await Task.sleep(nanoseconds: 34_000_000)
        }
        writer.queue.async { writer.finish() }
        await fulfillment(of: [finished], timeout: 10)
        XCTAssertEqual(try XCTUnwrap(result.hostTime), 1000, accuracy: 0.000001)
        XCTAssertEqual(result.duration, 0.4, accuracy: 0.04)
        XCTAssertNil(result.error)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 0.4, accuracy: 0.04)
        let video = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(video.count, 1)
    }
    func testTwelveSecondRecordingWithContinuousPreviewDoesNotStopEarly() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("long.mov"), framesURL = folder.appendingPathComponent("preview.frames")
        let writer = CaptureWriter()
        let result = CaptureResult()
        let finished = expectation(description: "long recording finalized")
        writer.onStarted = { result.started($0) }
        writer.onFinished = { _, duration, error in result.finished(duration, error); finished.fulfill() }
        writer.previewPublisher = try PreviewPublisher(url: framesURL)
        let receiver = PreviewReceiver(url: framesURL) { _ in result.previewed() }
        writer.queue.async { writer.begin(url: url) }
        for frame in 0..<360 {
            let sample = try makeSample(seconds: 2000 + Double(frame) / 30, width: 960, height: 540)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                writer.queue.async {
                    writer.captureOutput(AVCaptureVideoDataOutput(), didOutput: sample, from: AVCaptureConnection(inputPorts: [], output: AVCaptureVideoDataOutput()))
                    continuation.resume()
                }
            }
            try await Task.sleep(nanoseconds: 34_000_000)
        }
        writer.queue.async { writer.finish() }
        await fulfillment(of: [finished], timeout: 10)
        withExtendedLifetime(receiver) {}
        XCTAssertEqual(result.duration, 12, accuracy: 0.06)
        let duration = try await AVURLAsset(url: url).load(.duration)
        XCTAssertEqual(duration.seconds, 12, accuracy: 0.06)
        XCTAssertNil(result.error)
        XCTAssertGreaterThan(result.previewCount, 240, "Preview should comfortably exceed the old 10-fps limit")
        print("SUSTAINED CAPTURE: 12 seconds, \(result.previewCount) delivered preview frames, \(result.error ?? "no recording warnings")")
    }
    func testStopBeforeFirstFrameReportsFailureInsteadOfPhantomTake() async {
        let writer = CaptureWriter()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        let finished = expectation(description: "empty capture completed")
        writer.onFinished = { _, duration, message in
            XCTAssertEqual(duration, 0); XCTAssertNotNil(message)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            finished.fulfill()
        }
        writer.queue.async { writer.begin(url: url); writer.finish() }
        await fulfillment(of: [finished], timeout: 5)
    }
    private func makeSample(seconds: Double, width: Int = 64, height: Int = 64) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixel)
        let buffer = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 100, CVPixelBufferGetBytesPerRow(buffer) * height)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample)
        return try XCTUnwrap(sample)
    }
}
