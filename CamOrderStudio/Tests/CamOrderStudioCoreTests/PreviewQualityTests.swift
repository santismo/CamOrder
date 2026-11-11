import XCTest
import AppKit
import AVFoundation
@testable import CamOrderStudioCore

final class PreviewQualityTests: XCTestCase {
    func testLiveQualityReducesActualMailboxFramesWithoutChangingSource() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = try SharedPreview(url: folder, writable: true), reader = try SharedPreview(url: folder, writable: false)
        let context = CIContext()
        var pixel: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_32BGRA, nil, &pixel)
        let buffer = try XCTUnwrap(pixel)
        context.render(CIImage(color: CIColor(red: 1, green: 0, blue: 0)), to: buffer)
        var sequence: UInt64 = 0
        for (quality, width, height) in [(PreviewQuality.full, 960, 540), (.balanced, 640, 360), (.light, 320, 180), (.full, 960, 540)] {
            writer.publish(buffer, context: context, quality: quality)
            let image = try XCTUnwrap(reader.copyNewFrame(after: &sequence))
            XCTAssertEqual(image.width, width); XCTAssertEqual(image.height, height)
            let color = try XCTUnwrap(NSBitmapImageRep(cgImage: image).colorAt(x: width / 2, y: height / 2)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(color.redComponent, 0.95)
            XCTAssertEqual(CVPixelBufferGetWidth(buffer), 1920)
            XCTAssertEqual(CVPixelBufferGetHeight(buffer), 1080)
        }
    }

    func testProxyKeepsTimingOrientationAndOriginalAndInvalidatesChangedSource() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mov")
        try await makeMovie(source, rotated: true)
        let original = try Data(contentsOf: source)
        let cache = PreviewProxyCache(folder: folder.appendingPathComponent("cache"))
        for quality in [PreviewQuality.balanced, .light] {
            let proxy = try await cache.prepare(source, quality: quality)
            XCTAssertNotEqual(proxy, source)
            let movie = AVURLAsset(url: proxy)
            let duration = try await movie.load(.duration)
            XCTAssertEqual(duration.seconds, 2, accuracy: 0.035)
            let tracks = try await movie.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let size = try await track.load(.naturalSize)
            XCTAssertLessThanOrEqual(size.width * size.height, quality == .balanced ? 1280 * 720 : 640 * 480)
            let transform = try await track.load(.preferredTransform)
            let displayed = CGRect(origin: .zero, size: size).applying(transform)
            XCTAssertGreaterThan(abs(displayed.height), abs(displayed.width), "Portrait orientation must survive")
            let audio = try await movie.loadTracks(withMediaType: .audio)
            XCTAssertTrue(audio.isEmpty)
            let generator = AVAssetImageGenerator(asset: movie)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            for (seconds, red) in [(0.2, true), (0.99, true), (1.0, true), (1.02, false), (1.2, false)] {
                let image = try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
                let color = try XCTUnwrap(NSBitmapImageRep(cgImage: image).colorAt(x: image.width / 2, y: image.height / 2)?.usingColorSpace(.deviceRGB))
                XCTAssertGreaterThan(red ? color.redComponent : color.blueComponent, 0.9)
            }
            let reused = try await cache.prepare(source, quality: quality)
            XCTAssertEqual(reused, proxy)
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: source.path)
        let stale = await cache.cachedURL(for: source, quality: .light)
        XCTAssertNil(stale)
    }

    func testCancelledPreparationLeavesNoPartialMovie() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mov")
        try await makeMovie(source, rotated: false)
        let cache = PreviewProxyCache(folder: folder.appendingPathComponent("cache"))
        let task = Task { try await cache.prepare(source, quality: .light) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled conversion must not complete") }
        catch { XCTAssertTrue(error is CancellationError) }
        let files = (try? FileManager.default.contentsOfDirectory(at: cache.folder, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(files.isEmpty)
        let active = Task { try await cache.prepare(source, quality: .light) }
        try await Task.sleep(nanoseconds: 100_000_000)
        active.cancel()
        do { _ = try await active.value } // A very fast completed export is also valid.
        catch { XCTAssertTrue(error is CancellationError) }
        let remaining = (try? FileManager.default.contentsOfDirectory(at: cache.folder, includingPropertiesForKeys: nil)) ?? []
        XCTAssertFalse(remaining.contains { $0.lastPathComponent.contains("partial") })
    }

    private func makeMovie(_ url: URL, rotated: Bool) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1920, AVVideoHeightKey: 1080])
        if rotated { input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        writer.add(input)
        XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var pixel: CVPixelBuffer?
            CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_32BGRA, nil, &pixel)
            let buffer = try XCTUnwrap(pixel)
            context.render(CIImage(color: CIColor(red: frame < 15 ? 1 : 0, green: 0, blue: frame < 15 ? 0 : 1)), to: buffer)
            // Alternating intervals exercise variable frame timing as well as portrait video.
            let ticks = frame * 40 + (frame % 2 == 1 ? 10 : 0)
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(ticks), timescale: 600)))
        }
        writer.endSession(atSourceTime: CMTime(seconds: 2, preferredTimescale: 600))
        input.markAsFinished(); await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }
}
