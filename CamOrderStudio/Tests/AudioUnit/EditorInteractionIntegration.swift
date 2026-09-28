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
    COTestHostSetTempo(host, 88, 0.137, true)
    for _ in 0..<4 {
        require(COTestHostRender(host, 71, false, false) == 0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.04))
    }
    require(abs(session.store.tempoBPM - 88) < 0.00001 && abs(session.store.musicalGrid.originSeconds - 0.137) < 0.00001,
        "Host tempo and beat phase drive editing even without an editor")
    session.store.saveProject()
    let saved = try ProjectDocument.open(at: folder)
    require(saved.project.timeline.tempoBPM == 88 && abs(saved.project.timeline.gridOriginSeconds! - 0.137) < 0.00001)
    COTestHostSetTempo(host, 999, 0, false)
    for _ in 0..<4 {
        require(COTestHostRender(host, 71, false, false) == 0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.04))
    }
    require(session.store.tempoBPM == 88, "Missing beat callback must preserve the last real grid")
    COTestHostSetTempo(host, 120, 0, true)
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
    // Test production trim handles through window mouse dispatch, including the
    // narrow-region layout. Each gesture must commit once and remain undoable.
    let store = session.store
    var fixture = store.project.timeline.lanes[0].clips[0]
    fixture.timelineStartSeconds = 4; fixture.trimInSeconds = 0; fixture.durationSeconds = 2
    store.project.timeline.lanes[0].clips = [fixture]
    store.selectedClipId = fixture.id
    session.sync.preview(at: 5)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    func trim(left: Bool, pixels: CGFloat) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        view.layoutSubtreeIfNeeded()
        let id = "trim-\(left ? "left" : "right")-\(fixture.id)"
        guard let handle = descendants(view).first(where: { $0.identifier?.rawValue == id }) else { fatalError("Missing trim handle \(id)") }
        let point = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        for step in 0...6 {
            let type: NSEvent.EventType = step == 0 ? .leftMouseDown : (step == 6 ? .leftMouseUp : .leftMouseDragged)
            let delta = pixels * CGFloat(min(step, 5)) / 5
            send(NSEvent.mouseEvent(with: type, location: NSPoint(x: point.x + delta, y: point.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!)
        }
    }
    trim(left: true, pixels: 9)
    require(abs(store.clip(id: fixture.id)!.timelineStartSeconds - 4.5) < 0.001, "Dragging the left handle changes the start by 0.5 seconds")
    require(abs(store.clip(id: fixture.id)!.trimInSeconds - 0.5) < 0.001 && abs(store.clip(id: fixture.id)!.durationSeconds - 1.5) < 0.001)
    store.undoProjectChange()
    require(store.clip(id: fixture.id) == fixture, "One left-edge drag is one Undo step")
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    trim(left: false, pixels: -9)
    require(abs(store.clip(id: fixture.id)!.durationSeconds - 1.5) < 0.001 && store.clip(id: fixture.id)!.timelineStartSeconds == 4,
        "Right trim: expected start 4 and duration 1.5; got \(store.clip(id: fixture.id)!.timelineStartSeconds), \(store.clip(id: fixture.id)!.durationSeconds)")
    store.undoProjectChange()
    require(store.clip(id: fixture.id) == fixture, "One right-edge drag is one Undo step")
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    trim(left: true, pixels: 9); trim(left: true, pixels: -9)
    require(abs(store.clip(id: fixture.id)!.trimInSeconds) < 0.001, "Dragging left restores previously trimmed source")
    store.updateClipStart(fixture.id, startSeconds: 0)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    trim(left: true, pixels: 9)
    require(abs(store.clip(id: fixture.id)!.timelineStartSeconds - 0.5) < 0.001, "The left handle stays reachable at project zero")
    // Dispatch to the production AU responder: Command-C must copy, never cut.
    func command(_ key: String, code: UInt16) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!
        require(view.performKeyEquivalent(with: event), "AU responder must handle Command-\(key)")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(view)
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    require(window.isKeyWindow, "Shortcut regression requires the owned editor to have keyboard focus")
    let countBefore = store.project.timeline.lanes[0].clips.count
    command("c", code: 8)
    require(store.canPasteRegion && store.project.timeline.lanes[0].clips.count == countBefore,
        "Command-C copies without splitting; paste available \(store.canPasteRegion), regions \(store.project.timeline.lanes[0].clips.count), responder \(String(describing: window.firstResponder))")
    session.sync.preview(at: 10)
    command("v", code: 9)
    require(store.project.timeline.lanes[0].clips.count == countBefore + 1 && abs(store.selectedClip()!.timelineStartSeconds - 10) < 0.001)
    command("s", code: 1)
    require(store.lastManualSaveAt != nil)
    let saved = try ProjectDocument.open(at: store.document!.folderURL)
    require(saved.project.timeline == store.project.timeline, "Command-S saves the edited timeline")
    print("PASS: native left/right edge drags trim and restore footage with one-step Undo; Command-C/V/S copy, paste at playhead and save without cutting")
    // Exercise Shift-click through native region bodies, then group gestures and
    // T/number keys through the same AU responder used by the real editor.
    var cameraRegions: [VideoClip] = []
    for index in 0..<3 {
        var region = fixture
        region.id = UUID().uuidString; region.clipId = "Camera \(index + 1)"
        region.armedLaneId = store.project.timeline.lanes[index].id
        region.timelineStartSeconds = 4; region.trimInSeconds = 0; region.durationSeconds = 2
        store.project.timeline.lanes[index].clips = [region]
        cameraRegions.append(region)
    }
    store.selectedClipId = nil
    session.sync.preview(at: 5)
    RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    func regionMouse(_ id: String, shift: Bool = false, drag: CGFloat = 0, leftEdge: Bool = false) {
        view.layoutSubtreeIfNeeded()
        let identifier = "\(leftEdge ? "trim-left" : "region-body")-\(id)"
        guard let target = descendants(view).first(where: { $0.identifier?.rawValue == identifier }) else { fatalError("Missing \(identifier)") }
        // The horizontal timeline sits inside a separate vertical lane scroller.
        // Reveal the target through both ancestors, not just the nearest scroller.
        var ancestor = target.superview
        while let current = ancestor {
            if let scroll = current as? NSScrollView, let documentView = scroll.documentView {
                let rect = target.convert(target.bounds, to: documentView)
                var origin = scroll.contentView.bounds.origin
                if rect.minY < origin.y { origin.y = rect.minY }
                if rect.maxY > origin.y + scroll.contentView.bounds.height { origin.y = rect.maxY - scroll.contentView.bounds.height }
                scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView)
            }
            ancestor = current.superview
        }
        view.layoutSubtreeIfNeeded()
        let point = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        let flags: NSEvent.ModifierFlags = shift ? .shift : []
        for step in 0...4 {
            if drag == 0 && step > 0 && step < 4 { continue }
            let type: NSEvent.EventType = step == 0 ? .leftMouseDown : (step == 4 ? .leftMouseUp : .leftMouseDragged)
            send(NSEvent.mouseEvent(with: type, location: NSPoint(x: point.x + drag * CGFloat(min(step, 3)) / 3, y: point.y),
                modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!)
        }
    }
    for (index, region) in cameraRegions.enumerated() {
        regionMouse(region.id, shift: index > 0)
    }
    require(store.selectedClipIDs == Set(cameraRegions.map(\.id)), "Shift-click must retain all three camera selections")
    regionMouse(cameraRegions[1].id, shift: true)
    require(store.selectedClipIDs.count == 2, "Shift-click a selected region removes only that region")
    regionMouse(cameraRegions[1].id, shift: true)
    regionMouse(cameraRegions[0].id, drag: 9)
    require(store.selectedRegions().allSatisfy { abs($0.timelineStartSeconds - 4.5) < 0.001 }, "Native drag moves the whole selection on the beat")
    store.undoProjectChange()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    regionMouse(cameraRegions[0].id, drag: 9, leftEdge: true)
    require(store.selectedRegions().allSatisfy { abs($0.timelineStartSeconds - 4.5) < 0.001 && abs($0.trimInSeconds - 0.5) < 0.001 },
        "Dragging one selected left edge trims all cameras together")
    store.undoProjectChange()
    func editKey(_ key: String, code: UInt16) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!
        require(view.performKeyEquivalent(with: event), "AU must handle \(key)")
    }
    window.makeFirstResponder(view)
    session.sync.preview(at: 5.08)
    editKey("t", code: 17)
    require(store.project.timeline.lanes.prefix(3).allSatisfy { $0.clips.count == 2 }, "T cuts every selected camera")
    require(store.selectedRegions().count == 3 && store.selectedRegions().allSatisfy { abs($0.timelineStartSeconds - 5) < 0.001 }, "T uses the snapped common playhead")
    editKey("3", code: 20)
    require(store.selectedRegions().allSatisfy { $0.compositingLayer == 3 })
    let foreground = store.project.timeline.lanes[2].clips.last!
    store.selectRegion(foreground.id)
    editKey("1", code: 18)
    require(store.playbackClip(at: 5.5)?.id == foreground.id, "Number 1 puts the selected lower-lane region in front")
    // Typing a digit into a lane name must remain text editing.
    window.makeFirstResponder(name)
    let typing = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, characters: "2", charactersIgnoringModifiers: "2", isARepeat: false, keyCode: 19)!
    _ = view.performKeyEquivalent(with: typing)
    require(store.clip(id: foreground.id)?.compositingLayer == 1, "Layer shortcuts never steal lane-name typing")
    window.makeFirstResponder(view)
    print("PASS: native Shift-click/toggle, grouped move and trim gestures, T multi-camera split, numbered foreground and text-field shortcut protection")
    // End the trim gesture's deliberate two-second manual-scroll grace period
    // before independently testing automatic transport following.
    scroller.manualUntil = 0
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
