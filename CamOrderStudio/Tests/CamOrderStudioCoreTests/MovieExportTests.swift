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
    func testSyncIsBakedIntoEditedExportAtTheSameImportPosition() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await makeMovie(at: folder.appendingPathComponent("cue.mov"), red: true, changingAtFrame: 8)
        var project = CamOrderProject.empty(name: "Fixed anchor")
        project.exportSettings.canvasWidth = 64; project.exportSettings.canvasHeight = 64
        project.exportSettings.audioMode = .muteAll
        let asset = MediaAsset(kind: .video, displayName: "Cue", relativePath: "cue.mov")
        project.media = [asset]
        let clip = VideoClip(clipId: "cue", mediaAssetId: asset.id, videoFile: asset.relativePath, armedLaneId: project.timeline.lanes[0].id,
            logicStartTimecode: .from(seconds: 10, frameRate: .fps30), logicStartSeconds: 10, durationSeconds: 0.8, frameRate: .fps30, trimInSeconds: 0.1)
        project.timeline.lanes[0].clips = [clip]
        for offset in [0.0, -82.0, 82.0] {
            project.sync.videoOffsetMS = offset
            let range = try XCTUnwrap(RenderExportEngine.editedRange(in: project))
            XCTAssertEqual(range.startSeconds, 10)
            XCTAssertEqual(range.endSeconds, 10.8)
            let output = folder.appendingPathComponent("offset-\(Int(offset)).mov")
            try await RenderExportEngine().export(project: project, from: folder, to: output, fromFirstClip: true)
            let movie = AVURLAsset(url: output)
            let duration = try await movie.load(.duration)
            XCTAssertEqual(duration.seconds, 0.8, accuracy: 0.02)
            if offset == 0 { XCTAssertGreaterThan(try pixel(movie, at: 0.1).red, 0.8) }
            if offset < 0 { XCTAssertGreaterThan(try pixel(movie, at: 0.1).blue, 0.8, "The correction changes frames inside the movie, not its placement note") }
            if offset > 0 { XCTAssertLessThan(try pixel(movie, at: 0.033).red, 0.1, "Positive offset adds leading blank time at the fixed anchor") }
            XCTAssertEqual(project.timeline.lanes[0].clips[0], clip)
        }
    }

    @MainActor
    func testLayeredExportShowsLowerVideoAndAnimatedForeground() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await makeMovie(at: folder.appendingPathComponent("red.mov"), red: true)
        try await makeMovie(at: folder.appendingPathComponent("blue.mov"), red: false)
        var project = CamOrderProject.empty(name: "Layers")
        project.exportSettings.canvasWidth = 64; project.exportSettings.canvasHeight = 64
        project.exportSettings.audioMode = .muteAll
        project.media = [MediaAsset(id: "red", kind: .video, displayName: "Top", relativePath: "red.mov"), MediaAsset(id: "blue", kind: .video, displayName: "Bottom", relativePath: "blue.mov")]
        var top = VideoClip(clipId: "top", mediaAssetId: "red", videoFile: "red.mov", armedLaneId: "top",
            logicStartTimecode: .from(seconds: 2, frameRate: .fps30), logicStartSeconds: 2, durationSeconds: 0.5, frameRate: .fps30)
        top.automationMarkers = [ClipAutomationMarker(timeSeconds: 0, framing: ClipFraming(zoom: 0.25, offsetX: -0.5)), ClipAutomationMarker(timeSeconds: 0.5, framing: ClipFraming(zoom: 0.25, offsetX: 0.5))]
        let bottom = VideoClip(clipId: "bottom", mediaAssetId: "blue", videoFile: "blue.mov", armedLaneId: "bottom",
            logicStartTimecode: .from(seconds: 2, frameRate: .fps30), logicStartSeconds: 2, durationSeconds: 1, frameRate: .fps30)
        project.timeline.lanes = [VideoLane(id: "top", name: "Top", clips: [top]), VideoLane(id: "bottom", name: "Bottom", clips: [bottom])]
        XCTAssertEqual(project.playbackClips(at: 2.1).map(\.id), [top.id, bottom.id])
        let output = folder.appendingPathComponent("layers.mov")
        try await RenderExportEngine().export(project: project, from: folder, to: output, fromFirstClip: true)
        let movie = AVURLAsset(url: output)
        XCTAssertGreaterThan(try pixel(movie, at: 0, x: 16).red, 0.8)
        XCTAssertGreaterThan(try pixel(movie, at: 0, x: 48).blue, 0.8, "A small foreground must reveal the lower lane")
        XCTAssertGreaterThan(try pixel(movie, at: 0.4, x: 45).red, 0.8, "Automation moves the foreground independently")
        XCTAssertGreaterThan(try pixel(movie, at: 0.4, x: 16).blue, 0.8)
        XCTAssertGreaterThan(try pixel(movie, at: 0.7, x: 45).blue, 0.8, "The lower layer continues after the upper clip ends")
        project.timeline.lanes[0].isMuted = true
        XCTAssertEqual(project.playbackClips(at: 2.1).map(\.id), [bottom.id])
        // A positive Y framing value is a downward drag in Main Stage. Export
        // must keep that direction and rotate around the moved image's center.
        project.timeline.lanes[0].isMuted = false
        project.timeline.lanes[0].clips[0].automationMarkers = []
        project.timeline.lanes[0].clips[0].framing = ClipFraming(zoom: 0.25, offsetX: -0.5, offsetY: 0.5, rotationDegrees: 45)
        let moved = folder.appendingPathComponent("moved-and-rotated.mov")
        try await RenderExportEngine().export(project: project, from: folder, to: moved, fromFirstClip: true)
        XCTAssertGreaterThan(try pixel(AVURLAsset(url: moved), at: 0.1, x: 16, y: 48).red, 0.8)
        XCTAssertGreaterThan(try pixel(AVURLAsset(url: moved), at: 0.1, x: 16, y: 16).blue, 0.8)
    }

    @MainActor
    func testNumberedForegroundOverridesUpperLaneInExport() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await makeMovie(at: folder.appendingPathComponent("red.mov"), red: true)
        try await makeMovie(at: folder.appendingPathComponent("blue.mov"), red: false)
        var project = CamOrderProject.empty(name: "Numbered layers")
        project.exportSettings.canvasWidth = 64; project.exportSettings.canvasHeight = 64
        project.exportSettings.audioMode = .muteAll
        let red = VideoClip(clipId: "upper", mediaAssetId: "r", videoFile: "red.mov", armedLaneId: "upper",
            logicStartTimecode: .from(seconds: 0, frameRate: .fps30), logicStartSeconds: 0, durationSeconds: 1, frameRate: .fps30,
            compositingLayer: 3)
        let blue = VideoClip(clipId: "lower", mediaAssetId: "b", videoFile: "blue.mov", armedLaneId: "lower",
            logicStartTimecode: .from(seconds: 0, frameRate: .fps30), logicStartSeconds: 0, durationSeconds: 1, frameRate: .fps30,
            framing: ClipFraming(zoom: 0.5), compositingLayer: 1)
        project.media = [MediaAsset(id: "r", kind: .video, displayName: "Red", relativePath: "red.mov"), MediaAsset(id: "b", kind: .video, displayName: "Blue", relativePath: "blue.mov")]
        project.timeline.lanes = [VideoLane(id: "upper", name: "Upper", clips: [red], videoOffsetMS: -10), VideoLane(id: "lower", name: "Lower", clips: [blue], videoOffsetMS: 20)]
        project.sync.videoOffsetMS = -5
        XCTAssertEqual(project.playbackClips(at: 0.2).map(\.id), [blue.id, red.id])
        let output = folder.appendingPathComponent("foreground.mov")
        try await RenderExportEngine().export(project: project, from: folder, to: output)
        let movie = AVURLAsset(url: output)
        XCTAssertGreaterThan(try pixel(movie, at: 0.2).blue, 0.8, "Numbered foreground beats physical lane order")
        XCTAssertGreaterThan(try pixel(movie, at: 0.2, x: 4).red, 0.8, "Background still shows around a smaller foreground")
    }

    @MainActor
    func testDifferentLaneOffsetsCombineWithMasterInLayeredExport() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await makeMovie(at: folder.appendingPathComponent("cue.mov"), red: true, changingAtFrame: 8)
        var project = CamOrderProject.empty(name: "Independent lane offsets")
        project.exportSettings.canvasWidth = 64; project.exportSettings.canvasHeight = 64
        project.exportSettings.audioMode = .muteAll
        project.sync.videoOffsetMS = -50
        project.media = [MediaAsset(id: "cue", kind: .video, displayName: "Cue", relativePath: "cue.mov")]
        var top = VideoClip(clipId: "top", mediaAssetId: "cue", videoFile: "cue.mov", armedLaneId: "top",
            logicStartTimecode: .from(seconds: 10, frameRate: .fps30), logicStartSeconds: 10,
            durationSeconds: 0.8, frameRate: .fps30, trimInSeconds: 0.1)
        top.framing = ClipFraming(zoom: 0.5, offsetX: -0.5)
        var bottom = top; bottom.id = UUID().uuidString; bottom.clipId = "bottom"; bottom.armedLaneId = "bottom"; bottom.framing = ClipFraming()
        project.timeline.lanes = [VideoLane(id: "top", name: "Delayed", clips: [top]), VideoLane(id: "bottom", name: "Advanced", clips: [bottom])]
        project.timeline.lanes[0].videoOffsetMS = 150 // Net +100 ms.
        project.timeline.lanes[1].videoOffsetMS = -50 // Net -100 ms.
        XCTAssertEqual(project.videoOffsetSeconds(forLane: "top"), 0.1, accuracy: 0.0001)
        XCTAssertEqual(project.videoOffsetSeconds(forLane: "bottom"), -0.1, accuracy: 0.0001)
        XCTAssertEqual(project.playbackClips(at: 10.2).map(\.timelineStartSeconds), [10.1, 9.9])
        XCTAssertEqual(RenderExportEngine.editedRange(in: project)?.startSeconds, 10)
        let output = folder.appendingPathComponent("independent-offsets.mov")
        try await RenderExportEngine().export(project: project, from: folder, to: output, fromFirstClip: true)
        let movie = AVURLAsset(url: output)
        XCTAssertGreaterThan(try pixel(movie, at: 0.2, x: 16).red, 0.8, "Top lane uses its +100 ms net delay")
        XCTAssertGreaterThan(try pixel(movie, at: 0.2, x: 48).blue, 0.8, "Bottom lane independently uses its -100 ms net advance")
        XCTAssertGreaterThan(try pixel(movie, at: 0.4, x: 16).blue, 0.8)
        XCTAssertGreaterThan(try pixel(movie, at: 0.75, x: 16).blue, 0.8)
        XCTAssertLessThan(try pixel(movie, at: 0.75, x: 48).blue, 0.1, "The earlier lower lane ends without ending the delayed upper lane")
        let duration = try await movie.load(.duration)
        XCTAssertEqual(duration.seconds, 0.8, accuracy: 0.02)
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

    private func pixel(_ asset: AVAsset, at seconds: Double, x: Int = 32, y: Int = 32) throws -> (red: Double, blue: Double) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let image = try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
        let bitmap = NSBitmapImageRep(cgImage: image)
        let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
        return (color.redComponent, color.blueComponent)
    }
    private func makeMovie(at url: URL, red: Bool, changingAtFrame: Int? = nil) async throws {
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
            let red = changingAtFrame.map { frame < $0 } ?? red
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
