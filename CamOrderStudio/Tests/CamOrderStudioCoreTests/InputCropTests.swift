import XCTest
@preconcurrency import AVFoundation
@testable import CamOrderStudioCore

final class InputCropTests: XCTestCase {
    func testCropGeometryAndOldProjectCompatibility() throws {
        let crop = InputCrop(x: 0.101, y: 0.203, width: 0.507, height: 0.611)
        let rect = try XCTUnwrap(crop.pixelRect(width: 1920, height: 1080))
        XCTAssertGreaterThanOrEqual(rect.minX / 1920, crop.x)
        XCTAssertGreaterThanOrEqual(rect.minY / 1080, crop.y)
        XCTAssertLessThanOrEqual(rect.maxX / 1920, crop.x + crop.width)
        XCTAssertLessThanOrEqual(rect.maxY / 1080, crop.y + crop.height)
        XCTAssertEqual(Int(rect.width) % 2, 0); XCTAssertEqual(Int(rect.height) % 2, 0)
        XCTAssertNil(InputCrop(x: .nan, y: 0, width: 1, height: 1).rect)
        XCTAssertNil(InputCrop(x: 0, y: 0, width: 0.001, height: 0.001).pixelRect(width: 320, height: 240))
        var project = CamOrderProject.empty()
        let old = try JSONDecoder().decode(CamOrderProject.self, from: JSONEncoder().encode(project))
        XCTAssertNil(old.inputCrops)
        project.inputCrops = ["ipad": crop, "iphone": InputCrop(x: 0, y: 0.1, width: 1, height: 0.8)]
        project.timeline.lanes[0].captureCrop = [10, 20, 800, 600]
        let restored = try JSONDecoder().decode(CamOrderProject.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(restored, project)
        XCTAssertEqual(restored.timeline.lanes[0].captureCrop, [10, 20, 800, 600], "Screen region coordinates are separate")
    }

    func testCropCopiesExactTopLeftPixelsAndKeepsOriginalTiming() throws {
        let source = try sample(seconds: 42)
        let result = try XCTUnwrap(RecordingCropper().crop(source, to: InputCrop(x: 0.125, y: 0.25, width: 0.5, height: 0.5)))
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(result), CMSampleBufferGetPresentationTimeStamp(source))
        XCTAssertEqual(CMSampleBufferGetDuration(result), CMSampleBufferGetDuration(source))
        let pixel = try XCTUnwrap(CMSampleBufferGetImageBuffer(result))
        XCTAssertEqual(CVPixelBufferGetWidth(pixel), 160); XCTAssertEqual(CVPixelBufferGetHeight(pixel), 120)
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixel)).assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(base[0], 40); XCTAssertEqual(base[1], 60); XCTAssertEqual(base[2], 32)
        let last = 119 * CVPixelBufferGetBytesPerRow(pixel) + 159 * 4
        XCTAssertEqual(base[last], 199); XCTAssertEqual(base[last + 1], 179)
    }

    func testBusyCropPoolDropsOnlyTheFrameAndRecovers() throws {
        let cropper = RecordingCropper(), source = try sample(seconds: 100), crop = InputCrop(x: 0, y: 0, width: 0.5, height: 0.5)
        var held: [CMSampleBuffer] = []
        for _ in 0..<8 { held.append(try XCTUnwrap(cropper.crop(source, to: crop))) }
        XCTAssertNil(try cropper.crop(source, to: crop), "A busy pool must neither grow without bound nor stop the take")
        held.removeAll()
        XCTAssertNotNil(try cropper.crop(source, to: crop))
    }

    func testThreeInputsEncodeIndependentCropsWithLightPreviewAndReset() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let crops: [InputCrop?] = [InputCrop(x: 0.125, y: 0.25, width: 0.5, height: 0.5), InputCrop(x: 0.5, y: 0, width: 0.5, height: 0.25), nil]
        let sizes = [CGSize(width: 160, height: 120), CGSize(width: 160, height: 60), CGSize(width: 320, height: 240)]
        let writers = (0..<3).map { _ in CaptureWriter() }
        var finishes: [XCTestExpectation] = []
        for i in writers.indices {
            let writer = writers[i], done = expectation(description: "camera \(i) finalized")
            finishes.append(done)
            writer.onStarted = { XCTAssertEqual($0, 1000, accuracy: 0.00001) }
            writer.onFinished = { _, duration, error in XCTAssertNil(error); XCTAssertEqual(duration, 1, accuracy: 0.05); done.fulfill() }
            writer.previewPublisher = try PreviewPublisher(url: folder.appendingPathComponent("\(i).frames"))
            writer.previewPublisher?.quality = .light
            writer.queue.async { writer.setInputCrop(crops[i]); writer.begin(url: folder.appendingPathComponent("\(i).mov")) }
        }
        for frame in 0..<30 {
            let sample = try sample(seconds: 1000 + Double(frame) / 30)
            for writer in writers {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    writer.queue.async {
                        if frame == 10 { writer.setInputCrop(nil) } // Cannot alter an active take.
                        writer.captureOutput(AVCaptureVideoDataOutput(), didOutput: sample, from: AVCaptureConnection(inputPorts: [], output: AVCaptureVideoDataOutput()))
                        continuation.resume()
                    }
                }
            }
            try await Task.sleep(nanoseconds: 34_000_000)
        }
        for writer in writers { writer.queue.async { writer.finish() } }
        await fulfillment(of: finishes, timeout: 10)
        let referenceAsset = AVURLAsset(url: folder.appendingPathComponent("2.mov"))
        let (referenceImage, _) = try await AVAssetImageGenerator(asset: referenceAsset).image(at: CMTime(seconds: 0.5, preferredTimescale: 600))
        let reference = try rgba(referenceImage)
        for i in writers.indices {
            let asset = AVURLAsset(url: folder.appendingPathComponent("\(i).mov"))
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let size = try await XCTUnwrap(tracks.first).load(.naturalSize)
            XCTAssertEqual(size, sizes[i])
            let (image, _) = try await AVAssetImageGenerator(asset: asset).image(at: CMTime(seconds: 0.5, preferredTimescale: 600))
            XCTAssertEqual(image.width, Int(sizes[i].width)); XCTAssertEqual(image.height, Int(sizes[i].height))
            // Decoded pixels prove borders were removed from the movie itself,
            // not only hidden by a preview or an export transform.
            let data = try rgba(image)
            let origin = crops[i]?.pixelRect(width: 320, height: 240)?.origin ?? .zero
            for (x, y) in [(10, 10), (image.width / 2, image.height / 2), (image.width - 11, image.height - 11)] {
                let actual = (y * image.width + x) * 4
                let expected = ((Int(origin.y) + y) * 320 + Int(origin.x) + x) * 4
                for channel in 0..<3 {
                    XCTAssertEqual(Double(data[actual + channel]), Double(reference[expected + channel]), accuracy: 8,
                                   "Input \(i), point \(x),\(y), channel \(channel) must match the same source pixel")
                }
            }
            var sequence: UInt64 = 0
            let raw = try XCTUnwrap(SharedPreview(url: folder.appendingPathComponent("\(i).frames"), writable: false).copyNewFrame(after: &sequence))
            XCTAssertEqual(raw.width, 320); XCTAssertEqual(raw.height, 240, "Editor retains the full source feed")
            let preview = try rgba(raw)
            XCTAssertLessThan(preview[(10 * 320 + 10) * 4 + 1], 40, "Preview and recorded crop use the same top edge")
            XCTAssertGreaterThan(preview[(230 * 320 + 10) * 4 + 1], 200)
        }
        let writer = writers[0], reset = expectation(description: "reset finalized")
        writer.onStarted = nil
        writer.onFinished = { _, _, error in XCTAssertNil(error); reset.fulfill() }
        let next = try sample(seconds: 2000)
        writer.queue.async {
            writer.setInputCrop(nil); writer.begin(url: folder.appendingPathComponent("reset.mov"))
            writer.captureOutput(AVCaptureVideoDataOutput(), didOutput: next, from: AVCaptureConnection(inputPorts: [], output: AVCaptureVideoDataOutput()))
            writer.finish()
        }
        await fulfillment(of: [reset], timeout: 10)
        let tracks = try await AVURLAsset(url: folder.appendingPathComponent("reset.mov")).loadTracks(withMediaType: .video)
        let size = try await XCTUnwrap(tracks.first).load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 320, height: 240))
    }

    func testStaticWindowUsesTheSameRecordingCrop() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = CaptureWriter(), token = UUID(), ready = expectation(description: "window frame"), done = expectation(description: "window crop finalized")
        let frame = try sample(seconds: 100)
        writer.onStarted = { _ in ready.fulfill() }
        writer.onFinished = { _, duration, error in XCTAssertNil(error); XCTAssertGreaterThan(duration, 0.2); done.fulfill() }
        writer.queue.async {
            writer.setInputCrop(InputCrop(x: 0.25, y: 0, width: 0.5, height: 0.5))
            writer.beginWindowStream(token: token); _ = writer.receiveWindowFrame(frame, token: token)
            writer.begin(url: url)
        }
        await fulfillment(of: [ready], timeout: 10)
        try await Task.sleep(nanoseconds: 300_000_000)
        writer.queue.async { writer.finish(); writer.endWindowStream(token: token) }
        await fulfillment(of: [done], timeout: 10)
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        let size = try await XCTUnwrap(tracks.first).load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 160, height: 120))
    }

    func testThreeHDInputsSustainCroppedRecording() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = try sample(seconds: 2000, width: 1920, height: 1080)
        let writers = (0..<3).map { _ in CaptureWriter() }
        var completions: [XCTestExpectation] = []
        for (index, writer) in writers.enumerated() {
            let done = expectation(description: "HD input \(index)"); completions.append(done)
            writer.onFinished = { _, duration, error in XCTAssertNil(error); XCTAssertEqual(duration, 3, accuracy: 0.05); done.fulfill() }
            writer.previewPublisher = try PreviewPublisher(url: folder.appendingPathComponent("\(index).frames"))
            writer.previewPublisher?.quality = .light
            writer.queue.async {
                writer.setInputCrop(InputCrop(x: 0.125, y: 0.125, width: 0.75, height: 0.75))
                writer.begin(url: folder.appendingPathComponent("\(index).mov"))
            }
        }
        let start = ProcessInfo.processInfo.systemUptime
        for frame in 0..<90 {
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(seconds: 2000 + Double(frame) / 30, preferredTimescale: 600), decodeTimeStamp: .invalid)
            var timed: CMSampleBuffer?
            CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: original, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &timed)
            let sample = try XCTUnwrap(timed)
            for writer in writers {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    writer.queue.async {
                        writer.captureOutput(AVCaptureVideoDataOutput(), didOutput: sample, from: AVCaptureConnection(inputPorts: [], output: AVCaptureVideoDataOutput()))
                        continuation.resume()
                    }
                }
            }
            let remaining = Double(frame + 1) / 30 - (ProcessInfo.processInfo.systemUptime - start)
            if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1e9)) }
        }
        for writer in writers { writer.queue.async { writer.finish() } }
        await fulfillment(of: completions, timeout: 10)
        for index in writers.indices {
            let tracks = try await AVURLAsset(url: folder.appendingPathComponent("\(index).mov")).loadTracks(withMediaType: .video)
            let size = try await XCTUnwrap(tracks.first).load(.naturalSize)
            XCTAssertEqual(size, CGSize(width: 1440, height: 810))
        }
        print("CROPPED CAPTURE: three 1920×1080 inputs, 270 frames, Light previews, no recording warnings")
    }

    private func sample(seconds: Double, width: Int = 320, height: Int = 240) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixel)
        let buffer = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(buffer, [])
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        for y in 0..<height { for x in 0..<width {
            let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
            bytes[offset] = UInt8(x % 256); bytes[offset + 1] = UInt8(y % 256); bytes[offset + 2] = 32; bytes[offset + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample)
        return try XCTUnwrap(sample)
    }
    private func rgba(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { memory in
            let context = try XCTUnwrap(CGContext(data: memory.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
}
