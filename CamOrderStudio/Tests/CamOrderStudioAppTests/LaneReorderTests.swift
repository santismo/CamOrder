import XCTest
import SwiftUI
@testable import CamOrderStudioApp
@testable import CamOrderStudioCore

@MainActor
final class LaneReorderTests: XCTestCase {
    func testMouseDragAcrossSeveralRowsInBothDirections() async throws {
        let fixture = try await makeFixture(height: 680)
        defer { fixture.close() }
        let original = fixture.store.project.timeline.lanes
        try drag(fixture, source: "lane9", destination: "lane2", after: false, x: 450)
        XCTAssertEqual(fixture.store.project.timeline.lanes.map(\.id), ["lane1", "lane9", "lane2", "lane3", "lane4", "lane5", "lane6", "lane7", "lane8"])
        XCTAssertEqual(try ProjectDocument.open(at: fixture.folder).project.timeline, fixture.store.project.timeline)
        fixture.store.undoProjectChange()
        XCTAssertEqual(fixture.store.project.timeline.lanes, original)
        XCTAssertFalse(fixture.store.canUndo, "A drag across eight rows must be one Undo")
        settle()
        try drag(fixture, source: "lane1", destination: "lane8", after: true, x: 65)
        XCTAssertEqual(fixture.store.project.timeline.lanes.map(\.id), ["lane2", "lane3", "lane4", "lane5", "lane6", "lane7", "lane8", "lane1", "lane9"])
        fixture.store.undoProjectChange()
        XCTAssertEqual(fixture.store.project.timeline.lanes, original)
    }

    func testEscapeAndReleaseOutsideLeaveLanesUnchanged() async throws {
        let fixture = try await makeFixture(height: 680)
        defer { fixture.close() }
        let original = fixture.store.project.timeline.lanes
        let grip = try findGrip(fixture, "lane2")
        let start = grip.convert(NSPoint(x: 16, y: 11), to: nil)
        send(.leftMouseDown, at: start, fixture: fixture)
        send(.leftMouseDragged, at: NSPoint(x: 450, y: start.y - 220), fixture: fixture)
        XCTAssertNotNil(fixture.controller.destination)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: fixture.window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        fixture.window.sendEvent(escape)
        send(.leftMouseUp, at: NSPoint(x: 450, y: start.y - 220), fixture: fixture)
        XCTAssertEqual(fixture.store.project.timeline.lanes, original)
        XCTAssertNil(fixture.controller.destination)
        send(.leftMouseDown, at: start, fixture: fixture)
        send(.leftMouseDragged, at: NSPoint(x: -40, y: start.y - 220), fixture: fixture)
        send(.leftMouseUp, at: NSPoint(x: -40, y: start.y - 220), fixture: fixture)
        XCTAssertEqual(fixture.store.project.timeline.lanes, original)
        XCTAssertFalse(fixture.store.canUndo)
    }

    func testDraggingNearViewportEdgeScrollsToMoreLanes() async throws {
        let fixture = try await makeFixture(height: 260)
        defer { fixture.close() }
        let grip = try findGrip(fixture, "lane1")
        let scroll = try XCTUnwrap(grip.enclosingScrollView)
        let viewport = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
        let start = grip.convert(NSPoint(x: 16, y: 11), to: nil)
        let end = NSPoint(x: 450, y: viewport.minY + 8)
        let before = scroll.contentView.bounds.origin
        send(.leftMouseDown, at: start, fixture: fixture)
        send(.leftMouseDragged, at: end, fixture: fixture)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertGreaterThan(abs(scroll.contentView.bounds.origin.y - before.y), 150)
        send(.leftMouseUp, at: end, fixture: fixture)
        XCTAssertGreaterThan(try XCTUnwrap(fixture.store.project.timeline.lanes.firstIndex(where: { $0.id == "lane1" })), 4)
        XCTAssertNil(fixture.controller.draggedLaneID)
        let stopped = scroll.contentView.bounds.origin
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(scroll.contentView.bounds.origin, stopped, "Autoscroll stops on release")
        fixture.store.undoProjectChange()
        XCTAssertEqual(fixture.store.project.timeline.lanes.first?.id, "lane1")
    }

