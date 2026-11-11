import Foundation
import CamOrderStudioCore

protocol PlaybackPreviewPreparing: Sendable {
    func cachedURL(for source: URL, quality: PreviewQuality) async -> URL?
    func prepare(_ source: URL, quality: PreviewQuality) async throws -> URL
}
extension PreviewProxyCache: PlaybackPreviewPreparing {}

@MainActor
final class PlaybackPreviewController: ObservableObject {
    struct Request: Hashable {
        var sources: [URL]
        var quality: PreviewQuality
    }
    @Published private(set) var urls: [URL: URL] = [:]
    @Published private(set) var isPreparing = false
    @Published private(set) var isCheckingCache = false
    @Published private(set) var message = ""
    private let cache: any PlaybackPreviewPreparing
    private let idleDelay: UInt64
    private var request = Request(sources: [], quality: .full)
    private var task: Task<Void, Never>?
    private var retiringTask: Task<Void, Never>?
    private var lookupTask: Task<Void, Never>?
    private var scheduled: Task<Void, Never>?
    private var revision = 0
    private var configurationRevision = 0
    private var isIdle = false
    private var paused = false
    private var failed = Set<URL>()

    init(cache: any PlaybackPreviewPreparing = PreviewProxyCache(), idleDelay: UInt64 = 1_000_000_000) {
        self.cache = cache; self.idleDelay = idleDelay
    }
    deinit { task?.cancel(); retiringTask?.cancel(); lookupTask?.cancel(); scheduled?.cancel() }

    /// Gate changes are synchronous: playback/arming must cancel even while
    /// asynchronous cache discovery or an export completion is in flight.
    func update(_ next: Request, isIdle: Bool) {
        let becameBusy = self.isIdle && !isIdle
        self.isIdle = isIdle
        if becameBusy { paused = false; cancelWork() }
        if request != next {
            let sameQuality = request.quality == next.quality
            cancelWork(); lookupTask?.cancel()
            configurationRevision += 1
            request = next
            let sources = Set(next.sources)
            urls = sameQuality ? urls.filter { sources.contains($0.key) } : [:]
            failed = sameQuality ? failed.intersection(sources) : []
            if !sameQuality { paused = false }
            isCheckingCache = next.quality != .full && !next.sources.isEmpty
            guard isCheckingCache else { lookupTask = nil; refreshMessage(); return }
            let expected = configurationRevision, cache = cache
            let missing = next.sources.filter { urls[$0] == nil }
            lookupTask = Task { [weak self] in
                for source in missing {
                    let url = await cache.cachedURL(for: source, quality: next.quality)
                    guard !Task.isCancelled, let self, self.configurationRevision == expected else { return }
                    if let url { self.urls[source] = url; self.failed.remove(source) }
                }
                guard let self, !Task.isCancelled, self.configurationRevision == expected else { return }
                self.lookupTask = nil; self.isCheckingCache = false
                self.scheduleAutomatic()
            }
        }
        scheduleAutomatic()
    }

    /// Manual override: prepare immediately or retry files that failed once.
    func prepare() {
        guard isIdle, !isCheckingCache, !isPreparing, request.quality != .full else { return }
        paused = false; failed.removeAll()
        scheduled?.cancel(); scheduled = nil
        start()
    }

    /// Pause for this idle period. A transport/arm/view cycle resumes automatic work.
    func stop() {
        paused = true
        cancelWork()
        refreshMessage()
    }

    private var pending: [URL] { request.sources.filter { urls[$0] == nil && !failed.contains($0) } }

    private func cancelWork() {
        revision += 1
        scheduled?.cancel(); scheduled = nil
        if let task { task.cancel(); retiringTask = task; self.task = nil }
        isPreparing = false
    }

    private func scheduleAutomatic() {
        refreshMessage()
        guard isIdle, !paused, !isCheckingCache, !isPreparing,
              request.quality != .full, !pending.isEmpty, scheduled == nil else { return }
        let expected = revision, delay = idleDelay
        scheduled = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self, !Task.isCancelled, self.revision == expected else { return }
            self.scheduled = nil
            self.start()
        }
    }

    private func start() {
        guard isIdle, !paused, !isCheckingCache, !isPreparing, request.quality != .full else { return }
        let sources = pending
        guard !sources.isEmpty else { refreshMessage(); return }
        revision += 1
        let expected = revision, quality = request.quality, cache = cache
        let previous = retiringTask
        retiringTask = nil
        isPreparing = true
        message = "Auto · preparing playback…"
        task = Task { [weak self] in
            // A cancelled exporter may still be cleaning up. Never overlap it
            // with a replacement job, including rapid stop/start/quality changes.
            await previous?.value
            for source in sources {
                guard !Task.isCancelled, self?.revision == expected else { return }
                do {
                    let url = try await cache.prepare(source, quality: quality)
                    guard !Task.isCancelled, let self, self.revision == expected else { return }
                    self.urls[source] = url
                    self.message = "Auto · prepared \(self.urls.count)/\(self.request.sources.count)"
                } catch {
                    guard !Task.isCancelled, let self, self.revision == expected else { return }
                    self.failed.insert(source)
                }
            }
            guard let self, self.revision == expected else { return }
            self.isPreparing = false; self.task = nil
            self.refreshMessage()
        }
    }

    private func refreshMessage() {
        guard !isPreparing else { return }
        if request.quality == .full { message = "" }
        else if paused { message = "Auto paused · click Prepare now to resume" }
        else if isCheckingCache { message = "Auto · checking ready previews…" }
        else if !isIdle && !pending.isEmpty { message = "Auto · waiting for stopped, disarmed lanes" }
        else if !failed.isEmpty { message = "\(failed.count) preview(s) unavailable · Prepare now to retry" }
        else if !pending.isEmpty { message = "Auto · preparing when idle" }
        else { message = "Auto · playback \(urls.count)/\(request.sources.count) ready" }
    }
}
