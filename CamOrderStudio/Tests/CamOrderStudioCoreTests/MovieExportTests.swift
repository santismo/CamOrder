import XCTest
import AVFoundation
import AppKit
@testable import CamOrderStudioCore

final class MovieExportTests: XCTestCase {
    // Real encoded frames catch invalid composition instructions, black-gap regressions,
    // trimming errors and accidental source replacement; not just model round-trips.
    @MainActor
    func testExportPreservesGapsAndSupportsTrimmedMovie() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let red = folder.appendingPathComponent("red.mov")
        let blue = folder.appendingPathComponent("blue.mov")
        try await makeMovie(at: red, red: true)
        try await makeMovie(at: blue, red: false)
        var project = CamOrderProject.empty(name: "Export test")
        project.exportSettings.canvasWidth = 64; project.exportSettings.canvasHeight = 64
        project.exportSettings.audioMode = .muteAll
        let assets = [MediaAsset(kind: .video, displayName: "red", relativePath: "red.mov"), MediaAsset(kind: .video, displayName: "blue", relativePath: "blue.mov")]
        project.media = assets
        project.timeline.lanes[0].clips = assets.enumerated().map { index, asset in
            VideoClip(clipId: asset.id, mediaAssetId: asset.id, videoFile: asset.relativePath, armedLaneId: "lane_1",
                logicStartTimecode: Timecode.from(seconds: Double(index * 2 + 1), frameRate: .fps30),
                logicStartSeconds: Double(index * 2 + 1), durationSeconds: 1, frameRate: .fps30, playbackSyncOffsetSeconds: 0)
        }
        project.timeline.durationSeconds = 4
        let engine = RenderExportEngine()
        let full = folder.appendingPathComponent("full.mov")
        try await engine.export(project: project, from: folder, to: full)
        let asset = AVURLAsset(url: full)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 4, accuracy: 0.05)
        XCTAssertLessThan(try pixel(asset, at: 0.5).red, 0.08)
        XCTAssertGreaterThan(try pixel(asset, at: 1.5).red, 0.8)
        XCTAssertLessThan(try pixel(asset, at: 2.5).red, 0.08)
        XCTAssertGreaterThan(try pixel(asset, at: 3.5).blue, 0.8)
        let trimmed = folder.appendingPathComponent("trimmed.mp4")
        try await engine.export(project: project, from: folder, to: trimmed, fromFirstClip: true)
        let trimmedAsset = AVURLAsset(url: trimmed)
        let trimmedDuration = try await trimmedAsset.load(.duration)
        XCTAssertEqual(trimmedDuration.seconds, 3, accuracy: 0.05)
        XCTAssertGreaterThan(try pixel(trimmedAsset, at: 0.5).red, 0.8)
        XCTAssertEqual(RenderExportEngine.firstVisibleClipSeconds(in: project), 1)
        let original = try Data(contentsOf: red)
        do {
            try await engine.export(project: project, from: folder, to: red)
            XCTFail("Export must refuse to replace source media")
        } catch { XCTAssertEqual(try Data(contentsOf: red), original) }
        // Existing successful exports may be replaced only after a new export succeeds.
        try await engine.export(project: project, from: folder, to: full)
        XCTAssertGreaterThan(try Data(contentsOf: full).count, 100)
    }

    @MainActor
    func testHostedTransportUsesSecondsWithoutSMPTEHourGuess() {
        let engine = LogicSyncEngine(isHosted: true)
        engine.startMTCInput()
        engine.receiveHostPosition(seconds: 3602.125, playing: true, tempo: 97, available: true)
        XCTAssertEqual(engine.displaySeconds, 3602.125)
        XCTAssertTrue(engine.isTransportRolling)
        XCTAssertEqual(engine.detectedTempoBPM, 97)
        engine.receiveHostPosition(seconds: 12, playing: false, tempo: 97, available: true)
        XCTAssertEqual(engine.stopTimecodeForPlacement().secondsValue, 12)
        XCTAssertFalse(engine.isTransportRolling)
    }

    private func pixel(_ asset: AVAsset, at seconds: Double) throws -> (red: Double, blue: Double) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let image = try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
        let bitmap = NSBitmapImageRep(cgImage: image)
        let color = try XCTUnwrap(bitmap.colorAt(x: image.width / 2, y: image.height / 2)?.usingColorSpace(.deviceRGB))
        return (color.redComponent, color.blueComponent)
    }
    private func makeMovie(at url: URL, red: Bool) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixelBuffer = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let bytes = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            for y in 0..<64 { for x in 0..<64 {
                bytes[y * stride + x * 4] = red ? 0 : 255
                bytes[y * stride + x * 4 + 1] = 0
                bytes[y * stride + x * 4 + 2] = red ? 255 : 0
                bytes[y * stride + x * 4 + 3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
    }
}
