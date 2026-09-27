import AppKit
import SwiftUI
import CamOrderStudioCore

@MainActor
func runRestoredSessionRegression() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CamOrder-headless-" + UUID().uuidString + ".camorderstudio")
    defer { try? FileManager.default.removeItem(at: folder) }
    var project = CamOrderProject.empty(name: "Restored without editor")
    for index in project.timeline.lanes.indices { project.timeline.lanes[index].captureSourceID = "" }
    _ = try ProjectDocument.create(at: folder, project: project)
    let host = COTestHostCreate()!, bridge = COTestHostBridge(host)!
    defer { COTestHostDispose(host) }
    require(COGetSession(bridge) == nil)
    let data = try JSONSerialization.data(withJSONObject: ["version": 2, "path": folder.path])
    require(COTestHostRestoreProject(host, data as CFData) == 0)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    let session = COGetSession(bridge)!.takeUnretainedValue() as! PluginSession
    require(session.store.project.name == project.name, "AU restoration must create the session without its editor")
    for i in 0..<30 {
        require(COTestHostRender(host, 70 + Double(i) / 60, true, false) == 0)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60))
    }
    require(session.sync.isTransportRolling && session.sync.displaySeconds > 70.3)
    // A stopped scrub yields as soon as the host starts; reopening shares the same session.
    session.sync.receiveHostPosition(seconds: 71, playing: false, tempo: 120, available: true)
    session.sync.preview(at: 12)
    var editor: NSView? = Unmanaged<NSView>.fromOpaque(createCamOrderView(bridge)).takeRetainedValue()
    require(COGetSession(bridge)!.takeUnretainedValue() as! PluginSession === session)
    editor = nil
    for i in 0..<15 {
        require(COTestHostRender(host, 80 + Double(i) / 60, true, true) == 0)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60))
    }
    require(session.sync.editorSeconds > 80 && session.sync.previewSeconds == nil)
    editor = Unmanaged<NSView>.fromOpaque(createCamOrderView(bridge)).takeRetainedValue()
    require(editor != nil && session.sync.editorSeconds > 80)
    session.close()
    print("PASS: restored AU follows Logic before editor creation, after stopped scrubbing and across editor close/reopen")
}

@MainActor
func runEditorInteractionRegression(view: NSView, window: NSWindow, session: PluginSession, host: UnsafeMutableRawPointer) throws {
    func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
    func send(_ event: NSEvent) {
        NSApp.postEvent(event, atStart: false)
        while let queued = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) { NSApp.sendEvent(queued) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
    }
    let name = descendants(view).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "Lane name" }!
    window.makeFirstResponder(name)
    let text = name.currentEditor() as! NSTextView
    text.string = "Committed with Return"
    send(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
    require(session.store.project.timeline.lanes[0].name == "Committed with Return" && name.currentEditor() == nil, "Return commits and releases lane-name focus")
    window.makeFirstResponder(name)
    (name.currentEditor() as! NSTextView).string = "Committed by clicking away"
    let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        send(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!)
    }
    require(session.store.project.timeline.lanes[0].name == "Committed by clicking away" && name.currentEditor() == nil, "Clicking the canvas commits and releases lane-name focus")
    let scroller = descendants(view).compactMap { $0 as? TimelineNativeScrollView }.first!
    require(scroller.contentView.bounds.minX < 1, "Opening near the timeline start waits for layout and shows the beginning")
    let before = ProcessInfo.processInfo.systemUptime
    while ProcessInfo.processInfo.systemUptime - before < 0.6 {
        require(COTestHostRender(host, 2000 + ProcessInfo.processInfo.systemUptime - before, true, false) == 0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    require(abs(Double(scroller.contentView.bounds.midX) / 18 - session.sync.displaySeconds) < 0.2, "A distant playhead stays centered in the actual scroll view")
    let origin = scroller.contentView.bounds.minX
    require(COTestHostRender(host, 0, true, false) == 0)
    RunLoop.main.run(until: Date().addingTimeInterval(0.025))
    require(scroller.contentView.bounds.minX > origin - 50, "One bad zero callback cannot jump the timeline to the start")
    require(COTestHostRender(host, 2000.65, true, false) == 0)
    scroller.onMagnify?(0.5, scroller.contentView.bounds.width / 2)
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    require(abs(Double(scroller.contentView.bounds.midX) / 27 - 2000.6) < 0.3, "Pinch handler increases scale without losing the anchored time")
    print("PASS: native lane-name Return/outside-click focus; distant timeline centering, transient-zero protection and pinch zoom anchoring")
}
