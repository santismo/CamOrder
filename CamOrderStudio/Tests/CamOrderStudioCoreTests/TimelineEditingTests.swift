import XCTest
import AVFoundation
import AppKit
@testable import CamOrderStudioCore

final class TimelineEditingTests: XCTestCase {
    func testTrimmingPasteAtZeroWithPositivePresentationOffset() {
        var value = clip()
        value.timelineStartSeconds = -0.038
        let originalEnd = value.timelineStartSeconds + value.durationSeconds
        value.trimLeftEdge(to: -0.038, minimumTimelineStart: -0.038)
        XCTAssertEqual(value.timelineStartSeconds, -0.038, accuracy: 0.000001)
        XCTAssertEqual(value.trimInSeconds, 2)
        value.trimLeftEdge(to: 0.062, minimumTimelineStart: -0.038)
        XCTAssertEqual(value.trimInSeconds, 2.1, accuracy: 0.000001)
        XCTAssertEqual(value.timelineStartSeconds + value.durationSeconds, originalEnd, accuracy: 0.000001)
        value.trimLeftEdge(to: -1, minimumTimelineStart: -0.038)
        XCTAssertEqual(value.timelineStartSeconds, -0.038, accuracy: 0.000001)
        XCTAssertEqual(value.trimInSeconds, 2, accuracy: 0.000001)
    }
    private func clip(start: Double = 10, trim: Double = 2, duration: Double = 6) -> VideoClip {
        VideoClip(clipId: "take", mediaAssetId: "movie", videoFile: "source.mov", armedLaneId: "top",
                  logicStartTimecode: .from(seconds: start, frameRate: .fps30), logicStartSeconds: start,
                  durationSeconds: duration, frameRate: .fps30, trimInSeconds: trim, trimOutSeconds: 10)
    }

    func testTopLaneAndExactCutBoundaryRespectVisibility() throws {
        var top = clip()
        let (first, second) = try XCTUnwrap(top.split(at: 12))
        let lower = clip()
        var timeline = Timeline(lanes: [VideoLane(id: "top", name: "Top", clips: [first, second]), VideoLane(id: "bottom", name: "Bottom", clips: [lower])])
        XCTAssertEqual(timeline.visibleClip(at: 11)?.id, first.id)
        XCTAssertEqual(timeline.visibleClip(at: 12)?.id, second.id)
        timeline.lanes[0].isMuted = true
        XCTAssertEqual(timeline.visibleClip(at: 12)?.id, lower.id)
        timeline.lanes[0].isMuted = false
        top.isEnabled = false; timeline.lanes[0].clips = [top]
        XCTAssertEqual(timeline.visibleClip(at: 12)?.id, lower.id)
        XCTAssertNil(timeline.visibleClip(at: 16))
        XCTAssertNil(timeline.visibleClip(at: .nan))
    }

    func testSplitTrimAndExtensionPreserveSourceAndEasedAnimation() throws {
        var original = clip()
        original.automationMarkers = [ClipAutomationMarker(timeSeconds: 3, framing: ClipFraming(zoom: 3, offsetX: 1)), ClipAutomationMarker(timeSeconds: 6, framing: ClipFraming(zoom: 2, offsetY: 1))]
        var (first, second) = try XCTUnwrap(original.split(at: 12))
        XCTAssertEqual(first.trimInSeconds, 2)
        XCTAssertEqual(second.trimInSeconds, 4)
        XCTAssertEqual(first.sourceSeconds(at: 12), second.sourceSeconds(at: 12))
        for time in stride(from: 10.0, through: 16.0, by: 0.125) {
            let part = time < 12 ? first : second
            XCTAssertEqual(part.sourceSeconds(at: time), original.sourceSeconds(at: time), accuracy: 0.00001)
            XCTAssertEqual(part.automatedFraming(atTimelineSecond: time).zoom, original.automatedFraming(atTimelineSecond: time).zoom, accuracy: 0.00001)
        }
        second.trimLeftEdge(to: 13)
        XCTAssertEqual(second.trimInSeconds, 5)
        XCTAssertEqual(second.durationSeconds, 3)
        XCTAssertEqual(second.automatedFraming(atTimelineSecond: 13.5).zoom, original.automatedFraming(atTimelineSecond: 13.5).zoom, accuracy: 0.00001)
        second.trimLeftEdge(to: 12)
        XCTAssertEqual(second.trimInSeconds, 4)
        first.durationSeconds = 40; first.constrainDuration(toSourceDuration: 10)
        XCTAssertEqual(first.durationSeconds, 8)
        first.trimLeftEdge(to: 0)
        XCTAssertEqual(first.timelineStartSeconds, 8)
        XCTAssertEqual(first.trimInSeconds, 0)
        let reopened = try JSONDecoder().decode(VideoClip.self, from: JSONEncoder().encode(second))
        XCTAssertEqual(reopened, second)
    }

