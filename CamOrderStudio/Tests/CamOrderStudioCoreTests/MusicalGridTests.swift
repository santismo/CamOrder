import XCTest
@testable import CamOrderStudioCore

final class MusicalGridTests: XCTestCase {
    func testHostBeatPhaseAndDivisionsAt88BPM() throws {
        let grid = try XCTUnwrap(MusicalGrid(hostSeconds: 37.7, beat: 55, tempoBPM: 88))
        XCTAssertEqual(grid.snapped(37.81, division: .beat), 37.7, accuracy: 1e-9)
        XCTAssertEqual(grid.snapped(37.7 + 0.65, division: .beat), 37.7 + 60 / 88, accuracy: 1e-9)
        XCTAssertEqual(grid.snapped(37.7 + 0.18, division: .quarterBeat), 37.7 + 15 / 88, accuracy: 1e-9)
        XCTAssertEqual(grid.snapped(37.7 + 0.60, division: .bar), 37.7 + 60 / 88, accuracy: 1e-9) // beat 56
        XCTAssertGreaterThanOrEqual(grid.snapped(-20, division: .beat), 0)
        XCTAssertNil(MusicalGrid(hostSeconds: .nan, beat: 1, tempoBPM: 88))
        XCTAssertNil(MusicalGrid(hostSeconds: 1, beat: .infinity, tempoBPM: 88))
        XCTAssertNil(MusicalGrid(hostSeconds: 1, beat: 1, tempoBPM: 0))
    }

    func testNumberedRegionsOverrideLanesAndSurviveSplitAndLegacyDecode() throws {
        func clip(_ id: String, layer: Int? = nil) -> VideoClip {
            VideoClip(id: id, clipId: id, mediaAssetId: "m", videoFile: "m.mov", armedLaneId: id,
                logicStartTimecode: .from(seconds: 2, frameRate: .fps30), logicStartSeconds: 2,
                durationSeconds: 4, frameRate: .fps30, compositingLayer: layer)
        }
        let auto = clip("auto"), front = clip("front", layer: 1), middle = clip("middle", layer: 2)
        var project = CamOrderProject.empty()
        project.timeline.lanes = [VideoLane(id: "auto", name: "Top", clips: [auto]),
            VideoLane(id: "middle", name: "Middle", clips: [middle]), VideoLane(id: "front", name: "Bottom", clips: [front])]
        XCTAssertEqual(project.playbackClips(at: 3).map(\.id), ["front", "middle", "auto"])
        project.sync.videoOffsetMS = -82; project.timeline.lanes[2].videoOffsetMS = 100
        XCTAssertEqual(project.playbackClip(at: 2)?.id, "middle")
        XCTAssertEqual(project.playbackClip(at: 2.1)?.id, "front")
        project.timeline.lanes[2].isMuted = true
        XCTAssertEqual(project.playbackClip(at: 3)?.id, "middle")
        project.timeline.lanes[2].isMuted = false
        let parts = try XCTUnwrap(front.split(at: 4))
        XCTAssertEqual(parts.0.compositingLayer, 1); XCTAssertEqual(parts.1.compositingLayer, 1)
        project.timeline.lanes[2].clips = [parts.0, parts.1]
        XCTAssertEqual(project.playbackClip(at: 4.0181)?.id, parts.1.id)
        let data = try JSONEncoder().encode(project)
        XCTAssertEqual(try JSONDecoder().decode(CamOrderProject.self, from: data), project)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(front)) as? [String: Any])
        legacy.removeValue(forKey: "compositingLayer")
        let restored = try JSONDecoder().decode(VideoClip.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(restored.compositingLayer)
        // Different explicit layers can coexist in the same organizational lane.
        project.timeline.lanes = [VideoLane(id: "one", name: "One", clips: [front, middle, auto])]
        XCTAssertEqual(project.playbackClips(at: 3).map(\.id), ["front", "middle", "auto"])
        var replacement = front; replacement.id = "replacement"
        project.timeline.lanes[0].clips.append(replacement)
        XCTAssertEqual(project.playbackClips(at: 3).map(\.id), ["replacement", "middle", "auto"])
    }
}
