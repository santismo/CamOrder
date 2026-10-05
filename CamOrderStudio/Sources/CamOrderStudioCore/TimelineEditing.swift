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

    public func split(at seconds: Double, minimumDuration: Double = 0.05) -> (VideoClip, VideoClip)? {
        let elapsed = seconds - timelineStartSeconds
        guard seconds.isFinite, elapsed > minimumDuration, elapsed < durationSeconds - minimumDuration else { return nil }
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

/// Identity follows the source in a lane, so a cut or layer change does not
/// tear down a decoder that is already playing the same movie continuously.
public struct PlaybackSlot: Identifiable {
    public struct ID: Hashable {
        public let laneID: String
        public let mediaID: String
        public let occurrence: Int
    }
    public let id: ID
    public let clip: VideoClip

    public static func slots(for clips: [VideoClip]) -> [PlaybackSlot] {
        var counts: [String: [String: Int]] = [:]
        return clips.map { clip in
            let occurrence = counts[clip.armedLaneId]?[clip.mediaAssetId] ?? 0
            counts[clip.armedLaneId, default: [:]][clip.mediaAssetId] = occurrence + 1
            return PlaybackSlot(id: ID(laneID: clip.armedLaneId, mediaID: clip.mediaAssetId, occurrence: occurrence), clip: clip)
        }
    }
}


extension CamOrderProject {
    /// Split every region crossing this presentation time, then promote the
    /// chosen camera's right-hand region. Existing later edits stay intact.
    /// Returns the foreground region ID; invalid/empty camera choices do nothing.
    @discardableResult
    public mutating func switchCamera(toLaneID laneID: String, at seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 0,
              let chosen = playbackClips(at: seconds).first(where: { $0.armedLaneId == laneID }),
              media.contains(where: { $0.id == chosen.mediaAssetId }) else { return nil }
        let order = min(Int.max - 1, timeline.lanes.flatMap(\.clips).compactMap(\.layerAssignmentOrder).max() ?? 0) + 1
        var selectedID: String?
        for laneIndex in timeline.lanes.indices {
            let offset = videoOffsetSeconds(forLane: timeline.lanes[laneIndex].id)
            let local = seconds - offset
            timeline.lanes[laneIndex].clips = timeline.lanes[laneIndex].clips.flatMap { original -> [VideoClip] in
                guard local >= original.timelineStartSeconds,
                      local < original.timelineStartSeconds + original.durationSeconds else { return [original] }
                // Live edits may be closer than 50 ms; retain all source frames.
                let parts = original.split(at: local, minimumDuration: 0)
                var right = parts?.1 ?? original
                if original.id == chosen.id {
                    right.compositingLayer = 1
                    right.layerAssignmentOrder = order
                    selectedID = right.id
                } else if right.compositingLayer == 1 {
                    right.compositingLayer = 2
                }
                return parts.map { [$0.0, right] } ?? [right]
            }
        }
        return selectedID
    }

    /// A framing preview is temporary. Playback/export always use playbackClips.
    public func stageClips(at seconds: Double, selectedClipID: String?, previewSelection: Bool) -> [VideoClip] {
        let output = playbackClips(at: seconds)
        guard previewSelection, let selectedClipID,
              let selected = timeline.lanes.lazy.flatMap(\.clips).first(where: { $0.id == selectedClipID }) else { return output }
        let presented = presentedClip(selected)
        guard seconds >= presented.timelineStartSeconds,
              seconds < presented.timelineStartSeconds + presented.durationSeconds else { return output }
        return [presented] + output.filter { $0.id != selectedClipID }
    }

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
