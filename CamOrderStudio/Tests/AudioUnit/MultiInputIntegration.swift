import AppKit
import AVFoundation
import CamOrderStudioCore

@MainActor
func runMultiInputRegression() throws {
    let host = COTestHostCreate()!, bridge = COTestHostBridge(host)!
    let a = SyntheticCamera(id: "test-camera-a", shade: 60)
    let b = SyntheticCamera(id: "test-camera-b", shade: 130)
    let c = SyntheticCamera(id: "test-camera-c", shade: 210)
    let d = SyntheticCamera(id: "test-camera-d", shade: 245)
    let session = PluginSession(bridge: bridge, camera: CameraCaptureEngine(), captureDevices: [a.selectedDeviceID!: a, b.selectedDeviceID!: b, c.selectedDeviceID!: c, d.selectedDeviceID!: d], logicLink: LogicTimecodeLink(createDestination: false))
    COSetSession(bridge, session)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CamOrder-multicam-" + UUID().uuidString + ".camorderstudio")
    defer { try? FileManager.default.removeItem(at: folder) }
    var project = CamOrderProject.empty(name: "Multi-camera session")
    project.defaultCaptureSourceID = a.selectedDeviceID
    session.store.document = try ProjectDocument.create(at: folder, project: project)
    let laneIDs = project.timeline.lanes.map(\.id)
    func pump(_ duration: Double, _ position: Double, _ playing: Bool) {
        let start = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - start < duration {
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            require(COTestHostRender(host, position + (playing ? elapsed : 0), playing, playing) == 0)
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }
    func disarm() { session.store.unarmAllLanes(); pump(0.45, session.sync.displaySeconds, false) }
    laneIDs.forEach { session.store.armLane($0) }
    pump(0.3, 10, false)
    require(session.inputs.sourceIDs == [a.selectedDeviceID!], "All Default lanes must share exactly one camera input")
    require(session.store.armedBuffers.count == 3 && a.startedFiles == 1, "One camera connection and recording file buffer all three armed lanes")
    pump(1.5, 10, true)
    require(session.store.pendingTakes.count == 3, "Three default lanes must record together")
    require(Set(session.store.pendingTakes.values.map(\.relativeVideoFile)).count == 1, "Shared input uses one file")
    pump(0.6, 11.5, false)
    let shared = session.store.project.timeline.lanes.compactMap { $0.clips.last }
    require(shared.count == 3 && Set(shared.map(\.mediaAssetId)).count == 1, "Each lane gets a region linked to one media asset")
    require(shared.allSatisfy { abs($0.timelineStartSeconds - 10) < 0.12 && abs($0.durationSeconds - 1.5) < 0.12 }, "Shared camera regions remain synchronized")
    print("PASS: all lanes default to one shared camera; one encoded movie supplies three independently armed, aligned regions")
    disarm()
    session.store.setLaneCaptureSource(laneIDs[1], sourceID: b.selectedDeviceID, name: "Camera B")
    session.store.setLaneCaptureSource(laneIDs[2], sourceID: c.selectedDeviceID, name: "Camera C")
    laneIDs.forEach { session.store.armLane($0) }
    pump(0.3, 20, false); pump(1.1, 20, true)
    require(session.inputs.sourceIDs.count == 3 && session.store.pendingTakes.count == 3, "Three independent cameras capture with no editor")
    b.disconnect()
    pump(1.0, 21.1, true)
    require(a.isRecording && c.isRecording && session.store.pendingTakes.count == 2, "One camera failure must not stop the other cameras")
    require(!session.store.project.timeline.lanes[1].isArmed && session.store.project.timeline.lanes[0].isArmed && session.store.project.timeline.lanes[2].isArmed, "Only the failed input's lane is disarmed")
    pump(0.6, 22.1, false)
    let separate = session.store.project.timeline.lanes.compactMap { $0.clips.last }
    require(Set(separate.map(\.videoFile)).count == 3, "Each different camera records a separate movie")
    require(separate.allSatisfy { abs($0.timelineStartSeconds - 20) < 0.12 }, "Independent camera regions share the Logic start")
    require(separate[0].durationSeconds > 2 && separate[1].durationSeconds > 0.8 && separate[1].durationSeconds < 1.4 && separate[2].durationSeconds > 2, "Disconnect preserves that camera's usable footage while other inputs continue")
    print("PASS: three cameras record simultaneous movies without an editor; disconnecting one saves its footage and leaves the others recording")
    disarm(); session.store.lastError = nil
    session.store.setLaneCaptureSource(laneIDs[1], sourceID: nil)
    session.store.setLaneCaptureSource(laneIDs[2], sourceID: nil)
    session.store.armLane(laneIDs[0]); pump(0.3, 30, false); pump(1.0, 30, true)
    session.store.armLane(laneIDs[1]); pump(1.0, 31, true)
    session.store.armLane(laneIDs[0]); pump(1.0, 32, true)
    require(a.isRecording && session.store.captureEndSeconds[laneIDs[0]] != nil, "Disarming one shared lane holds its end while the other records")
    pump(0.6, 33, false)
    let first = session.store.project.timeline.lanes[0].clips.last!, second = session.store.project.timeline.lanes[1].clips.last!
    require(first.mediaAssetId == second.mediaAssetId, "Late arming still shares the input file")
    require(abs(first.timelineStartSeconds - 30) < 0.12 && abs(first.durationSeconds - 2) < 0.15, "First lane retains its independent stop")
    require(abs(second.timelineStartSeconds - 31) < 0.15 && abs(second.durationSeconds - 2) < 0.15 && second.trimInSeconds > first.trimInSeconds + 0.8, "Late armed lane begins at the actual joining frame")
    print("PASS: independently joining and stopping lanes on one camera preserve each region's own start, end and source trim")
    disarm()
    session.store.setLaneCaptureSource(laneIDs[1], sourceID: b.selectedDeviceID, name: "Camera B")
    session.store.setLaneCaptureSource(laneIDs[2], sourceID: c.selectedDeviceID, name: "Camera C")
    b.isPreviewing = true; b.lastErrorMessage = nil
    session.store.addLane()
    let fourthID = session.store.project.timeline.lanes.last!.id
    require(!laneIDs.contains(fourthID) && session.inputs.sourceID(for: session.store.project.timeline.lanes.last!) == a.selectedDeviceID, "Added lanes inherit the shared default with a unique lane ID")
    session.store.setLaneCaptureSource(fourthID, sourceID: d.selectedDeviceID, name: "Camera D")
    session.store.project.timeline.lanes.map(\.id).forEach { session.store.armLane($0) }
    pump(0.3, 40, false); pump(1.2, 40, true)
    require(session.store.pendingTakes.count == 4 && session.inputs.sourceIDs.count == 4, "Four input capture: \(session.store.pendingTakes.count) takes / \(session.inputs.sourceIDs.count) inputs; preview states \([a,b,c,d].map(\.isPreviewing))")
    pump(0.6, 41.2, false)
    require(session.store.project.timeline.lanes.allSatisfy { abs(($0.clips.last?.timelineStartSeconds ?? 0) - 40) < 0.12 && ($0.clips.last?.durationSeconds ?? 0) > 1.1 }, "Four inputs finalize aligned, playable regions")
    print("PASS: adding a fourth input records four aligned movies; new lanes inherit Default until explicitly reassigned")
    disarm()
    session.store.saveProject()
    let reopened = try ProjectDocument.open(at: folder)
    require(reopened.project.defaultCaptureSourceID == a.selectedDeviceID && reopened.project.timeline.lanes[0].captureSourceID == nil && reopened.project.timeline.lanes[1].captureSourceID == b.selectedDeviceID, "Default and per-lane assignments survive reopening")
    require(!session.store.hasArmedLane, "All four lanes disarm after host Stop")
    for (index, pose) in [ClipFraming(zoom: 0.48, offsetX: -0.48, offsetY: -0.48),
                          ClipFraming(zoom: 0.48, offsetX: 0.48, offsetY: -0.48),
                          ClipFraming(zoom: 0.48, offsetX: -0.48, offsetY: 0.48)].enumerated() {
        let clip = session.store.project.timeline.lanes[index].clips.last!
        session.store.updateClipFraming(clip.id, zoom: pose.zoom, offsetX: pose.offsetX, offsetY: pose.offsetY, save: true)
    }
    // Actual plug-in UI, with four input cards and simultaneous layered regions.
    pump(0.25, 40.5, false)
    let view = Unmanaged<NSView>.fromOpaque(createCamOrderView(bridge)).takeRetainedValue()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 960), styleMask: [.titled,.resizable], backing: .buffered, defer: false)
    window.contentView = view; window.setContentSize(NSSize(width: 1280, height: 960)); view.setFrameSize(NSSize(width: 1280, height: 960))
    window.title = "CamOrder Studio 0.5.2"; window.center(); window.makeKeyAndOrderFront(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.8)); view.layoutSubtreeIfNeeded()
    if CommandLine.arguments.count > 1, let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) {
        let url = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("editor-multicam.png")
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }
    window.orderOut(nil); session.close(); COTestHostDispose(host)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
}
