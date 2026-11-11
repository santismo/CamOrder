import Foundation
import CamOrderStudioCore

@MainActor
final class PlaybackPreviewController: ObservableObject {
    struct Request: Hashable {
        var sources: [URL]
        var quality: PreviewQuality
    }
    @Published private(set) var urls: [URL: URL] = [:]
    @Published private(set) var isPreparing = false
    @Published private(set) var message = ""
    private let cache: PreviewProxyCache
    private var request = Request(sources: [], quality: .full)
    private var task: Task<Void, Never>?
    private var revision = 0
    private var configurationRevision = 0
    init(cache: PreviewProxyCache = PreviewProxyCache()) { self.cache = cache }
    deinit { task?.cancel() }

    func configure(_ request: Request) async {
        guard self.request != request else { return }
        stop()
        self.request = request
        configurationRevision += 1
        urls = [:]; message = ""
        let expected = configurationRevision
        guard request.quality != .full else { return }
        for source in request.sources {
            let url = await cache.cachedURL(for: source, quality: request.quality)
            guard !Task.isCancelled, expected == configurationRevision else { return }
            if let url { urls[source] = url }
        }
    }

    func prepare() {
        guard !isPreparing, request.quality != .full, !request.sources.isEmpty else { return }
        revision += 1
        let expected = revision, request = request, cache = cache
        isPreparing = true; message = "Preparing playback…"
        task = Task { [weak self] in
            var failures = 0
            for (index, source) in request.sources.enumerated() {
                do {
                    let url = try await cache.prepare(source, quality: request.quality)
                    guard !Task.isCancelled, let self, self.revision == expected else { return }
                    self.urls[source] = url
                    self.message = "Prepared \(index + 1)/\(request.sources.count)"
                } catch {
                    guard !Task.isCancelled, self?.revision == expected else { return }
                    failures += 1
                }
            }
            guard let self, self.revision == expected else { return }
            self.isPreparing = false; self.task = nil
            self.message = failures == 0 ? "Playback previews ready" : "\(failures) preview(s) unavailable — using originals. Retry when stopped."
        }
    }

    func stop() {
        revision += 1
        task?.cancel(); task = nil
        if isPreparing { message = "Preparation stopped · ready previews kept" }
        isPreparing = false
    }
}
