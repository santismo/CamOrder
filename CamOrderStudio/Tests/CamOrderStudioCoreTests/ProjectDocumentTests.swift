import Foundation
import XCTest
@testable import CamOrderStudioCore

final class ProjectDocumentTests: XCTestCase {
    func testProjectJSONRoundTrips() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ProjectDocument.fileExtension)
        defer { try? FileManager.default.removeItem(at: folder) }

        let project = CamOrderProject.empty(name: "Round Trip")
        let created = try ProjectDocument.create(at: folder, project: project)
        let opened = try ProjectDocument.open(at: created.folderURL)

        XCTAssertEqual(opened.project.name, "Round Trip")
        XCTAssertEqual(opened.project.timeline.lanes.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("media/video").path))
    }

    func testClipPlacementAppliesCaptureStartDelay() {
        let start = VideoClip.timelineStart(logicStartSeconds: 83.4, captureLatencyMs: 85)
        XCTAssertEqual(start, 83.485, accuracy: 0.0001)
    }

    func testClipAutomationInterpolatesFramingBetweenMarkers() {
        let clip = VideoClip(
            clipId: "take_001",
            mediaAssetId: "asset_001",
            videoFile: "media/video/take_001.mov",
            armedLaneId: "lane_1",
            logicStartTimecode: Timecode(hours: 0, minutes: 0, seconds: 0, frames: 0, frameRate: .fps30),
            logicStartSeconds: 10,
            durationSeconds: 10,
            frameRate: .fps30,
            framing: ClipFraming(zoom: 1, offsetX: 0, offsetY: 0),
            automationMarkers: [
                ClipAutomationMarker(timeSeconds: 0, framing: ClipFraming(zoom: 1, offsetX: 0, offsetY: 0)),
                ClipAutomationMarker(timeSeconds: 10, framing: ClipFraming(zoom: 3, offsetX: 0.5, offsetY: -0.5))
            ]
        )

        let framing = clip.automatedFraming(atTimelineSecond: 15)

        XCTAssertEqual(framing.zoom, 2, accuracy: 0.0001)
        XCTAssertEqual(framing.offsetX, 0.25, accuracy: 0.0001)
        XCTAssertEqual(framing.offsetY, -0.25, accuracy: 0.0001)
    }

    func testClipAutomationMarkersDefaultWhenOpeningOlderJSON() throws {
        let json = """
        {
          "id": "clip_001",
          "clipId": "take_001",
          "mediaAssetId": "asset_001",
          "videoFile": "media/video/take_001.mov",
          "armedLaneId": "lane_1",
          "logicStartTimecode": {
            "hours": 0,
            "minutes": 0,
            "seconds": 0,
            "frames": 0,
            "frameRate": "fps30"
          },
          "logicStartSeconds": 0,
          "durationSeconds": 2,
          "frameRate": "fps30"
        }
        """

        let clip = try JSONDecoder().decode(VideoClip.self, from: Data(json.utf8))

        XCTAssertTrue(clip.automationMarkers.isEmpty)
        XCTAssertTrue(clip.isEnabled)
        XCTAssertEqual(clip.trimInSeconds, 0)
    }
}
