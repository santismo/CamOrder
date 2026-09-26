import AVFoundation

/// Chases a timeline clock without cancelling an unfinished decoder seek on every UI tick.
@MainActor
public final class TimelineVideoPlayer {
    public let player = AVPlayer()
    private var url: URL?
    private var itemObservation: NSKeyValueObservation?
    private var generation = 0
    private var desiredSeconds = 0.0
    private var requestedHostTime = CMTime.zero
    private var playing = false
    private var seeking = false
    private var needsSeek = false
    private var lastSeekTime = -Double.infinity

    public init() {
        player.isMuted = true // The host supplies audio; source-camera audio must never double it.
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .pause
    }

    deinit { player.pause() }

    public func update(url: URL, sourceSeconds: Double, isPlaying: Bool) {
        guard sourceSeconds.isFinite else { return }
        let next = max(0, sourceSeconds)
        if playing != isPlaying || abs(next - desiredSeconds) > 0.20 { needsSeek = true }
        desiredSeconds = next
        requestedHostTime = CMClockGetTime(CMClockGetHostTimeClock())
        playing = isPlaying
        if self.url != url {
            self.url = url
            generation += 1
            seeking = false
            needsSeek = true
            lastSeekTime = -Double.infinity
            itemObservation = nil
            player.pause()
            let item = AVPlayerItem(url: url)
            player.replaceCurrentItem(with: item)
            let expectedGeneration = generation
            itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == expectedGeneration else { return }
                    self.reconcile()
                }
            }
        }
        if !playing { player.pause() }
        reconcile()
    }

    private func reconcile() {
        guard !seeking, let item = player.currentItem, item.status == .readyToPlay else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let actual = player.currentTime().seconds
        let duration = item.duration.seconds
        let elapsed = playing ? max(0, CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), requestedHostTime).seconds) : 0
        let desiredNow = desiredSeconds + elapsed
        let target = duration.isFinite && duration > 0 ? min(desiredNow, max(0, duration - 1.0 / 600)) : desiredNow
        let drift = abs(actual - target)
        let tolerance = playing ? 0.15 : 0.005
        let driftRequiresSeek = !actual.isFinite || (drift > tolerance && (!playing || now - lastSeekTime > 0.25))
        if needsSeek || driftRequiresSeek {
            needsSeek = false
            seeking = true
            lastSeekTime = now
            player.pause()
            let expectedGeneration = generation
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == expectedGeneration else { return }
                    self.seeking = false
                    // Reconcile against the newest request, including Stop or a scrub that
                    // arrived while this seek was decoding. Never resume stale transport.
                    self.reconcile()
                }
            }
        } else if playing {
            if player.rate == 0 {
                player.setRate(1, time: CMTime(seconds: desiredSeconds, preferredTimescale: 60000), atHostTime: requestedHostTime)
            }
        } else {
            player.pause()
        }
    }
}
