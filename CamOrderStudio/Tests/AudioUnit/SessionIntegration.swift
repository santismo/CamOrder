import AppKit
import AVFoundation
import CoreMIDI
import CamOrderStudioCore

// Synthetic camera for exercising the production session without camera permission.
// This encodes real frames; only the physical camera is replaced.
@MainActor
final class SyntheticCamera: HostedCaptureDevice {
    let selectedDeviceID: String?
    private let shade: UInt8
    private var simulatedError: String?
    private(set) var startedFiles = 0
    init(id: String = "synthetic-test", shade: UInt8 = 100) { selectedDeviceID = id; self.shade = shade }
    func disconnect() { simulatedError = "Test camera disconnected"; isPreviewing = false; stopRecording() }
    var isRecording = false
    var isFinishingRecording = false
    var isPreviewing = true
    var lastRecordedFileURL: URL?
    var lastRecordingStartedHostTime: UInt64?
    var lastRecordingDuration = 0.0
    var lastErrorMessage: String?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var timer: Timer?
    private var destination: URL?
    private var startTime = 0.0
    private var lastFrame = 0.0
    func selectedDeviceInfo() -> CameraDeviceInfo? { CameraDeviceInfo(id: selectedDeviceID!, displayName: selectedDeviceID!) }
    func selectDevice(id: String) {
        require(id == selectedDeviceID)
        isPreviewing = true; lastErrorMessage = nil
    }
    func stopPreview() { isPreviewing = false }
    func startRecording(to url: URL) throws {
        startedFiles += 1; simulatedError = nil
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        self.writer = writer; self.input = input; self.adaptor = adaptor
        destination = url; startTime = ProcessInfo.processInfo.systemUptime
        lastRecordingStartedHostTime = nil; lastRecordedFileURL = nil; lastErrorMessage = nil
        lastRecordingDuration = 0; isRecording = true
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.frame() } }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    private func frame() {
        guard let input, input.isReadyForMoreMediaData, let adaptor, let pool = adaptor.pixelBufferPool else { return }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), Int32(shade), CVPixelBufferGetBytesPerRow(buffer) * 64)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let now = ProcessInfo.processInfo.systemUptime
        if lastRecordingStartedHostTime == nil { startTime = now; lastRecordingStartedHostTime = UInt64(now * 1e9) }
        lastFrame = now - startTime
        require(adaptor.append(buffer, withPresentationTime: CMTime(seconds: lastFrame, preferredTimescale: 600)))
    }
    func stopRecording() {
        guard isRecording, !isFinishingRecording, let writer, let input, let destination else { return }
        timer?.invalidate(); timer = nil; isFinishingRecording = true
        input.markAsFinished()
        writer.finishWriting { Task { @MainActor in
            self.lastRecordingDuration = self.lastFrame + 1.0 / 30
            self.lastErrorMessage = self.simulatedError ?? writer.error?.localizedDescription
            self.isRecording = false; self.isFinishingRecording = false
            self.lastRecordedFileURL = destination
        } }
    }
}

private final class KeyboardHostView: NSView {
    var keys: [UInt16] = []
    override func keyDown(with event: NSEvent) { keys.append(event.keyCode) }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String = "Integration check failed", file: StaticString = #file, line: UInt = #line) {
    if !condition() { fatalError(message, file: file, line: line) }
}

