import Foundation

/// Audio hosts can pause render calls on silent tracks or briefly decline callbacks.
/// An absent callback is not a stop command. Only new, valid transport reports count.
public struct HostTransportMonitor {
    public enum Event: Equatable { case none, started, stopped, relocated }
    public struct Update {
        public var event: Event
        public var playing: Bool
        public var seconds: Double
        public var timingDelayed: Bool
    }
    private var playing = false
    private var lastReportTime: Double?
    private var lastSeconds = 0.0
    private var stopCandidate: Double?
    private var rewindCandidate: Double?
    private var stoppedSeconds = 0.0
    public init() {}
    public mutating func update(seconds: Double, reportedPlaying: Bool, valid: Bool, reportTime: Double, now: Double) -> Update {
        var event = Event.none
        let newReport = valid && seconds.isFinite && reportTime != lastReportTime
        if newReport {
            let previous = lastSeconds
            let reportIsRecent = now - reportTime < 1
            let position = max(0, seconds)
            if reportedPlaying {
                stopCandidate = nil
                if !playing && reportIsRecent { playing = true; event = .started }
                if event != .started && playing && position < previous - 0.25 {
                    if let candidate = rewindCandidate, position >= candidate - 0.05, position < candidate + 0.5, reportIsRecent {
                        event = .relocated
                        lastSeconds = position
                        rewindCandidate = nil
                    } else {
                        // Do not publish the first suspect zero/backward report.
                        // A transient callback must not jump the cursor or viewport.
                        rewindCandidate = position
                    }
                } else {
                    rewindCandidate = nil
                    lastSeconds = position
                }
            } else if playing && reportIsRecent {
                if stopCandidate == nil || abs(position - stoppedSeconds) > 0.001 { stopCandidate = now }
                stoppedSeconds = position
                // Keep the last valid rolling position until Stop is confirmed.
                if position >= previous { lastSeconds = position }
                rewindCandidate = nil
            } else if !playing {
                lastSeconds = position
                rewindCandidate = nil
            }
            lastReportTime = reportTime
        }
        if playing, let since = stopCandidate, now - since >= 0.2 {
            playing = false; event = .stopped; stopCandidate = nil
            lastSeconds = stoppedSeconds
        }

        let age = lastReportTime.map { max(0, now - $0) } ?? 0
        let delayed = playing && age > 0.5
        // Unknown transport must never invent a moving playhead. Keep an active
        // capture alive, but freeze the displayed position at the last host report.
        return Update(event: event, playing: playing, seconds: lastSeconds, timingDelayed: delayed)
    }
}
