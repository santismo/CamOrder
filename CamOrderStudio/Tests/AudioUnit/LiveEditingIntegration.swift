import AppKit
import CamOrderStudioCore

@MainActor
func runLiveEditingRegression() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CamOrder-live-" + UUID().uuidString + ".camorderstudio")
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = ProjectStore()
    store.document = try ProjectDocument.create(at: folder, project: .empty(name: "Live editing"))
    let media = MediaAsset(kind: .video, displayName: "Camera", relativePath: "camera.mov", durationSeconds: 20)
    store.project.media = [media]
    store.project.timeline.lanes = (1...9).map { number in
        let id = "camera_\(number)"
        let clip = VideoClip(clipId: id, mediaAssetId: media.id, videoFile: media.relativePath, armedLaneId: id,
            logicStartTimecode: .from(seconds: 4, frameRate: .fps30), logicStartSeconds: 4, durationSeconds: 8, frameRate: .fps30)
        return VideoLane(id: id, name: "Camera \(number)", clips: [clip])
    }
    let original = store.project
    store.setSnapLiveCutsToGrid(false)
    store.switchCamera(number: 9, at: 5.123)
    require(store.project.timeline.lanes.allSatisfy { $0.clips.count == 2 })
    require(store.playbackClip(at: 5.2)?.armedLaneId == "camera_9")
    require(abs(store.selectedClip()!.timelineStartSeconds - 5.123) < 1e-9)
    store.undoProjectChange()
    require(store.project.timeline.lanes == original.timeline.lanes, "One live switch is one Undo for all nine lanes")
    store.redoProjectChange()
    require(store.playbackClip(at: 5.2)?.armedLaneId == "camera_9")
    store.receiveHostGrid(seconds: 10, beat: 12, tempo: 88)
    store.setSnapLiveCutsToGrid(true)
    let expected = store.musicalGrid.snapped(6.123, division: store.gridDivision)
    store.switchCamera(number: 2, at: 6.123)
    require(abs(store.selectedClip()!.timelineStartSeconds - expected) < 1e-9)
    require(store.playbackClip(at: expected + 0.001)?.armedLaneId == "camera_2")
    let beforeMove = store.project.timeline.lanes
    store.moveLane("camera_9", relativeTo: "camera_1", after: false)
    require(store.project.timeline.lanes[0] == beforeMove[8] && store.project.timeline.lanes[1] == beforeMove[0])
    require(store.project.timeline.lanes.flatMap(\.clips).count == beforeMove.flatMap(\.clips).count)
    store.undoProjectChange(); require(store.project.timeline.lanes == beforeMove)
    store.redoProjectChange()
    store.setSnapLiveCutsToGrid(false)
    store.switchCamera(number: 1, at: 8.12)
    require(store.playbackClip(at: 8.2)?.armedLaneId == "camera_9", "Live numbers follow reordered lanes")
    store.moveLane("camera_9", relativeTo: "camera_4", after: true)
    require(store.project.timeline.lanes[4].id == "camera_9", "Drop can move across multiple lanes, before or after a target")
    let saved = try ProjectDocument.open(at: folder)
    require(saved.project.timeline == store.project.timeline && saved.project.timeline.snapLiveCutsToGrid == false,
        "Lane order, cuts, output assignments and live snap setting must survive saving")
    let beforeInvalid = store.project
    store.switchCamera(number: 1, at: 100)
    store.switchCamera(number: 10, at: 8.5)
    require(store.project == beforeInvalid)
    store.armLane("camera_1")
    let armed = store.project
    store.switchCamera(number: 1, at: 8.5)
    require(store.project == armed, "Live editing must not split an in-progress camera recording")
    print("PASS: nine-camera free/snapped live cuts, one-step Undo/Redo, cross-lane reordering, reassigned number keys, save/reopen and safe empty/armed choices")
}

