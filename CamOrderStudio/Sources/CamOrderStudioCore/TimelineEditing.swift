import Foundation

extension Timeline {
    /// Lane order is compositing order; selection is only an editing concern.
    public func visibleClip(at seconds: Double) -> VideoClip? {
        guard seconds.isFinite else { return nil }
        for lane in lanes where !lane.isMuted {
            if let clip = lane.clips.last(where: {
                $0.isEnabled && seconds >= $0.timelineStartSeconds && seconds < $0.timelineStartSeconds + $0.durationSeconds
            }) { return clip }
        }
        return nil
    }
}

extension VideoClip {
    public func sourceSeconds(at timelineSeconds: Double, syncOffset: Double = 0) -> Double {
        max(0, trimInSeconds + timelineSeconds - timelineStartSeconds + syncOffset)
    }

    public func split(at seconds: Double) -> (VideoClip, VideoClip)? {
        let elapsed = seconds - timelineStartSeconds
        guard elapsed > 0.05, elapsed < durationSeconds - 0.05 else { return nil }
        var first = self
        first.durationSeconds = elapsed
        var second = self
        second.id = UUID().uuidString
        second.clipId += "_cut"
        second.timelineStartSeconds = seconds
        second.logicStartSeconds = seconds
        second.logicStartTimecode = .from(seconds: seconds, frameRate: frameRate)
        second.trimInSeconds += elapsed
        second.durationSeconds -= elapsed
        second.shiftAutomationOrigin(by: elapsed)
        return (first, second)
    }

    public mutating func trimLeftEdge(to requestedStart: Double) {
        let end = timelineStartSeconds + durationSeconds
        let earliest = max(0, timelineStartSeconds - trimInSeconds)
        let start = max(earliest, min(requestedStart, end - min(0.1, durationSeconds)))
        let delta = start - timelineStartSeconds
        timelineStartSeconds = start
        trimInSeconds += delta
        durationSeconds = end - start
        shiftAutomationOrigin(by: delta)
    }

    public mutating func constrainDuration(toSourceDuration duration: Double?) {
        guard let end = duration ?? trimOutSeconds, end.isFinite, end > 0 else { return }
        let available = max(0, end - trimInSeconds - (playbackSyncOffsetSeconds ?? 0))
        durationSeconds = min(durationSeconds, available)
    }

    // Keep out-of-region keys: they preserve the exact eased curve across a cut
    // and let extending a trimmed edge recover its original motion.
    private mutating func shiftAutomationOrigin(by seconds: Double) {
        guard seconds != 0, !automationMarkers.isEmpty else { return }
        if let first = automationMarkers.min(by: { $0.timeSeconds < $1.timeSeconds }), first.timeSeconds > 0 {
            automationMarkers.append(ClipAutomationMarker(timeSeconds: 0, framing: framing ?? ClipFraming()))
        }
        for index in automationMarkers.indices { automationMarkers[index].timeSeconds -= seconds }
        automationMarkers.sort { $0.timeSeconds < $1.timeSeconds }
    }

    public mutating func reframe(from reference: ClipFraming, to target: ClipFraming) {
        func adjusted(_ value: ClipFraming) -> ClipFraming {
            ClipFraming(zoom: value.zoom * target.zoom / max(0.001, reference.zoom),
                        offsetX: value.offsetX + target.offsetX - reference.offsetX,
                        offsetY: value.offsetY + target.offsetY - reference.offsetY,
                        rotationDegrees: value.rotationDegrees + target.rotationDegrees - reference.rotationDegrees)
        }
        framing = adjusted(framing ?? ClipFraming())
        for index in automationMarkers.indices { automationMarkers[index].framing = adjusted(automationMarkers[index].framing) }
    }
}


extension CamOrderProject {
    /// Presentation offsets are additive and non-destructive. Positive delays video.
    public func videoOffsetSeconds(forLane id: String) -> Double {
        let lane = timeline.lanes.first { $0.id == id }
        return ((sync.videoOffsetMS ?? 0) + (lane?.videoOffsetMS ?? 0)) / 1000
    }

    public func presentedClip(_ clip: VideoClip, laneID: String? = nil) -> VideoClip {
        var result = clip
        result.timelineStartSeconds += videoOffsetSeconds(forLane: laneID ?? clip.armedLaneId)
        return result
    }

    public var presentationTimeline: Timeline {
        var result = timeline
        for index in result.lanes.indices {
            let laneID = result.lanes[index].id
            result.lanes[index].clips = result.lanes[index].clips.map { presentedClip($0, laneID: laneID) }
        }
        return result
    }

    public func playbackClip(at seconds: Double) -> VideoClip? {
        for lane in timeline.lanes where !lane.isMuted {
            let local = seconds - videoOffsetSeconds(forLane: lane.id)
            if let clip = lane.clips.last(where: { $0.isEnabled && local >= $0.timelineStartSeconds && local < $0.timelineStartSeconds + $0.durationSeconds }) {
                return presentedClip(clip, laneID: lane.id)
            }
        }
        return nil
    }
}

public struct MovieExportRange: Equatable, Sendable {
    public let startSeconds: Double
    public let endSeconds: Double
    public var durationSeconds: Double { endSeconds - startSeconds }
    public init?(startSeconds: Double, endSeconds: Double) {
        guard startSeconds.isFinite, endSeconds.isFinite, endSeconds > max(0, startSeconds) else { return nil }
        self.startSeconds = max(0, startSeconds)
        self.endSeconds = endSeconds
    }
}
