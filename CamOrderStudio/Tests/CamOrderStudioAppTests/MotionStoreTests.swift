import XCTest
import SwiftUI
import AVFoundation
@testable import CamOrderStudioApp
@testable import CamOrderStudioCore

@MainActor
final class MotionStoreTests: XCTestCase {
    func testGroupedMotionUsesOneUndoAndPersistsWithoutChangingMedia() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".camorderstudio")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try await makeStore(at: folder)
        let before = store.project
        let media = try Data(contentsOf: folder.appendingPathComponent("test.mov"))
        let selection = store.selectedClipIDs
        var motion = AutomaticMotion(); motion.pan = .downRight
        let applied = await store.applyAutomaticMotion(motion)
        XCTAssertTrue(applied, store.lastError ?? "")
        XCTAssertEqual(store.selectedClipIDs, selection)
        let after = store.project
        XCTAssertTrue(store.selectedRegions().allSatisfy { $0.automationMarkers.count == 2 })
        XCTAssertEqual(try ProjectDocument.open(at: folder).project.timeline, after.timeline)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("test.mov")), media)
        store.undoProjectChange()
        XCTAssertEqual(store.project.timeline, before.timeline)
        XCTAssertFalse(store.canUndo, "The whole group must be one operation")
        store.redoProjectChange()
        XCTAssertEqual(store.project.timeline, after.timeline)
    }

    func testMissingMediaAbortsEntireSelection() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".camorderstudio")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try await makeStore(at: folder)
        store.project.timeline.lanes[1].clips[0].videoFile = "missing.mov"
        let before = store.project
        let applied = await store.applyAutomaticMotion(AutomaticMotion())
        XCTAssertFalse(applied)
        XCTAssertEqual(store.project, before)
        XCTAssertFalse(store.canUndo)
        XCTAssertNotNil(store.lastError)
    }

    func testMotionPanelRendersWithSelectedRegions() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".camorderstudio")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try await makeStore(at: folder)
        let view = NSHostingView(rootView: MotionPane().environmentObject(store).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 370, height: 630), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        window.orderFront(nil)
        view.setFrameSize(CGSize(width: 370, height: 630))
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.bounds.size, CGSize(width: 370, height: 630))
        if let path = ProcessInfo.processInfo.environment["CAMORDER_MOTION_SCREENSHOT"], let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: image)
            try image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        window.contentView = nil
    }

    func testFailedSaveDoesNotApplyOrAddUndo() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".camorderstudio")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try await makeStore(at: folder)
        let before = store.project
        let projectFile = folder.appendingPathComponent(ProjectDocument.projectFileName)
        try FileManager.default.removeItem(at: projectFile)
        try FileManager.default.createDirectory(at: projectFile, withIntermediateDirectories: false)
        let applied = await store.applyAutomaticMotion(AutomaticMotion())
        XCTAssertFalse(applied)
        XCTAssertEqual(store.project, before)
        XCTAssertFalse(store.canUndo)
        XCTAssertNotNil(store.lastError)
    }

    private func makeStore(at folder: URL) async throws -> ProjectStore {
        let store = ProjectStore()
        var project = CamOrderProject.empty(name: "Motion test")
        project.exportSettings.canvasWidth = 1920; project.exportSettings.canvasHeight = 1080
        for index in 0..<2 {
            let lane = project.timeline.lanes[index].id
            project.timeline.lanes[index].captureSourceID = ""
            project.timeline.lanes[index].videoOffsetMS = Double(index * -82)
            project.timeline.lanes[index].clips = [VideoClip(clipId: "test", mediaAssetId: "test", videoFile: "test.mov", armedLaneId: lane,
                logicStartTimecode: .from(seconds: 12, frameRate: .fps30), logicStartSeconds: 12,
                durationSeconds: 0.5 + Double(index) * 0.2, frameRate: .fps30, trimInSeconds: 0.1)]
        }
        project.media = [MediaAsset(id: "test", kind: .video, displayName: "Test", relativePath: "test.mov")]
        store.document = try ProjectDocument.create(at: folder, project: project)
        store.setRegionSelection(Set(project.timeline.lanes.flatMap(\.clips).map(\.id)))
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "motion", withExtension: "mp4", subdirectory: "Fixtures"))
        try FileManager.default.copyItem(at: fixture, to: folder.appendingPathComponent("test.mov"))
        return store
    }
}