    func testReframingDoesNotSnapBackToAutomation() {
        var value = clip()
        value.automationMarkers = [ClipAutomationMarker(timeSeconds: 3, framing: ClipFraming(zoom: 2, offsetX: 1))]
        for zoom in stride(from: 1.5, through: 4, by: 0.125) {
            let reference = value.automatedFraming(atLocalSecond: 1.5)
            let target = ClipFraming(zoom: zoom, offsetX: 2, offsetY: -1)
            value.reframe(from: reference, to: target)
            let actual = value.automatedFraming(atLocalSecond: 1.5)
            XCTAssertEqual(actual.zoom, zoom, accuracy: 0.00001)
            XCTAssertEqual(actual.offsetX, 2, accuracy: 0.00001)
            XCTAssertEqual(actual.offsetY, -1, accuracy: 0.00001)
        }
    }

    @MainActor
    func testRealPlayerChasesAcrossSplitTrimAndRapidScrub() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("source.mov")
        try await makeMovie(at: url)
        let playback = TimelineVideoPlayer()
        playback.update(url: url, sourceSeconds: 2.5, isPlaying: false)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        playback.player.currentItem!.add(output)
        try await settle(playback, at: 2.5)
        let original = clip(trim: 2, duration: 3)
        let (first, second) = try XCTUnwrap(original.split(at: 11.2))
        let begin = ProcessInfo.processInfo.systemUptime
        var decodedFrames = 0
        var timingErrors: [Double] = []
        while ProcessInfo.processInfo.systemUptime - begin < 1.7 {
            let timelineTime = 10.5 + ProcessInfo.processInfo.systemUptime - begin
            let active = timelineTime < 11.2 ? first : second
            playback.update(url: url, sourceSeconds: active.sourceSeconds(at: timelineTime), isPlaying: true)
            if output.hasNewPixelBuffer(forItemTime: playback.player.currentTime()), output.copyPixelBuffer(forItemTime: playback.player.currentTime(), itemTimeForDisplay: nil) != nil { decodedFrames += 1 }
            if ProcessInfo.processInfo.systemUptime - begin > 0.3 {
                timingErrors.append(abs(playback.player.currentTime().seconds - active.sourceSeconds(at: timelineTime)))
            }
            try await Task.sleep(nanoseconds: 16_000_000)
        }
        let meanError = timingErrors.reduce(0, +) / Double(max(1, timingErrors.count))
        XCTAssertGreaterThan(decodedFrames, 35)
        XCTAssertLessThan(meanError, 0.04, "Seek/decode completion must not leave a persistent preview delay")
        print(String(format: "PLAYBACK: %d decoded frames in 1.7 seconds; mean clock error %.2f ms", decodedFrames, meanError * 1000))
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertGreaterThan(playback.player.currentTime().seconds, 4.0, "Decoded playback advances across a cut sharing the same media")
        XCTAssertEqual(playback.player.rate, 1)
        let buffer = try XCTUnwrap(output.copyPixelBuffer(forItemTime: playback.player.currentTime(), itemTimeForDisplay: nil))
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        XCTAssertGreaterThan(bytes[0], 200, "The rendered frame is from the blue end of the source, not a frozen green frame")
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        // Many requests before the decoder finishes: latest paused position must win.
        for position in [0.2, 3.2, 1.1, 5.1] { playback.update(url: url, sourceSeconds: position, isPlaying: false) }
        try await settle(playback, at: 5.1)
        XCTAssertEqual(playback.player.rate, 0)
        var trimmed = second; trimmed.trimLeftEdge(to: 11.8)
        playback.update(url: url, sourceSeconds: trimmed.sourceSeconds(at: 11.8), isPlaying: false)
        try await settle(playback, at: 3.8)
        // Same-position framing refreshes must not restart or move the movie.
        for _ in 0..<100 { playback.update(url: url, sourceSeconds: 3.8, isPlaying: false) }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(playback.player.currentTime().seconds, 3.8, accuracy: 0.02)
        // Export uses identical visibility/source mapping after split + trim.
        var project = CamOrderProject.empty(name: "Cuts")
        project.exportSettings.canvasWidth = 64; project.exportSettings.canvasHeight = 64
        project.exportSettings.audioMode = .muteAll
        project.media = [MediaAsset(id: "movie", kind: .video, displayName: "Source", relativePath: "source.mov", durationSeconds: 6)]
        var source = clip(start: 0, trim: 1, duration: 4)
        source.trimOutSeconds = 6
        var (left, right) = try XCTUnwrap(source.split(at: 2))
        left.durationSeconds = 1; right.trimLeftEdge(to: 2.5)
        project.timeline.lanes[0].clips = [left, right]
        let exported = folder.appendingPathComponent("edited.mov")
        let engine = RenderExportEngine()
        try await engine.export(project: project, from: folder, to: exported)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: exported))
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        func color(_ seconds: Double) throws -> NSColor {
            let image = try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
            return try XCTUnwrap(NSBitmapImageRep(cgImage: image).colorAt(x: 32, y: 32)?.usingColorSpace(.deviceRGB))
        }
        XCTAssertGreaterThan(try color(0.5).redComponent, 0.8)
        XCTAssertLessThan(try color(1.5).redComponent, 0.1)
        XCTAssertGreaterThan(try color(2.7).greenComponent, 0.8)
        XCTAssertGreaterThan(try color(3.5).blueComponent, 0.8)
        source.automationMarkers = [ClipAutomationMarker(timeSeconds: 1.275, framing: ClipFraming(zoom: 1.5)), ClipAutomationMarker(timeSeconds: 3.713, framing: ClipFraming(zoom: 2))]
        var (animatedLeft, animatedRight) = try XCTUnwrap(source.split(at: 2))
        animatedLeft.durationSeconds = 1; animatedRight.trimLeftEdge(to: 2.5)
        project.timeline.lanes[0].clips = [animatedLeft, animatedRight]
        try await engine.export(project: project, from: folder, to: folder.appendingPathComponent("animated.mov"))
    }

    @MainActor
    func testExportStartsAtEditedSourceAndKeepsMasterAudioAlignedWithOffsets() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await makeMovie(at: folder.appendingPathComponent("source.mov"))
        // A real PCM cue at original timeline second 5. It must remain at that
        // project time while project/lane sync offsets move only the video.
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000 * 8)!
        buffer.frameLength = buffer.frameCapacity
        let samples = buffer.floatChannelData![0]
        for frame in 0..<Int(buffer.frameLength) {
            samples[frame] = frame >= 5 * 48000 && frame < 5 * 48000 + 4800 ? Float(sin(Double(frame) * 2 * .pi * 440 / 48000) * 0.7) : 0
        }
        try autoreleasepool {
            let audio = try AVAudioFile(forWriting: folder.appendingPathComponent("master.wav"), settings: format.settings)
            try audio.write(from: buffer)
        }
        var project = CamOrderProject.empty(name: "Edited range")
        project.exportSettings.canvasWidth = 64; project.exportSettings.canvasHeight = 64
        project.exportSettings.audioMode = .masteredOnly
        project.audio.masteredAudioFile = "master.wav"
        project.media = [MediaAsset(id: "movie", kind: .video, displayName: "Source", relativePath: "source.mov", durationSeconds: 6)]
        var region = clip(start: 1, trim: 0, duration: 5)
        region.armedLaneId = project.timeline.lanes[0].id
        region.trimLeftEdge(to: 3.5) // Edited start 3.5; source starts at 2.5, green.
        project.timeline.lanes[0].clips = [region]
        project.sync.videoOffsetMS = -100
        project.timeline.lanes[0].videoOffsetMS = 50
        let range = try XCTUnwrap(RenderExportEngine.editedRange(in: project))
        XCTAssertEqual(range.startSeconds, 3.5, accuracy: 0.001)
        let output = folder.appendingPathComponent("edited.mov")
        let engine = RenderExportEngine()
        try await engine.export(project: project, from: folder, to: output, range: range)
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 2.5, accuracy: 0.04)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let image = try generator.copyCGImage(at: .zero, actualTime: nil)
        let color = try XCTUnwrap(NSBitmapImageRep(cgImage: image).colorAt(x: 32, y: 32)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(color.greenComponent, 0.8, "Export begins at the trimmed source frame, not the original red take start")
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(audioTracks.first)
        let reader = try AVAssetReader(asset: asset)
        let readOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
        reader.add(readOutput); XCTAssertTrue(reader.startReading())
        var firstAudible: Double?
        while let sample = readOutput.copyNextSampleBuffer() {
            guard let data = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0; var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(data, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr, let pointer else { continue }
            let pcm = UnsafeRawPointer(pointer).assumingMemoryBound(to: Float.self)
            for index in 0..<(length / MemoryLayout<Float>.size) where abs(pcm[index]) > 0.1 {
                firstAudible = CMSampleBufferGetPresentationTimeStamp(sample).seconds + Double(index) / 48000
                break
            }
            if firstAudible != nil { break }
        }
        reader.cancelReading()
        XCTAssertEqual(try XCTUnwrap(firstAudible), 5 - range.startSeconds, accuracy: 0.04, "Master audio stays on the project clock after the export start is removed")
        let custom = try XCTUnwrap(MovieExportRange(startSeconds: 4.95, endSeconds: 5.45))
        let customURL = folder.appendingPathComponent("range.mov")
        try await engine.export(project: project, from: folder, to: customURL, range: custom)
        let customAsset = AVURLAsset(url: customURL)
        let customDuration = try await customAsset.load(.duration)
        XCTAssertEqual(customDuration.seconds, 0.5, accuracy: 0.04)
        let customImage = try AVAssetImageGenerator(asset: customAsset).copyCGImage(at: .zero, actualTime: nil)
        XCTAssertGreaterThan(try XCTUnwrap(NSBitmapImageRep(cgImage: customImage).colorAt(x: 32, y: 32)?.usingColorSpace(.deviceRGB)).blueComponent, 0.8)
    }

    @MainActor private func settle(_ playback: TimelineVideoPlayer, at seconds: Double) async throws {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if playback.player.currentItem?.status == .readyToPlay && abs(playback.player.currentTime().seconds - seconds) < 0.02 { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Player never reached \(seconds); actual \(playback.player.currentTime().seconds), error \(String(describing: playback.player.currentItem?.error))")
    }

    private func makeMovie(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for frame in 0..<180 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixel = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            let bytes = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixel)
            for y in 0..<64 { for x in 0..<64 {
                bytes[y * stride + x * 4] = frame >= 120 ? 255 : 0
                bytes[y * stride + x * 4 + 1] = frame >= 60 && frame < 120 ? 255 : 0
                bytes[y * stride + x * 4 + 2] = frame < 60 ? 255 : 0
                bytes[y * stride + x * 4 + 3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            XCTAssertTrue(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished(); await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }
}
