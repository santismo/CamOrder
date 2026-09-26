import XCTest
@preconcurrency import AVFoundation
@testable import CamOrderStudioCore

final class SharedPreviewTests: XCTestCase {
    func testPreviewContinuesWhenNewDeviceResetsItsTimestamp() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let publisher = try PreviewPublisher(url: url)
        let reader = try SharedPreview(url: url, writable: false)
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixel)
        var sequence: UInt64 = 0
        func streamUntilFrame(origin: Double) -> CGImage? {
            let deadline = Date().addingTimeInterval(2)
            var frame = 0
            while Date() < deadline {
                // The mailbox intentionally drops a frame if the reader holds its
                // lock. Exercise a stream, not a guaranteed single-frame delivery.
                publisher.offer(buffer, timestamp: origin + Double(frame) / 30)
                frame += 1
                Thread.sleep(forTimeInterval: 1.0 / 30)
                if let image = reader.copyNewFrame(after: &sequence) { return image }
            }
            return nil
        }
        XCTAssertNotNil(streamUntilFrame(origin: 10_000))
        let firstSequence = sequence
        XCTAssertNotNil(streamUntilFrame(origin: 0))
        XCTAssertGreaterThan(sequence, firstSequence)
    }
    func testSharedFramesPreservePixelsAndSkipUnchangedFrames() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try SharedPreview(url: url, writable: true)
        let reader = try SharedPreview(url: url, writable: false)
        let context = CIContext()
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(buffer, [])
        let ptr = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<64 { for x in 0..<64 {
            let index = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
            ptr[index] = 0; ptr[index + 1] = 0; ptr[index + 2] = 255; ptr[index + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var sequence: UInt64 = 0
        writer.publish(buffer, context: context)
        let image = try XCTUnwrap(reader.copyNewFrame(after: &sequence))
        XCTAssertEqual(image.width, 64)
        let color = try XCTUnwrap(NSBitmapImageRep(cgImage: image).colorAt(x: 32, y: 32)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(color.redComponent, 0.95)
        XCTAssertLessThan(color.blueComponent, 0.05)
        XCTAssertNil(reader.copyNewFrame(after: &sequence))
        writer.publish(buffer, context: context)
        XCTAssertNotNil(reader.copyNewFrame(after: &sequence))
        XCTAssertEqual(sequence, 2)
    }
}