@MainActor
func runLiveEditorRegression(view: NSView, window: NSWindow, session: PluginSession, host: UnsafeMutableRawPointer, screenshots: URL) throws {
    let store = session.store
    func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
    func pump(_ seconds: Double, playing: Bool) {
        for index in 0..<12 {
            require(COTestHostRender(host, seconds + (playing ? Double(index) / 60 : 0), playing, false) == 0)
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60))
        }
        view.layoutSubtreeIfNeeded()
    }
    pump(4, playing: false)
    store.unarmAllLanes()
    let sample = store.project.timeline.lanes[0].clips[0]
    for index in 0..<3 {
        var clip = sample
        clip.id = UUID().uuidString; clip.armedLaneId = store.project.timeline.lanes[index].id
        clip.timelineStartSeconds = 4; clip.trimInSeconds = 0; clip.durationSeconds = 2
        clip.automationMarkers = []; clip.compositingLayer = nil; clip.layerAssignmentOrder = nil
        store.project.timeline.lanes[index].clips = [clip]
    }
    store.setSnapLiveCutsToGrid(false)
    store.selectedClipId = nil
    pump(4.5, playing: true)
    func players() -> Set<ObjectIdentifier> {
        Set(descendants(view).filter { String(describing: type(of: $0)).contains("PlaybackPlayerNSView") }.map(ObjectIdentifier.init))
    }
    let existingPlayers = players()
    require(existingPlayers.count == 3, "Three cameras should have three continuous decoders")
    window.makeFirstResponder(view)
    func digit(_ key: String, code: UInt16) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!
        require(view.performKeyEquivalent(with: event))
    }
    digit("2", code: 19)
    let cut = store.selectedClip()!.timelineStartSeconds
    require(store.project.timeline.lanes.prefix(3).allSatisfy { $0.clips.count == 2 })
    require(store.playbackClip(at: cut + 0.02)?.armedLaneId == store.project.timeline.lanes[1].id)
    pump(cut + 0.05, playing: true)
    require(players() == existingPlayers, "Live cuts must reuse all three decoded player views")
    pump(5.3, playing: false)
    session.sync.preview(at: 5.3) // Hold this paused edit while the earlier MTC fixture expires.
    let count = store.project.timeline.lanes.flatMap(\.clips).count
    digit("3", code: 20)
    require(store.selectedClip()?.compositingLayer == 3 && store.project.timeline.lanes.flatMap(\.clips).count == count,
        "Stopped numbers retain layer assignment without making a live cut")
    store.undoProjectChange()
    store.selectedClipId = store.project.timeline.lanes[2].clips.last!.id
    store.insertAutomationMarker(at: 5.3)
    store.beginSelectedClipFramingEdit()
    store.updateSelectedClipFraming(zoom: 0.65, offsetX: 0.25, trackUndo: false)
    store.endClipFramingEdit()
    require(store.project.stageClips(at: 5.3, selectedClipID: store.selectedClipId, previewSelection: true).first?.id == store.selectedClipId)
    require(store.playbackClip(at: 5.3)?.armedLaneId == store.project.timeline.lanes[1].id, "Framing preview must not change output")
    // Persist the layout preference across editor reconstruction, then restore
    // this test process's preference so it cannot change the user's layout.
    let key = "CamOrderStudio.ControlsAtBottom"
    let preference = UserDefaults.standard.object(forKey: key)
    defer {
        if let preference { UserDefaults.standard.set(preference, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }
    UserDefaults.standard.set(true, forKey: key)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    window.setContentSize(NSSize(width: 1280, height: 820)); view.setFrameSize(NSSize(width: 1280, height: 820))
    view.layoutSubtreeIfNeeded()
    let output = store.document!.folderURL.appendingPathComponent("live-edit-test.mov")
    store.setExportCanvasSize(width: 64, height: 64)
    store.exportController.start(project: store.project, folderURL: store.document!.folderURL, destinationURL: output,
        range: MovieExportRange(startSeconds: 4, endSeconds: 5.8)!)
    require(store.exportController.isRendering)
    // Hiding the editor must not discard export progress or its finished result.
    window.orderOut(nil)
    let deadline = Date().addingTimeInterval(15)
    while store.exportController.isRendering && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    require(store.exportController.finished && store.exportController.lastExportURL == output,
        "Export failed: \(store.exportController.errorMessage ?? "timed out")")
    require(store.exportController.progress == 1 && FileManager.default.fileExists(atPath: output.path))
    require(FileManager.default.fileExists(atPath: output.deletingPathExtension().appendingPathExtension("logic-placement.txt").path))
    store.setExportCanvasSize(width: 1920, height: 1080)
    window.makeKeyAndOrderFront(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.4)); view.layoutSubtreeIfNeeded()
    if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) {
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: screenshots.appendingPathComponent("editor-live-bottom.png"))
    }
    print("PASS: native AU playing keys cut/switch, paused keys assign layers, zero decoder replacements across the live cut, obscured-clip automation preview, and hidden-window export completion/placement note")
}
