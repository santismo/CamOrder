import XCTest
@testable import CamOrderStudioCore

final class MulticamEditingTests: XCTestCase {
    private func fixture() -> CamOrderProject {
        var project = CamOrderProject.empty(name: "Three cameras")
        project.sync.videoOffsetMS = -82
        project.media = [MediaAsset(id: "source", kind: .video, displayName: "Camera", relativePath: "take.mov")]
        for index in project.timeline.lanes.indices {
            project.timeline.lanes[index].videoOffsetMS = Double(index * 37)
            let lane = project.timeline.lanes[index].id
            let start = 10 - project.videoOffsetSeconds(forLane: lane)
            var clip = VideoClip(clipId: lane, mediaAssetId: "source", videoFile: "take.mov", armedLaneId: lane,
                logicStartTimecode: .from(seconds: start, frameRate: .fps30), logicStartSeconds: start,
                durationSeconds: 6, frameRate: .fps30, trimInSeconds: 1)
            clip.automationMarkers = [ClipAutomationMarker(timeSeconds: 0, framing: ClipFraming(zoom: 1)),
                ClipAutomationMarker(timeSeconds: 5, framing: ClipFraming(zoom: 2, offsetX: 0.5))]
            project.timeline.lanes[index].clips = [clip]
        }
        return project
    }

    func testLiveSwitchCutsEveryLaneAndPreservesSourceAutomationAndOffsets() throws {
        var project = fixture()
        let original = project
        let target = project.timeline.lanes[1].id
        let cut = 11.237
        let selected = try XCTUnwrap(project.switchCamera(toLaneID: target, at: cut))
        XCTAssertEqual(project.playbackClip(at: cut + 0.001)?.id, selected)
        XCTAssertEqual(project.playbackClip(at: cut - 0.001)?.armedLaneId, original.timeline.lanes[0].id)
        for lane in project.timeline.lanes {
            XCTAssertEqual(lane.clips.count, 2)
            XCTAssertEqual(lane.clips.reduce(0) { $0 + $1.durationSeconds }, 6, accuracy: 1e-9)
            XCTAssertEqual(project.presentedClip(lane.clips[1]).timelineStartSeconds, cut, accuracy: 1e-9)
            let source = original.playbackClips(at: 12).first { $0.armedLaneId == lane.id }!
            let right = project.presentedClip(lane.clips[1])
            XCTAssertEqual(right.sourceSeconds(at: 12), source.sourceSeconds(at: 12), accuracy: 1e-9)
            XCTAssertEqual(right.automatedFraming(atTimelineSecond: 12).zoom, source.automatedFraming(atTimelineSecond: 12).zoom, accuracy: 1e-9)
        }
        _ = project.switchCamera(toLaneID: project.timeline.lanes[2].id, at: 12.011)
        XCTAssertEqual(project.playbackClip(at: 12)?.armedLaneId, target)
        XCTAssertEqual(project.playbackClip(at: 12.02)?.armedLaneId, project.timeline.lanes[2].id)
        // A punch-in within an earlier shot leaves the already edited later shot.
        _ = project.switchCamera(toLaneID: project.timeline.lanes[0].id, at: 11.9)
        XCTAssertEqual(project.playbackClip(at: 11.95)?.armedLaneId, project.timeline.lanes[0].id)
        XCTAssertEqual(project.playbackClip(at: 12.02)?.armedLaneId, project.timeline.lanes[2].id)
        let reopened = try JSONDecoder().decode(CamOrderProject.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(reopened, project)
    }

    func testEmptyMutedAndMissingCamerasDoNotDamageAnEdit() {
        var project = fixture()
        project.timeline.lanes[1].isMuted = true
        project.timeline.lanes[2].clips[0].isEnabled = false
        let before = project
        for (lane, time) in [("lane_2", 11.0), ("lane_3", 11), ("missing", 11), ("lane_1", 9), ("lane_1", Double.nan)] {
            XCTAssertNil(project.switchCamera(toLaneID: lane, at: time))
            XCTAssertEqual(project, before)
        }
    }

    func testPausedFramingPreviewCannotChangePlaybackOrExportOrdering() {
        let project = fixture()
        let selected = project.timeline.lanes[2].clips[0].id
        XCTAssertEqual(project.stageClips(at: 12, selectedClipID: selected, previewSelection: true).first?.id, selected)
        XCTAssertEqual(project.stageClips(at: 12, selectedClipID: selected, previewSelection: false), project.playbackClips(at: 12))
        XCTAssertEqual(project.stageClips(at: 20, selectedClipID: selected, previewSelection: true), [])
        XCTAssertEqual(project.playbackClip(at: 12)?.armedLaneId, "lane_1")
    }

    func testDecoderIdentitiesSurviveCutsAndLayerChanges() {
        var project = fixture()
        let before = PlaybackSlot.slots(for: project.playbackClips(at: 11))
        _ = project.switchCamera(toLaneID: "lane_3", at: 11.5)
        let after = PlaybackSlot.slots(for: project.playbackClips(at: 12))
        XCTAssertEqual(Set(before.map(\.id)), Set(after.map(\.id)))
        XCTAssertNotEqual(Set(before.map { $0.clip.id }), Set(after.map { $0.clip.id }))
        let duplicate = PlaybackSlot.slots(for: [before[0].clip, before[0].clip])
        XCTAssertEqual(Set(duplicate.map(\.id)).count, 2)
    }

    func testRapidFreeCutsKeepEveryFrameAndExactExistingBoundary() {
        var project = fixture()
        _ = project.switchCamera(toLaneID: "lane_2", at: 11)
        _ = project.switchCamera(toLaneID: "lane_3", at: 11.02)
        XCTAssertEqual(project.playbackClip(at: 11.01)?.armedLaneId, "lane_2")
        XCTAssertEqual(project.playbackClip(at: 11.03)?.armedLaneId, "lane_3")
        for lane in project.timeline.lanes { XCTAssertEqual(lane.clips.reduce(0) { $0 + $1.durationSeconds }, 6, accuracy: 1e-9) }
        let counts = project.timeline.lanes.map { $0.clips.count }
        _ = project.switchCamera(toLaneID: "lane_1", at: 11.02)
        XCTAssertEqual(project.timeline.lanes.map { $0.clips.count }, counts)
    }
}
