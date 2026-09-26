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
    public init() {}
    public mutating func update(seconds: Double, reportedPlaying: Bool, valid: Bool, reportTime: Double, now: Double) -> Update {
        var event = Event.none
        let newReport = valid && seconds.isFinite && reportTime != lastReportTime
        if newReport {
            let previous = lastSeconds
            let advanced = seconds > previous + 0.001
            let rewound = playing && seconds < previous - 0.25
            let reportIsRecent = now - reportTime < 1
            if reportedPlaying {
                stopCandidate = nil
                if !playing && reportIsRecent { playing = true; event = .started }
                if rewound, rewindCandidate == nil { rewindCandidate = seconds }
                else if let candidate = rewindCandidate {
                    if seconds < previous + 0.5 && seconds >= candidate && reportIsRecent { event = .relocated }
                    rewindCandidate = nil
                }
            } else if playing && reportIsRecent {
                // Allow 200 ms for a transient stopped report to recover. Advancing
                // position postpones confirmation even if the playing flag is false.
                if advanced || rewound || stopCandidate == nil { stopCandidate = now }
            }
            lastReportTime = reportTime
            lastSeconds = max(0, seconds)
        }
        if playing, let since = stopCandidate, now - since >= 0.2 {
            playing = false; event = .stopped; stopCandidate = nil
        }
        let age = lastReportTime.map { max(0, now - $0) } ?? 0
        let delayed = playing && age > 0.5
        // Unknown transport must never invent a moving playhead. Keep an active
        // capture alive, but freeze the displayed position at the last host report.
        return Update(event: event, playing: playing, seconds: lastSeconds, timingDelayed: delayed)
    }
}
