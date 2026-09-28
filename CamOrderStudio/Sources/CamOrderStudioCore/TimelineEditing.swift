import Foundation

extension Timeline {
    /// Numbered layers precede automatic lane order. The most recent assignment
    /// breaks ties, then lane order and the last overlapping take in that lane.
    public func visibleClips(at seconds: Double) -> [VideoClip] { orderedClips(at: seconds) { _ in 0 } }

    fileprivate func orderedClips(at seconds: Double, offset: (String) -> Double) -> [VideoClip] {
        guard seconds.isFinite else { return [] }
        var candidates: [(clip: VideoClip, lane: Int, index: Int)] = []
        for (index, lane) in lanes.enumerated() where !lane.isMuted {
            let shift = offset(lane.id), local = seconds - shift
            for (clipIndex, clip) in lane.clips.enumerated() where clip.isEnabled
                && local >= clip.timelineStartSeconds && local < clip.timelineStartSeconds + clip.durationSeconds {
                var presented = clip; presented.timelineStartSeconds += shift
                candidates.append((presented, index, clipIndex))
            }
        }
        let ordered = candidates.sorted {
            let left = $0.clip.compositingLayer ?? 10, right = $1.clip.compositingLayer ?? 10
            if left != right { return left < right }
            let leftOrder = $0.clip.compositingLayer == nil ? 0 : ($0.clip.layerAssignmentOrder ?? 0)
            let rightOrder = $1.clip.compositingLayer == nil ? 0 : ($1.clip.layerAssignmentOrder ?? 0)
            if leftOrder != rightOrder { return leftOrder > rightOrder }
            return $0.lane == $1.lane ? $0.index > $1.index : $0.lane < $1.lane
        }
        var occupied: [Int: Set<Int>] = [:]
        return ordered.compactMap { entry in
            let layer = entry.clip.compositingLayer ?? 10
            guard occupied[entry.lane, default: []].insert(layer).inserted else { return nil }
            return entry.clip
        }
    }

    public func visibleClip(at seconds: Double) -> VideoClip? { visibleClips(at: seconds).first }

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

    public mutating func trimLeftEdge(to requestedStart: Double, minimumTimelineStart: Double = 0) {
        let end = timelineStartSeconds + durationSeconds
        // Presentation offsets can put visible zero before underlying zero.
        // Keep an already earlier edge stable, and allow restoring its footage.
        let earliest = min(timelineStartSeconds, max(minimumTimelineStart, timelineStartSeconds - trimInSeconds))
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

    public mutating func setAutomationFraming(_ value: ClipFraming, atLocalSecond seconds: Double) {
        let time = min(durationSeconds, max(0, seconds))
        let tolerance = 0.5 / max(1, frameRate.framesPerSecond)
        if let index = automationMarkers.firstIndex(where: { abs($0.timeSeconds - time) <= tolerance }) {
            automationMarkers[index].framing = value
        } else {
            automationMarkers.append(ClipAutomationMarker(timeSeconds: time, framing: value))
        }
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

    /// Shared by Main Stage and movie export, including per-lane sync offsets.
    public func playbackClips(at seconds: Double) -> [VideoClip] {
        timeline.orderedClips(at: seconds) { videoOffsetSeconds(forLane: $0) }
    }

    public func playbackClip(at seconds: Double) -> VideoClip? { playbackClips(at: seconds).first }

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