    func testLaneDragInsideFullEditor() async throws {
        let fixture = try await makeFixture(height: 680)
        defer { fixture.close() }
        let discovery = CameraCaptureEngine(automaticallyPreviewsDefaultSource: false)
        let inputs = LaneCaptureInputs(store: fixture.store, discovery: discovery, createsEngines: false)
        fixture.store.captureInputs = inputs
        fixture.store.isHosted = true
        fixture.store.project.defaultCaptureSourceID = ""
        let movie = try XCTUnwrap(Bundle.module.url(forResource: "motion", withExtension: "mp4", subdirectory: "Fixtures"))
        try FileManager.default.copyItem(at: movie, to: fixture.folder.appendingPathComponent("preview.mp4"))
        let clip = VideoClip(clipId: "Preview", mediaAssetId: "preview", videoFile: "preview.mp4", armedLaneId: "lane1",
            logicStartTimecode: .from(seconds: 0, frameRate: .fps30), logicStartSeconds: 0, durationSeconds: 0.8, frameRate: .fps30)
        fixture.store.project.timeline.lanes[0].clips = [clip]
        fixture.store.project.media = [MediaAsset(id: "preview", kind: .video, displayName: "Motion test", relativePath: "preview.mp4")]
        fixture.store.selectRegion(clip.id)
        fixture.window.contentView = NSHostingView(rootView: StudioShellView(syncEngine: LogicSyncEngine(isHosted: true), cameraEngine: discovery).environmentObject(fixture.store).preferredColorScheme(.dark))
        fixture.window.setContentSize(NSSize(width: 1280, height: 820))
        try await Task.sleep(nanoseconds: 500_000_000)
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        let grip = try findGrip(fixture, "lane1")
        let controller = try XCTUnwrap(grip.controller)
        let scroll = try XCTUnwrap(grip.enclosingScrollView)
        let viewport = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
        let start = grip.convert(NSPoint(x: grip.bounds.midX, y: grip.bounds.midY), to: nil)
        let end = NSPoint(x: viewport.midX, y: viewport.minY + 8)
        let root = fixture.window.contentView!
        XCTAssertTrue(root.hitTest(root.superview?.convert(start, from: nil) ?? start) === grip)
        send(.leftMouseDown, at: start, fixture: fixture)
        send(.leftMouseDragged, at: end, fixture: fixture)
        // Wait for the actual scroll destination; decoder/encoder warm-up in
        // other tests can delay timer delivery without breaking the gesture.
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if let target = controller.destination,
               let index = fixture.store.project.timeline.lanes.firstIndex(where: { $0.id == target.laneID }),
               index - 1 + (target.after ? 1 : 0) > 4 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotNil(controller.destination)
        send(.leftMouseUp, at: end, fixture: fixture)
        XCTAssertGreaterThan(try XCTUnwrap(fixture.store.project.timeline.lanes.firstIndex(where: { $0.id == "lane1" })), 4)
        fixture.store.undoProjectChange()
        XCTAssertEqual(fixture.store.project.timeline.lanes.first?.id, "lane1")
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(nanoseconds: 300_000_000)
        if let path = ProcessInfo.processInfo.environment["CAMORDER_EDITOR_SCREENSHOT"],
           let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(fixture.window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) {
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        inputs.stopAllPreviews()
    }

    @MainActor private struct Fixture {
        let store: ProjectStore
        let controller: LaneReorderController
        let window: NSWindow
        let folder: URL
        func close() { controller.cancel(); window.orderOut(nil); window.contentView = nil; try? FileManager.default.removeItem(at: folder) }
    }
    private func makeFixture(height: CGFloat) async throws -> Fixture {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".camorderstudio")
        let store = ProjectStore(), controller = LaneReorderController()
        var project = CamOrderProject.empty(name: "Lane drag")
        project.timeline.lanes = (1...9).map { VideoLane(id: "lane\($0)", name: "Camera \($0)", videoOffsetMS: Double($0 * -8), captureSourceID: "") }
        store.document = try ProjectDocument.create(at: folder, project: project)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LaneDragFixture(store: store, controller: controller).preferredColorScheme(.dark))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(nanoseconds: 250_000_000)
        window.contentView?.layoutSubtreeIfNeeded()
        return Fixture(store: store, controller: controller, window: window, folder: folder)
    }
    private func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
    private func findGrip(_ fixture: Fixture, _ id: String) throws -> LaneReorderNSView {
        try XCTUnwrap(descendants(fixture.window.contentView!).compactMap { $0 as? LaneReorderNSView }.first { $0.laneID == id })
    }
    private func drag(_ fixture: Fixture, source: String, destination: String, after: Bool, x: CGFloat) throws {
        let sourceView = try findGrip(fixture, source), targetView = try findGrip(fixture, destination)
        let start = sourceView.convert(NSPoint(x: 16, y: 11), to: nil)
        // Grips are at the top of each 56-point row: its midpoint is 17 lower.
        let target = targetView.convert(NSPoint(x: 16, y: 11), to: nil)
        let end = NSPoint(x: x, y: target.y - (after ? 40 : 6))
        let root = fixture.window.contentView!
        XCTAssertTrue(root.hitTest(root.superview?.convert(start, from: nil) ?? start) === sourceView, "The visible grip must receive mouse events")
        send(.leftMouseDown, at: start, fixture: fixture)
        for step in 1...5 {
            send(.leftMouseDragged, at: NSPoint(x: start.x + (end.x - start.x) * CGFloat(step) / 5, y: start.y + (end.y - start.y) * CGFloat(step) / 5), fixture: fixture)
        }
        XCTAssertEqual(fixture.controller.destination?.laneID, destination)
        XCTAssertEqual(fixture.controller.destination?.after, after)
        send(.leftMouseUp, at: end, fixture: fixture)
        XCTAssertNil(fixture.controller.destination)
    }
    private func send(_ type: NSEvent.EventType, at point: NSPoint, fixture: Fixture) {
        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        fixture.window.sendEvent(event)
        settle()
    }
    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.04)) }
}

private struct LaneDragFixture: View {
    @ObservedObject var store: ProjectStore
    let controller: LaneReorderController
    var body: some View {
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 8) {
                    Text("Timecode").frame(width: 150, height: 28)
                    ForEach(Array(store.project.timeline.lanes.enumerated()), id: \.element.id) { index, lane in
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                LaneReorderGrip(laneID: lane.id, number: index + 1, store: store, controller: controller)
                                Text(lane.name)
                            }
                            Spacer(minLength: 0)
                        }.frame(width: 150, height: 56)
                            .modifier(LaneReorderTarget(controller: controller, laneID: lane.id))
                    }
                }.padding(.vertical, 12)
                Color.gray.opacity(0.2).frame(width: 450, height: 628)
            }
        }
    }
}
