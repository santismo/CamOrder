import Foundation
import Darwin
import CoreImage
import AppKit

/// A latest-frame mailbox shared only by this AU instance and its capture helper.
/// No JPEG compression, filesystem polling, or work on the recording queue.
final class SharedPreview: @unchecked Sendable {
    static let maxWidth = 960
    static let maxHeight = 640
    private static let headerBytes = 64
    private static let size = headerBytes + maxWidth * maxHeight * 4
    private let fd: Int32
    private let memory: UnsafeMutableRawPointer
    private let writable: Bool
    private var sequence: UInt64 = 0
    init(url: URL, writable: Bool) throws {
        self.writable = writable
        fd = Darwin.open(url.path, writable ? (O_RDWR | O_CREAT) : O_RDONLY, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(.ENOENT) }
        if writable && ftruncate(fd, off_t(Self.size)) != 0 { Darwin.close(fd); throw POSIXError(.EIO) }
        var statValue = stat()
        guard fstat(fd, &statValue) == 0, statValue.st_size == Self.size else { Darwin.close(fd); throw POSIXError(.EINVAL) }
        let mapped = mmap(nil, Self.size, writable ? (PROT_READ | PROT_WRITE) : PROT_READ, MAP_SHARED, fd, 0)
        guard mapped != MAP_FAILED, let mapped else { Darwin.close(fd); throw POSIXError(.ENOMEM) }
        memory = mapped
    }
    deinit { munmap(memory, Self.size); Darwin.close(fd) }
    func publish(_ pixel: CVPixelBuffer, context: CIContext) {
        guard writable, flock(fd, LOCK_EX | LOCK_NB) == 0 else { return }
        defer { flock(fd, LOCK_UN) }
        let source = CIImage(cvPixelBuffer: pixel)
        let scale = min(1, CGFloat(Self.maxWidth) / source.extent.width, CGFloat(Self.maxHeight) / source.extent.height)
        let width = Int(source.extent.width * scale), height = Int(source.extent.height * scale)
        guard width > 0, height > 0 else { return }
        let image = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        context.render(image, toBitmap: memory.advanced(by: Self.headerBytes), rowBytes: width * 4,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .BGRA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        sequence &+= 1
        memory.storeBytes(of: sequence, as: UInt64.self)
        memory.storeBytes(of: UInt32(width), toByteOffset: 8, as: UInt32.self)
        memory.storeBytes(of: UInt32(height), toByteOffset: 12, as: UInt32.self)
    }
    func copyNewFrame(after previous: inout UInt64) -> CGImage? {
        guard flock(fd, LOCK_SH | LOCK_NB) == 0 else { return nil }
        let current = memory.load(as: UInt64.self)
        let width = Int(memory.load(fromByteOffset: 8, as: UInt32.self))
        let height = Int(memory.load(fromByteOffset: 12, as: UInt32.self))
        guard current != 0, current != previous, width > 0, width <= Self.maxWidth, height > 0, height <= Self.maxHeight else {
            flock(fd, LOCK_UN); return nil
        }
        let data = Data(bytes: memory.advanced(by: Self.headerBytes), count: width * height * 4)
        previous = current
        flock(fd, LOCK_UN)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

final class PreviewPublisher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.santismo.CamOrder.preview", qos: .userInitiated)
    private let gate = DispatchSemaphore(value: 1)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let shared: SharedPreview
    private var lastTimestamp = -Double.infinity // capture queue only
    init(url: URL) throws { shared = try SharedPreview(url: url, writable: true) }
    func offer(_ pixel: CVPixelBuffer, timestamp: Double) {
        guard timestamp.isFinite else { return }
        // A newly selected device can use a different timestamp origin.
        if timestamp < lastTimestamp { lastTimestamp = -Double.infinity }
        // Admit 30-fps sources without rounding a 33.333-ms interval down to 15 fps.
        guard timestamp - lastTimestamp >= 1.0 / 35.0, gate.wait(timeout: .now()) == .success else { return }
        lastTimestamp = timestamp
        queue.async { [self] in
            shared.publish(pixel, context: context)
            gate.signal()
        }
    }
}

@MainActor
public final class CapturePreviewFrames: ObservableObject {
    @Published public private(set) var image: CGImage?
    func display(_ image: CGImage) { self.image = image }
    func clear() { image = nil }
}