@main
struct SessionIntegration {
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.accessory)
        let host = COTestHostCreate()!
        let bridge = COTestHostBridge(host)!
        let capture = SyntheticCamera()
        let midiName = "CamOrder Session Test " + UUID().uuidString
        let link = LogicTimecodeLink(destinationName: midiName)
        let session = PluginSession(bridge: bridge, camera: CameraCaptureEngine(), captureDevice: capture, logicLink: link)
        COSetSession(bridge, session)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CamOrder-session-test-" + UUID().uuidString + ".camorderstudio")
        defer { try? FileManager.default.removeItem(at: folder) }
        session.store.document = try ProjectDocument.create(at: folder, project: .empty(name: "Session test"))
        func pump(duration: Double, position: Double, playing: Bool, recording: Bool = false) {
            let start = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime - start < duration {
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                require(COTestHostRender(host, position + (playing ? elapsed : 0), playing, recording) == 0)
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
        }
        for pass in 0..<2 {
            let start = 12.0 + Double(pass) * 10
            session.store.armLane(session.store.project.timeline.lanes[0].id)
            require(session.store.hasArmedLane, "Video lane arms for the next take")
            pump(duration: 0.3, position: start, playing: false)
            require(capture.isRecording && session.store.armedBuffer != nil, "Arming starts pre-roll without any editor")
            // No NSHostingView or plugin window is created in this test.
            pump(duration: 2.4, position: start, playing: true, recording: pass == 1)
            require(session.store.pendingTake != nil && capture.isRecording, "Take starts and remains active with no editor")
            require(abs(session.sync.displaySeconds - (start + 2.4)) < 0.12, "Playhead follows host with no editor")
            pump(duration: 0.7, position: start + 2.4, playing: false)
            require(session.store.pendingTake == nil && !session.store.hasArmedLane, "Host Stop saves the take and automatically disarms the lane")
            let clips = session.store.project.timeline.lanes[0].clips
            require(clips.count == pass + 1, "Each take saved as a clip")
            let clip = clips.last!
            require(abs(clip.timelineStartSeconds - start) < 0.1, "Clip begins at host start")
            require(abs(clip.durationSeconds - 2.4) < 0.15, "Clip duration follows host")
            let asset = AVURLAsset(url: folder.appendingPathComponent(clip.videoFile))
            require(asset.duration.seconds > 2.4 && !asset.tracks(withMediaType: .video).isEmpty, "Recorded movie is playable")
            print("PASS: \(pass == 0 ? "Play" : "Record") saves a \(clip.durationSeconds)-second movie at \(clip.timelineStartSeconds) with no plugin editor; playhead follows host")
        }
        session.store.armLane(session.store.project.timeline.lanes[0].id)
        pump(duration: 0.3, position: 32, playing: false)
        pump(duration: 1.2, position: 32, playing: true)
        let lastPosition = session.sync.displaySeconds
        RunLoop.main.run(until: Date().addingTimeInterval(1.2)) // Host stops processing, without a Stop report.
        require(session.sync.hostTimingDelayed && abs(session.sync.displaySeconds - lastPosition) < 0.15, "Missing callbacks hold the playhead instead of running away")
        require(session.store.pendingTake != nil && capture.isRecording, "Missing callbacks preserve active video capture")
        session.store.unarmAllLanes()
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        let finalClip = session.store.project.timeline.lanes[0].clips.last!
        require(session.store.pendingTake == nil && !session.store.hasArmedLane && finalClip.durationSeconds > 2.2, "Manual Stop Take retains video captured during unavailable timing")
        print("PASS: unavailable host timing freezes the playhead, preserves capture, and manual Stop Take saves the captured duration")
        // Exercise the real CoreMIDI virtual destination with AU processing stopped.
        var client = MIDIClientRef(), port = MIDIPortRef()
        require(MIDIClientCreate("CamOrder integration sender" as CFString, nil, nil, &client) == noErr)
        require(MIDIOutputPortCreate(client, "Transport test" as CFString, &port) == noErr)
        defer { MIDIPortDispose(port); MIDIClientDispose(client) }
        let destination = (0..<MIDIGetNumberOfDestinations()).map { MIDIGetDestination($0) }.first { endpoint in
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &name)
            return name?.takeRetainedValue() as String? == midiName
        }!
        func send(_ bytes: [UInt8]) {
            var list = MIDIPacketList()
            withUnsafeMutablePointer(to: &list) { pointer in
                let packet = MIDIPacketListInit(pointer)
                bytes.withUnsafeBufferPointer { data in
                    _ = MIDIPacketListAdd(pointer, MemoryLayout<MIDIPacketList>.size, packet, 0, bytes.count, data.baseAddress!)
                }
                require(MIDISend(port, destination, pointer) == noErr)
            }
        }
        func locate(_ seconds: Int) { send([0xF0,0x7F,0x7F,1,1,0x61,UInt8(seconds / 60),UInt8(seconds % 60),0,0xF7]) }
        func runTimecode(start: Double, duration: Double) {
            let begin = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime - begin < duration {
                let frames = Int((start + ProcessInfo.processInfo.systemUptime - begin) * 30)
                let second = (frames / 30) % 60, minute = frames / 1800, frame = frames % 30
                let values = [frame & 15, frame >> 4, second & 15, second >> 4, minute & 15, minute >> 4, 1, 6]
                for part in 0..<8 {
                    send([0xF1,UInt8(part << 4 | values[part])])
                    RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 120))
                }
            }
        }
        var before = COTransport(); _ = COReadTransport(bridge, &before)
        locate(44)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        require(abs(session.sync.displaySeconds - 44) < 0.01 && session.store.pendingTake == nil, "MTC locate follows host without starting a recording")
        session.store.armLane(session.store.project.timeline.lanes[0].id)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        send([0xF0,0x7F,0x7F,6,2,0xF7]); send([0xF0,0x7F,0x7F,6,6,0xF7])
        runTimecode(start: 44, duration: 2.4)
        require(session.store.pendingTake != nil && session.sync.displaySeconds > 46.3, "MTC starts capture and follows Logic without audio callbacks or an editor")
        send([0xF0,0x7F,0x7F,6,1,0xF7]); locate(44)
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        var after = COTransport(); _ = COReadTransport(bridge, &after)
        require(before.renderCount == after.renderCount, "No audio callback was needed")
        let linkedClip = session.store.project.timeline.lanes[0].clips.last!
        require(session.store.pendingTake == nil && !session.store.hasArmedLane && abs(linkedClip.timelineStartSeconds - 44) < 0.1 && linkedClip.durationSeconds > 2.3, "MMC Stop saves a real timed movie and disarms")
        locate(12)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        require(abs(session.sync.displaySeconds - 12) < 0.01 && session.store.pendingTake == nil, "Stopped backward locate moves the playhead without a false take")
        print("PASS: CoreMIDI Logic Link records and stops a real movie with no AU render calls and no editor; stopped locate follows the host")
        // Host keyboard handoff bypasses the SwiftUI responder subtree.
        let hostView = KeyboardHostView(frame: NSRect(x: 0, y: 0, width: 820, height: 520))
        let editor = NSView(frame: hostView.bounds); hostView.addSubview(editor)
        let forwarder = EditorResizeTarget(); forwarder.view = editor
        for (code, text) in [(UInt16(15), "r"), (UInt16(49), " ")] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
            require(forwarder.forwardTransportKey(event))
        }
        require(hostView.keys == [15,49], "R and Space are delivered exactly once to the host responder")
        print("PASS: R and Space keyboard handoff reaches the host responder exactly once")
        try runEditingRegression()
        try runSyncCalculatorRegression()
        // Visual fixture: actual recorded media and a 4K canvas in the small editor.
        session.store.unarmAllLanes()
        session.store.selectedClipId = linkedClip.id
        session.store.selectedMediaAssetId = linkedClip.mediaAssetId
        session.store.setExportCanvasSize(width: 3840, height: 2160)
        locate(13)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        if CommandLine.arguments.count > 1 {
            let view = Unmanaged<NSView>.fromOpaque(createCamOrderView(bridge)).takeRetainedValue()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 520), styleMask: [.titled,.resizable], backing: .buffered, defer: false)
            window.contentView = view; window.setContentSize(NSSize(width: 820, height: 520)); view.setFrameSize(NSSize(width: 820,height: 520)); window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.7)); view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
            }
            // Drive the actual SwiftUI canvas gesture in this owned test window.
            func findPlayer(_ root: NSView) -> NSView? {
                if String(describing: type(of: root)).contains("PlaybackPlayerNSView") { return root }
                for child in root.subviews { if let found = findPlayer(child) { return found } }
                return nil
            }
            if let playerView = findPlayer(view), let stageClip = session.store.playbackClip(at: session.sync.displaySeconds) {
                let origin = playerView.convert(NSPoint(x: playerView.bounds.midX, y: playerView.bounds.midY), to: nil)
                func mouse(_ type: NSEvent.EventType, dx: CGFloat) {
                    let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: origin.x + dx, y: origin.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
                    NSApp.postEvent(event, atStart: false)
                    while let queued = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.005), inMode: .default, dequeue: true) {
                        NSApp.sendEvent(queued)
                    }
                    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                }
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                mouse(.leftMouseDown, dx: 0)
                for step in 1...10 { mouse(.leftMouseDragged, dx: CGFloat(step * 2)) }
                mouse(.leftMouseUp, dx: 20)
                guard let committed = session.store.clip(id: stageClip.id)?.framing?.offsetX else { fatalError("Canvas drag did not reach the gesture; player bounds \(playerView.bounds), origin \(origin)") }
                require(committed > 0.05, "Dragging the displayed canvas must update that clip")
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                require(session.store.clip(id: stageClip.id)!.framing!.offsetX == committed, "Canvas position cannot snap back after release")
                require(session.store.selectedClipId == stageClip.id, "The canvas selects the clip actually being edited")
                print("PASS: actual SwiftUI canvas drag commits framing to the displayed clip and holds after release")
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let framed = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("editor-framing.png")
                    try bitmap.representation(using: .png, properties: [:])?.write(to: framed)
                }
            } else { preconditionFailure("Expected a visible timeline movie in the real editor") }
            // Exercise the bottom-right grip through actual mouse events. Screen
            // coordinates stay stable while the window's bottom edge moves.
            // Disable AppKit's overlapping native corner tracker in this harness
            // so the click specifically reaches CamOrder's SwiftUI resize grip.
            window.styleMask.remove(.resizable)
            let beforeResize = view.bounds.size
            let grip = NSPoint(x: view.bounds.maxX - 12, y: view.isFlipped ? view.bounds.maxY - 9 : 9)
            let screenOrigin = window.convertPoint(toScreen: view.convert(grip, to: nil))
            func gripMouse(_ type: NSEvent.EventType, fraction: CGFloat) {
                let point = NSPoint(x: screenOrigin.x + 73 * fraction, y: screenOrigin.y - 37 * fraction)
                let event = NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: point), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
                NSApp.postEvent(event, atStart: false)
                while let queued = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.005), inMode: .default, dequeue: true) { NSApp.sendEvent(queued) }
                RunLoop.main.run(until: Date().addingTimeInterval(0.025))
            }
            gripMouse(.leftMouseDown, fraction: 0)
            for step in 1...10 { gripMouse(.leftMouseDragged, fraction: CGFloat(step) / 10) }
            gripMouse(.leftMouseUp, fraction: 1)
            require(abs(view.bounds.width - beforeResize.width - 73) < 2 && abs(view.bounds.height - beforeResize.height - 37) < 2, "Window grip must resize continuously in both dimensions; got \(view.bounds.size)")
            print("PASS: actual bottom-right window grip freely resizes the editor in both dimensions")
            window.styleMask.insert(.resizable)
            window.setContentSize(NSSize(width: 1280, height: 820))
            view.setFrameSize(NSSize(width: 1280, height: 820))
            window.center()
            window.title = "CamOrder Studio 0.5.1"
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            view.layoutSubtreeIfNeeded()
            let fullScreenshot = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("editor-full-session.png")
            // Capture only this test's own window, including its decoded movie layer.
            if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) {
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: fullScreenshot)
            } else if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: fullScreenshot)
            }
            try runEditorInteractionRegression(view: view, window: window, session: session, host: host)
            window.orderOut(nil)
        }
        session.close()
        COTestHostDispose(host)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        try runRestoredSessionRegression()
        try runMultiInputRegression()
    }
}
