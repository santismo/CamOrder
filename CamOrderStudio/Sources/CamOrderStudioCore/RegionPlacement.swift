import Foundation

extension CamOrderProject {
    /// Keep a multi-lane selection together at the first/last lane boundary.
    public func clampedRegionLaneDelta(ids: Set<String>, requested: Int) -> Int {
        let occupied = timeline.lanes.indices.filter { index in
            timeline.lanes[index].clips.contains { ids.contains($0.id) }
        }
        guard let first = occupied.first, let last = occupied.last else { return 0 }
        return max(-first, min(timeline.lanes.count - 1 - last, requested))
    }

    /// Preserve presentation timing when the destination has a different sync offset.
    @discardableResult
    public mutating func moveRegions(ids: Set<String>, seconds: Double, laneDelta: Int) -> Bool {
        guard seconds.isFinite, seconds != 0 || laneDelta != 0,
              clampedRegionLaneDelta(ids: ids, requested: laneDelta) == laneDelta else { return false }
        var moved: [(Int, VideoClip)] = []
        for source in timeline.lanes.indices {
            for var clip in timeline.lanes[source].clips where ids.contains(clip.id) {
                let target = source + laneDelta
                let destination = timeline.lanes[target].id
                clip.timelineStartSeconds += seconds + videoOffsetSeconds(forLane: timeline.lanes[source].id)
                    - videoOffsetSeconds(forLane: destination)
                guard clip.timelineStartSeconds.isFinite else { return false }
                clip.armedLaneId = destination
                moved.append((target, clip))
            }
        }
        guard !moved.isEmpty else { return false }
        if laneDelta == 0 {
            // Preserve overlap ordering for an ordinary horizontal move.
            let replacements = Dictionary(uniqueKeysWithValues: moved.map { ($0.1.id, $0.1) })
            for index in timeline.lanes.indices {
                timeline.lanes[index].clips = timeline.lanes[index].clips.map { replacements[$0.id] ?? $0 }
            }
        } else {
            for index in timeline.lanes.indices { timeline.lanes[index].clips.removeAll { ids.contains($0.id) } }
            for (target, clip) in moved { timeline.lanes[target].clips.append(clip) }
        }
        extendDurationForRegionPlacement()
        return true
    }

    public func canReturnRegionsToRecordedPosition(ids: Set<String>) -> Bool {
        let clips = timeline.lanes.flatMap(\.clips).filter { ids.contains($0.id) }
        return !clips.isEmpty && clips.count == ids.count && clips.allSatisfy { $0.recordedTimelineStartSeconds != nil }
    }

    /// Restore the remaining source frames to their recorded time, retaining all
    /// trims, framing, automation and the current lane/project sync corrections.
    @discardableResult
    public mutating func returnRegionsToRecordedPosition(ids: Set<String>) -> Bool {
        guard canReturnRegionsToRecordedPosition(ids: ids) else { return false }
        var changed = false
        for lane in timeline.lanes.indices {
            for index in timeline.lanes[lane].clips.indices {
                let clip = timeline.lanes[lane].clips[index]
                guard ids.contains(clip.id), let start = clip.recordedTimelineStartSeconds,
                      abs(start - clip.timelineStartSeconds) > 0.0000001 else { continue }
                timeline.lanes[lane].clips[index].timelineStartSeconds = start
                changed = true
            }
        }
        if changed { extendDurationForRegionPlacement() }
        return changed
    }

    private mutating func extendDurationForRegionPlacement() {
        let end = timeline.lanes.flatMap(\.clips).map {
            presentedClip($0).timelineStartSeconds + $0.durationSeconds
        }.max() ?? 0
        timeline.durationSeconds = max(timeline.durationSeconds, end)
    }
}
