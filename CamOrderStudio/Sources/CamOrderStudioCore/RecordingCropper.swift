import Foundation
@preconcurrency import AVFoundation

/// Capture-queue only. Reuses a bounded pixel pool and copies only the selected
/// BGRA rows, with no scaling, image conversion, or work on the audio thread.
final class RecordingCropper {
    private var pool: CVPixelBufferPool?
    private var size = CGSize.zero
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
    func crop(_ sample: CMSampleBuffer, to crop: InputCrop) throws -> CMSampleBuffer? {
        guard let source = CMSampleBufferGetImageBuffer(sample),
              CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA,
              let rect = crop.pixelRect(width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source)) else {
            throw Failure("The input crop is too small or the camera format changed. Stop and adjust the crop before recording again.")
        }
        if pool == nil || size != rect.size {
            pool = nil
            let attributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: Int(rect.width),
                kCVPixelBufferHeightKey as String: Int(rect.height),
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else {
                throw Failure("Cannot allocate cropped recording buffers.")
            }
            size = rect.size
        }
        var cropped: CVPixelBuffer?
        let limits = [kCVPixelBufferPoolAllocationThresholdKey as String: 8] as CFDictionary
        guard let pool else { throw Failure("Cannot allocate cropped recording buffers.") }
        let allocation = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limits, &cropped)
        // Backpressure drops this frame, like a busy writer, without ending the
        // take or ever falling back to recording uncropped borders.
        if allocation == kCVReturnWouldExceedAllocationThreshold { return nil }
        guard allocation == kCVReturnSuccess, let cropped else { throw Failure("Cannot allocate cropped recording buffers.") }
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { throw Failure("Cannot read camera frame.") }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(cropped, []) == kCVReturnSuccess else { throw Failure("Cannot write cropped frame.") }
        defer { CVPixelBufferUnlockBaseAddress(cropped, []) }
        guard let src = CVPixelBufferGetBaseAddress(source), let dst = CVPixelBufferGetBaseAddress(cropped) else {
            throw Failure("Cannot access camera pixels.")
        }
        let srcStride = CVPixelBufferGetBytesPerRow(source), dstStride = CVPixelBufferGetBytesPerRow(cropped)
        for row in 0..<Int(rect.height) {
            memcpy(dst.advanced(by: row * dstStride),
                   src.advanced(by: (Int(rect.minY) + row) * srcStride + Int(rect.minX) * 4), Int(rect.width) * 4)
        }
        // Retain color interpretation without copying the original clean aperture.
        for key in [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey, kCVImageBufferCGColorSpaceKey] {
            if let value = CVBufferCopyAttachment(source, key, nil) { CVBufferSetAttachment(cropped, key, value, .shouldPropagate) }
        }
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: cropped, formatDescriptionOut: &format) == noErr,
              let format else { throw Failure("Cannot describe cropped video.") }
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sample), presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample), decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(sample))
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: cropped, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &result) == noErr,
              let result else { throw Failure("Cannot prepare cropped video.") }
        return result
    }
}
