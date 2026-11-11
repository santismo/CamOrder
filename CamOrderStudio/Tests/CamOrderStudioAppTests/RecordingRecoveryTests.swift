import XCTest
@testable import CamOrderStudioApp
import CamOrderStudioCore

@MainActor
final class RecordingRecoveryTests: XCTestCase {
    func testPlacementFailureKeepsMovieAndRecoveryMessageAfterHostDisarms() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".camorderstudio")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ProjectStore()
        store.document = try ProjectDocument.create(at: folder, project: .empty(name: "Recovery"))
        let lane = store.project.timeline.lanes[0].id
        store.armLane(lane)
        store.startTakeRegion(at: .from(seconds: 18.62, frameRate: .fps30), cameraDeviceId: "test", preciseSeconds: 18.62, laneID: lane)
        let movie = try XCTUnwrap(store.pendingRecordingURL(laneID: lane))
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "motion", withExtension: "mp4", subdirectory: "Fixtures"))
        try FileManager.default.copyItem(at: fixture, to: movie)
        let original = try Data(contentsOf: movie)
        store.disarmLane(lane) // The session disarms before the encoder finalizes.
        store.finishTakeRegion(at: .from(seconds: 10, frameRate: .fps30), preciseSeconds: 10, actualMediaDuration: 1, laneID: lane)
        XCTAssertEqual(try Data(contentsOf: movie), original)
        XCTAssertEqual(store.project.media.count, 1)
        let reopened = try XCTUnwrap(ProjectDocument.open(at: folder).project.media.first)
        XCTAssertEqual(reopened.id, store.project.media[0].id)
        XCTAssertEqual(reopened.relativePath, store.project.media[0].relativePath)
        XCTAssertEqual(reopened.durationSeconds, store.project.media[0].durationSeconds)
        XCTAssertTrue(store.project.timeline.lanes[0].clips.isEmpty)
        XCTAssertNil(store.pendingTake)
        XCTAssertTrue(store.lastError?.contains("Video was saved") == true)
        XCTAssertTrue(store.lastError?.contains("Video Folder") == true)
    }

    func testMissingRecordingDoesNotClaimRecoveredFootage() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".camorderstudio")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ProjectStore()
        store.document = try ProjectDocument.create(at: folder, project: .empty(name: "Missing recording"))
        let lane = store.project.timeline.lanes[0].id
        store.armLane(lane)
        store.startTakeRegion(at: .from(seconds: 5, frameRate: .fps30), cameraDeviceId: "test", laneID: lane)
        store.finishTakeRegion(at: .from(seconds: 6, frameRate: .fps30), actualMediaDuration: 1, laneID: lane)
        XCTAssertTrue(store.project.media.isEmpty)
        XCTAssertNil(store.pendingTake)
        XCTAssertFalse(store.hasArmedLane)
        XCTAssertTrue(store.lastError?.contains("No usable video") == true)
    }
}
