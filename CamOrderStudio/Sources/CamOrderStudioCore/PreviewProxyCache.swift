@preconcurrency import AVFoundation
import CryptoKit

/// Disposable, video-only playback copies; project media paths never refer here.
public struct PreviewProxyCache: Sendable {
    public let folder: URL
    public init(folder: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.santismo.CamOrderStudio/Preview-v1", isDirectory: true)) { self.folder = folder }

    private func destination(for source: URL, quality: PreviewQuality) throws -> URL {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let signature = "\(source.standardizedFileURL.path)|\(attributes[.size] ?? 0)|\(modified)|\(quality.rawValue)"
        let key = SHA256.hash(data: Data(signature.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(key + ".mov")
    }

    public func cachedURL(for source: URL, quality: PreviewQuality) async -> URL? {
        guard quality != .full, let destination = try? destination(for: source, quality: quality),
              FileManager.default.fileExists(atPath: destination.path),
              (try? await AVURLAsset(url: destination).load(.isPlayable)) == true else { return nil }
        return destination
    }

    public func prepare(_ source: URL, quality: PreviewQuality) async throws -> URL {
        guard quality != .full else { return source }
        if let existing = await cachedURL(for: source, quality: quality) { return existing }
        try Task.checkCancellation()
        let destination = try destination(for: source, quality: quality)
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ProxyError("No video track") }
        let duration = try await asset.load(.duration)
        let size = try await track.load(.naturalSize)
        let limit = quality == .balanced ? CGSize(width: 1280, height: 720) : CGSize(width: 640, height: 480)
        // Smaller sources need no extra generation or re-encoding.
        if abs(size.width) <= limit.width && abs(size.height) <= limit.height { return source }
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ProxyError("Could not prepare a video track")
        }
        let range = try await track.load(.timeRange)
        try video.insertTimeRange(range, of: track, at: range.start)
        video.preferredTransform = try await track.load(.preferredTransform)
        if CMTimeCompare(composition.duration, duration) < 0 {
            composition.insertEmptyTimeRange(CMTimeRange(start: composition.duration, duration: duration - composition.duration))
        }
        let preset = quality == .balanced ? AVAssetExportPreset1280x720 : AVAssetExportPreset640x480
        guard let export = AVAssetExportSession(asset: composition, presetName: preset) else { throw ProxyError("Preview conversion unavailable") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent(UUID().uuidString + ".partial.mov")
        defer { try? FileManager.default.removeItem(at: temporary) }
        export.outputURL = temporary
        export.outputFileType = .mov
        export.shouldOptimizeForNetworkUse = false
        export.canPerformMultiplePassesOverSourceMediaData = false
        let operation = PreviewExportOperation(export)
        await withTaskCancellationHandler {
            await operation.run()
        } onCancel: { operation.cancel() }
        try Task.checkCancellation()
        guard export.status == .completed else { throw export.error ?? ProxyError("Preview conversion failed") }
        let rendered = AVURLAsset(url: temporary)
        let proxyDuration = try await rendered.load(.duration)
        guard abs(proxyDuration.seconds - duration.seconds) < 0.05 else { throw ProxyError("Preview duration did not match the original") }
        // The source may have been replaced while conversion was in progress.
        guard try destination == self.destination(for: source, quality: quality) else { throw ProxyError("Source changed while preparing") }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) {
            if await cachedURL(for: source, quality: quality) != nil { return destination }
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}

/// Serialize start and cancellation so an early Stop cannot cancel an idle
/// exporter only for it to start encoding immediately afterwards.
private final class PreviewExportOperation: @unchecked Sendable {
    private let lock = NSLock()
    private let export: AVAssetExportSession
    private var cancelled = false
    init(_ export: AVAssetExportSession) { self.export = export }
    func run() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard !cancelled else { lock.unlock(); continuation.resume(); return }
            export.exportAsynchronously { continuation.resume() }
            lock.unlock()
        }
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        export.cancelExport()
    }
}

private struct ProxyError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
