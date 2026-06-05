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
}
