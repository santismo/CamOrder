import XCTest
@testable import CamOrderStudioCore

final class RegionPlacementTests: XCTestCase {
    private func fixture() -> CamOrderProject {
        var project = CamOrderProject.empty()
        project.sync.videoOffsetMS = -82
        for index in project.timeline.lanes.indices {
            let id = project.timeline.lanes[index].id
            project.timeline.lanes[index].videoOffsetMS = Double(index * 150)
            project.timeline.lanes[index].clips = [VideoClip(clipId: "take_\(index)", mediaAssetId: "source", videoFile: "take.mov", armedLaneId: id,
                logicStartTimecode: .from(seconds: 10, frameRate: .fps30), logicStartSeconds: 10,
                durationSeconds: 8, frameRate: .fps30, trimInSeconds: 2, trimOutSeconds: 20,
                framing: ClipFraming(zoom: 1.5), automationMarkers: [ClipAutomationMarker(timeSeconds: 3, framing: ClipFraming(zoom: 2))],
                compositingLayer: 1, recordedSourceOriginSeconds: 8)]
        }
        return project
    }

    func testMovingAcrossOffsetsPreservesPresentationAndSourceFrames() throws {
        var project = fixture()
        let before = project.timeline.lanes[0].clips[0]
        let time = project.presentedClip(before).timelineStartSeconds
        XCTAssertTrue(project.moveRegions(ids: [before.id], seconds: 0, laneDelta: 2))
        XCTAssertTrue(project.timeline.lanes[0].clips.isEmpty)
        let moved = try XCTUnwrap(project.timeline.lanes[2].clips.last)
        XCTAssertEqual(moved.armedLaneId, project.timeline.lanes[2].id)
        XCTAssertEqual(project.presentedClip(moved).timelineStartSeconds, time, accuracy: 1e-9)
        XCTAssertEqual(project.presentedClip(moved).sourceSeconds(at: time + 1), project.presentedClip(before, laneID: "lane_1").sourceSeconds(at: time + 1), accuracy: 1e-9)
        var expected = before; expected.armedLaneId = moved.armedLaneId; expected.timelineStartSeconds = moved.timelineStartSeconds
        XCTAssertEqual(moved, expected)
        // Timeline zero may require a negative underlying start on a delayed lane.
        XCTAssertTrue(project.moveRegions(ids: [moved.id], seconds: -time, laneDelta: 0))
        XCTAssertEqual(project.presentedClip(project.timeline.lanes[2].clips.last!).timelineStartSeconds, 0, accuracy: 1e-9)
    }

    func testGroupMovesKeepLaneSpacingAndRejectOutOfBoundsAtomically() {
        var project = fixture()
        let ids = Set(project.timeline.lanes.prefix(2).flatMap(\.clips).map(\.id))
        let before = project
        XCTAssertEqual(project.clampedRegionLaneDelta(ids: ids, requested: 99), 1)
        XCTAssertEqual(project.clampedRegionLaneDelta(ids: ids, requested: -99), 0)
        XCTAssertFalse(project.moveRegions(ids: ids, seconds: 1, laneDelta: 2))
        XCTAssertFalse(project.moveRegions(ids: ids, seconds: .nan, laneDelta: 1))
        XCTAssertEqual(project, before)
        XCTAssertTrue(project.moveRegions(ids: ids, seconds: 1.25, laneDelta: 1))
        for index in 0..<2 {
            let old = before.timeline.lanes[index].clips[0]
            let moved = project.timeline.lanes[index + 1].clips.first { $0.id == old.id }!
            XCTAssertEqual(project.presentedClip(moved).timelineStartSeconds, before.presentedClip(old).timelineStartSeconds + 1.25, accuracy: 1e-9)
        }
    }

    func testReturnAfterMovingSplittingTrimmingAndReopeningPreservesEdits() throws {
        var project = fixture()
        let source = project.timeline.lanes[0].clips[0]
        XCTAssertTrue(project.moveRegions(ids: [source.id], seconds: 20, laneDelta: 1))
        let moved = project.timeline.lanes[1].clips.last!
        var right = try XCTUnwrap(moved.split(at: moved.timelineStartSeconds + 2)).1
        right.trimLeftEdge(to: right.timelineStartSeconds + 0.5)
        project.timeline.lanes[1].clips = [right]
        project = try JSONDecoder().decode(CamOrderProject.self, from: JSONEncoder().encode(project))
        XCTAssertTrue(project.returnRegionsToRecordedPosition(ids: [right.id]))
        let restored = project.timeline.lanes[1].clips[0]
        XCTAssertEqual(restored.timelineStartSeconds, 12.5, accuracy: 1e-9)
        var expected = right; expected.timelineStartSeconds = restored.timelineStartSeconds
        XCTAssertEqual(restored, expected)
        XCTAssertEqual(project.presentedClip(restored).timelineStartSeconds, 12.568, accuracy: 1e-9)
        XCTAssertFalse(project.returnRegionsToRecordedPosition(ids: [right.id]), "An already restored region makes no edit")
    }

    func testLegacyAndImportedRegionsCannotGuessOriginalPosition() throws {
        var project = fixture()
        project.timeline.lanes[1].clips[0].recordedSourceOriginSeconds = nil
        let all = Set(project.timeline.lanes.flatMap(\.clips).map(\.id))
        let before = project
        XCTAssertFalse(project.canReturnRegionsToRecordedPosition(ids: all))
        XCTAssertFalse(project.returnRegionsToRecordedPosition(ids: all))
        XCTAssertFalse(project.returnRegionsToRecordedPosition(ids: []))
        XCTAssertFalse(project.returnRegionsToRecordedPosition(ids: ["missing"]))
        XCTAssertEqual(project, before)
        let old = try JSONDecoder().decode(VideoClip.self, from: JSONEncoder().encode(project.timeline.lanes[1].clips[0]))
        XCTAssertNil(old.recordedTimelineStartSeconds)
    }

    func testHorizontalMovesKeepExistingOverlapOrder() {
        var project = fixture()
        var copy = project.timeline.lanes[0].clips[0]; copy.id = "copy"
        project.timeline.lanes[0].clips.append(copy)
        let ids = project.timeline.lanes[0].clips.map(\.id)
        XCTAssertTrue(project.moveRegions(ids: [ids[0]], seconds: 1, laneDelta: 0))
        XCTAssertEqual(project.timeline.lanes[0].clips.map(\.id), ids)
    }
}
