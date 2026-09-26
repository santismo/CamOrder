import XCTest
import AVFoundation
@testable import CamOrderStudioCore

@MainActor
final class VideoOffsetTests: XCTestCase {
    func testOffsetsAreAdditiveNonDestructiveAndBackwardCompatible() throws {
        var project = CamOrderProject.empty(name: "Offsets")
        let clip = VideoClip(clipId: "recorded", mediaAssetId: "video", videoFile: "video.mov", armedLaneId: project.timeline.lanes[0].id,
                             logicStartTimecode: .from(seconds: 10, frameRate: .fps30), logicStartSeconds: 10,
                             durationSeconds: 4, frameRate: .fps30, trimInSeconds: 2)
        project.timeline.lanes[0].clips = [clip]
        let oldData = try JSONEncoder().encode(project)
        let old = try JSONDecoder().decode(CamOrderProject.self, from: oldData)
        XCTAssertEqual(old.videoOffsetSeconds(forLane: clip.armedLaneId), 0)
        project.sync.videoOffsetMS = -42.6
        project.timeline.lanes[0].videoOffsetMS = 12.6
        XCTAssertEqual(project.videoOffsetSeconds(forLane: clip.armedLaneId), -0.03, accuracy: 0.000001)
        XCTAssertEqual(project.timeline.lanes[0].clips[0], clip)
        XCTAssertNil(project.playbackClip(at: 9.96))
        let displayed = try XCTUnwrap(project.playbackClip(at: 9.97))
        XCTAssertEqual(displayed.timelineStartSeconds, 9.97, accuracy: 0.000001)
        XCTAssertEqual(displayed.sourceSeconds(at: 10), 2.03, accuracy: 0.000001)
        XCTAssertEqual(RenderExportEngine.editedRange(in: project)?.startSeconds ?? 0, 9.97, accuracy: 0.001)
        let roundtrip = try JSONDecoder().decode(CamOrderProject.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(roundtrip, project)
        project.sync.videoOffsetMS = 0; project.timeline.lanes[0].videoOffsetMS = 0
        XCTAssertEqual(project.playbackClip(at: 10), clip)
    }

    func testOffsetsRespectLanePriorityAndNegativeStart() throws {
        var project = CamOrderProject.empty(name: "Overlap")
        let top = VideoClip(clipId: "top", mediaAssetId: "top", videoFile: "top.mov", armedLaneId: project.timeline.lanes[0].id,
                            logicStartTimecode: .from(seconds: 0, frameRate: .fps30), logicStartSeconds: 0,
                            durationSeconds: 4, frameRate: .fps30)
        project.timeline.lanes[0].clips = [top]
        project.sync.videoOffsetMS = -50
        let active = try XCTUnwrap(project.playbackClip(at: 0))
        XCTAssertEqual(active.sourceSeconds(at: 0), 0.05, accuracy: 0.00001)
        XCTAssertEqual(RenderExportEngine.editedRange(in: project)?.startSeconds, 0)
        XCTAssertEqual(RenderExportEngine.editedRange(in: project)?.endSeconds ?? 0, 3.95, accuracy: 0.001)
        project.timeline.lanes[0].isMuted = true
        XCTAssertNil(project.playbackClip(at: 1))
        XCTAssertNil(RenderExportEngine.editedRange(in: project))
    }
}
