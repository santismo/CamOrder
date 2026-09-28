import AppKit
import SwiftUI
import CamOrderStudioCore

private struct PluginDocumentLink: Codable {
    var version = 2
    var path: String
    var bookmark: Data?
    var sourceID: String?
    var timecodeOriginHours: Int?
}

@MainActor
protocol HostedCaptureDevice: AnyObject {
    var selectedDeviceID: String? { get }
    var isRecording: Bool { get }
    var isFinishingRecording: Bool { get }
    var isPreviewing: Bool { get }
    var lastRecordedFileURL: URL? { get }
    var lastRecordingStartedHostTime: UInt64? { get }
    var lastRecordingDuration: Double { get }
    var lastErrorMessage: String? { get }
    func selectedDeviceInfo() -> CameraDeviceInfo?
    func selectDevice(id: String)
    func startRecording(to url: URL) throws
    func stopRecording()
    func stopPreview()
}
extension CameraCaptureEngine: HostedCaptureDevice {}

@MainActor
private final class SourceRecorder {
    let id: String
    let capture: any HostedCaptureDevice
    var template: ProjectStore.ArmedCaptureBuffer?
    var members = Set<String>()
    var ends: [String: Double] = [:]
    var warnings: [String: String] = [:]
    var stopSeconds: Double?
    var completionURL: URL?
    var lastRollingSeconds = 0.0
    init(id: String, capture: any HostedCaptureDevice) { self.id = id; self.capture = capture }
    var active: Bool { capture.isRecording || capture.isFinishingRecording }
}

@MainActor
final class PluginSession: NSObject {
    let store = ProjectStore()
    let sync = LogicSyncEngine(isHosted: true)
    let camera: CameraCaptureEngine
    let inputs: LaneCaptureInputs
    private let captureOverrides: [String: any HostedCaptureDevice]
    private let logicLink: LogicTimecodeLink
    let bridge: OpaquePointer
    private var recorders: [String: SourceRecorder] = [:]
    private var timer: Timer?
    private var revision: UInt64 = 0
    private var lastSeconds = 0.0
    private var transportMonitor = HostTransportMonitor()
    private var lastDisplayTime = 0.0
    private var timingWasDelayed = false
    private var lastDiagnosticTime = 0.0
    private var lastDiagnostic: [String: Any] = [:]
    private var recordingActivity: NSObjectProtocol?
    private var securityScopedURL: URL?
    private var closing = false
    private var restoringPending = false
    private var shutdownHold: PluginSession?

    init(bridge: OpaquePointer, camera: CameraCaptureEngine? = nil, captureDevice: (any HostedCaptureDevice)? = nil,
         captureDevices: [String: any HostedCaptureDevice] = [:], logicLink: LogicTimecodeLink? = nil) {
        self.bridge = bridge
        let camera = camera ?? CameraCaptureEngine(useCaptureHelper: true, automaticallyPreviewsDefaultSource: false)
        self.camera = camera
        var overrides = captureDevices
        if let captureDevice { overrides[captureDevice.selectedDeviceID ?? "test-input"] = captureDevice }
        captureOverrides = overrides
        inputs = LaneCaptureInputs(store: store, discovery: camera, createsEngines: overrides.isEmpty,
            defaultOverride: captureDevice.map { $0.selectedDeviceID ?? "test-input" })
        self.logicLink = logicLink ?? .shared
        super.init()
        CORetainBridge(bridge)
        store.isHosted = true
        store.requiresLaneSource = true
        store.captureInputs = inputs
        store.framingPlayheadSeconds = { [weak sync] in sync?.editorSeconds ?? 0 }
        restore()
        store.onDocumentChange = { [weak self] in self?.saveLink() }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    deinit {
        timer?.invalidate()
        securityScopedURL?.stopAccessingSecurityScopedResource()
        COReleaseBridge(bridge)
    }
    func saveLink() {
        guard !restoringPending, !closing, let document = store.document else { return }
        let url = document.folderURL
        let link = PluginDocumentLink(path: url.path, bookmark: try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
            sourceID: inputs.defaultSourceID, timecodeOriginHours: sync.timecodeOriginHours)
        guard let data = try? JSONEncoder().encode(link) else { return }
        COSetState(bridge, data as CFData)
        revision = COStateRevision(bridge)
    }
    private func restore() {
        revision = COStateRevision(bridge)
        restoringPending = false
        guard let data = COCopyState(bridge) as Data?, !data.isEmpty else { return }
        do {
            let link = try JSONDecoder().decode(PluginDocumentLink.self, from: data)
            var stale = false
            let resolved = link.bookmark.flatMap { try? URL(resolvingBookmarkData: $0, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) }
            let url = resolved ?? URL(fileURLWithPath: link.path)
            securityScopedURL?.stopAccessingSecurityScopedResource()
            securityScopedURL = url.startAccessingSecurityScopedResource() ? url : nil
            var document = try ProjectDocument.open(at: url)
            for index in document.project.timeline.lanes.indices { document.project.timeline.lanes[index].isArmed = false }
            if link.version < 2, document.project.defaultCaptureSourceID == nil { document.project.defaultCaptureSourceID = link.sourceID }
            store.document = document
            sync.timecodeOriginHours = link.timecodeOriginHours ?? 1
            store.lastError = nil
        } catch {
            store.lastError = "The linked video project could not be opened. Use Open Project to locate its .camorderstudio folder. \(error.localizedDescription)"
        }
    }
    private func configureRecorders() {
        inputs.reconcile()
        for id in inputs.sourceIDs where recorders[id] == nil {
            captureOverrides[id]?.selectDevice(id: id)
            if let capture = captureOverrides[id] ?? inputs.engines[id] {
                recorders[id] = SourceRecorder(id: id, capture: capture)
            }
        }
        for id in Array(recorders.keys) where !inputs.sourceIDs.contains(id) {
            guard let state = recorders[id], !state.active, state.members.isEmpty else { continue }
            state.capture.stopPreview(); recorders[id] = nil
        }
    }
    private func tick() {
        if !COBridgeIsAlive(bridge), !closing { close() }
        for state in recorders.values { finishIfReady(state) }
        if closing {
            if !recorders.values.contains(where: \.active) {
                inputs.stopAllPreviews()
                recorders.values.forEach { $0.capture.stopPreview() }
                timer?.invalidate(); timer = nil; shutdownHold = nil
            }
            return
        }
        if revision != COStateRevision(bridge) {
            if recorders.values.contains(where: \.active) {
                restoringPending = true
                recorders.values.forEach { stop($0, at: lastSeconds) }
                return
            }
            restore()
        }
        configureRecorders()
        COSetTransportInterest(bridge, store.hasOpenProject || store.hasArmedLane)
        let active = store.hasArmedLane || recorders.values.contains(where: \.active)
        if active && recordingActivity == nil {
            recordingActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Recording video with Logic Pro")
        } else if !active, let activity = recordingActivity {
            ProcessInfo.processInfo.endActivity(activity); recordingActivity = nil
        }
        var snapshot = COTransport()
        guard COReadTransport(bridge, &snapshot) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let freshAU = snapshot.valid != 0 && now - snapshot.lastRenderSeconds < 0.25
        let timecode = freshAU ? nil : logicLink.snapshot(now: now)
        let usingTimecode = timecode != nil
        sync.setLogicLinkConnected(usingTimecode)
        let origin = Double(sync.timecodeOriginHours) * 3600
        let reportedSeconds = timecode.map { $0.seconds - origin } ?? snapshot.seconds
        let reportedPlaying = timecode?.playing ?? (snapshot.playing != 0)
        let available = usingTimecode || snapshot.valid != 0
        let update = transportMonitor.update(seconds: reportedSeconds, reportedPlaying: reportedPlaying,
            valid: available, reportTime: usingTimecode ? now : snapshot.lastRenderSeconds, now: now)
        let clockOffset = now - snapshot.hostSeconds
        let canAlign = abs(update.seconds - snapshot.seconds) < 0.01 && !usingTimecode && update.playing && snapshot.playing != 0 && !update.timingDelayed && snapshot.valid != 0
            && abs(clockOffset) < 2 && now - snapshot.lastRenderSeconds < 0.1
        let seconds = canAlign ? max(0, snapshot.seconds + clockOffset) : update.seconds
        lastDiagnostic = ["transportSource": usingTimecode ? "Logic Link" : "Audio Unit", "renderCount": snapshot.renderCount,
            "callbackFailures": snapshot.callbackFailures, "reportedSeconds": snapshot.seconds, "callbackAge": now - snapshot.lastRenderSeconds,
            "armedLanes": store.project.timeline.lanes.filter(\.isArmed).count, "inputs": recorders.count,
            "activeTakes": store.pendingTakes.count]
        if store.hasArmedLane && now - lastDiagnosticTime >= 2 { logEvent("armed_transport_status", seconds: seconds); lastDiagnosticTime = now }
        if now - lastDisplayTime >= 1.0 / 30 {
            if freshAU, snapshot.musicalTimeValid != 0 {
                store.receiveHostGrid(seconds: snapshot.seconds, beat: snapshot.beat, tempo: snapshot.tempo)
            }
            sync.receiveHostPosition(seconds: seconds, playing: update.playing && !update.timingDelayed,
                tempo: snapshot.musicalTimeValid != 0 ? snapshot.tempo : .nan,
                available: available && !update.timingDelayed, sourceName: usingTimecode ? "CamOrder Logic Link" : "Logic Audio Unit transport")
            sync.setHostTimingDelayed(update.timingDelayed); lastDisplayTime = now
        }
        if update.timingDelayed != timingWasDelayed {
            logEvent(update.timingDelayed ? "host_timing_delayed_capture_continues" : "host_timing_resumed", seconds: seconds)
            timingWasDelayed = update.timingDelayed
        }
        if update.event == .stopped { store.unarmAllLanes() }
        var startedTake = false
        for state in recorders.values {
            let capture = state.capture
            let lanes = inputs.lanes(for: state.id)
            let armed = lanes.filter(\.isArmed)
            if state.stopSeconds == nil {
                if state.members.contains(where: { store.pendingTakes[$0] != nil }) {
                    if update.event == .stopped {
                        let end = abs(seconds - state.lastRollingSeconds) > 0.25 ? state.lastRollingSeconds : seconds
                        stop(state, at: end)
                    } else if update.event == .relocated {
                        stop(state, at: state.lastRollingSeconds)
                        store.lastError = "Takes saved before Logic moved backward. Arm the lanes again for the next take."
                    } else {
                        for id in state.members where store.pendingTakes[id] != nil && !armed.contains(where: { $0.id == id }) && state.ends[id] == nil {
                            var end = seconds
                            if update.timingDelayed, let take = store.pendingTakes[id] {
                                end = max(seconds, take.startSeconds + now - Double(take.hostTime) / 1e9 - take.trimInSeconds)
                                state.warnings[id] = "Logic timing was unavailable at Stop Take; the end uses the captured video duration."
                            }
                            state.ends[id] = end; store.captureEndSeconds[id] = end
                        }
                    }
                }
                if update.playing && reportedPlaying, seconds >= state.lastRollingSeconds - 0.25 { state.lastRollingSeconds = seconds }
            }
            for id in Array(state.members) where store.pendingTakes[id] == nil && !armed.contains(where: { $0.id == id }) {
                store.discardArmedBuffer(laneID: id); state.members.remove(id)
            }
            if !armed.isEmpty, state.template == nil, !state.active, capture.isPreviewing {
                let first = armed[0]
                store.startArmedBuffer(cameraDeviceId: state.id, cameraDisplayName: inputs.name(for: state.id), laneID: first.id)
                if let buffer = store.armedBuffers[first.id], let url = store.pendingArmedBufferURL(laneID: first.id) {
                    state.template = buffer; state.members.insert(first.id); state.completionURL = nil
                    do { try capture.startRecording(to: url) }
                    catch { store.cancelPendingTake(message: "\(first.name): \(error.localizedDescription)", laneID: first.id); state.template = nil; state.members.remove(first.id) }
                }
            }
            if !armed.isEmpty, state.template == nil, !state.active, !capture.isPreviewing, let error = capture.lastErrorMessage {
                armed.forEach { store.disarmLane($0.id) }
                store.lastError = "\(inputs.name(for: state.id)): \(error)"
            }
            if var template = state.template, state.stopSeconds == nil, !capture.isFinishingRecording {
                if let firstFrame = capture.lastRecordingStartedHostTime { template.recordingStartedHostTime = firstFrame; state.template = template }
                for lane in armed where store.pendingTakes[lane.id] == nil {
                    if store.armedBuffers[lane.id] == nil {
                        var buffer = template; buffer.laneId = lane.id
                        buffer.clipId = "take_" + UUID().uuidString
                        buffer.bufferStartHostTime = DispatchTime.now().uptimeNanoseconds
                        store.armedBuffers[lane.id] = buffer; state.members.insert(lane.id)
                    }
                    if let firstFrame = template.recordingStartedHostTime { store.markArmedBufferRecordingStarted(hostTime: firstFrame, laneID: lane.id) }
                    if update.playing && reportedPlaying && reportedSeconds >= 0 && !update.timingDelayed,
                       let buffer = store.armedBuffers[lane.id], let firstFrame = buffer.recordingStartedHostTime {
                        let startSeconds = timecode.map { $0.startSeconds - origin } ?? snapshot.startSeconds
                        let startHost = timecode?.startHostTime ?? snapshot.startHostSeconds
                        let captureHost = max(startHost, Double(firstFrame) / 1e9, Double(buffer.bufferStartHostTime) / 1e9, startHost - startSeconds)
                        let start = max(0, startSeconds + captureHost - startHost)
                        store.startTakeRegion(at: .from(seconds: start, frameRate: store.project.frameRate), cameraDeviceId: state.id,
                            cameraDisplayName: inputs.name(for: state.id), preciseSeconds: start, captureHostSeconds: captureHost, laneID: lane.id)
                        state.lastRollingSeconds = max(start, seconds); startedTake = true
                        logEvent("take_started", seconds: start, source: state.id, lane: lane.id)
                    }
                }
            }
            // A lane can stop independently while other lanes share this source.
            // Its closed region is saved as soon as the shared movie finalizes.
            if armed.isEmpty, state.active, state.stopSeconds == nil { stop(state, at: seconds) }
        }
        if startedTake {
            transportMonitor = HostTransportMonitor()
            _ = transportMonitor.update(seconds: reportedSeconds, reportedPlaying: reportedPlaying, valid: available,
                reportTime: usingTimecode ? now : snapshot.lastRenderSeconds, now: now)
        }
        lastSeconds = seconds
    }
    private func stop(_ state: SourceRecorder, at seconds: Double) {
        guard state.stopSeconds == nil else { return }
        state.stopSeconds = seconds
        for id in state.members {
            if store.pendingTakes[id] != nil, state.ends[id] == nil { state.ends[id] = seconds; store.captureEndSeconds[id] = seconds }
            store.disarmLane(id)
        }
        state.capture.stopRecording()
        logEvent("input_stop", seconds: seconds, source: state.id)
    }
    private func finishIfReady(_ state: SourceRecorder) {
        let capture = state.capture
        guard let url = capture.lastRecordedFileURL, url != state.completionURL, !state.active else { return }
        state.completionURL = url
        let unexpectedlyStopped = state.stopSeconds == nil && state.members.contains { store.pendingTakes[$0] != nil }
        logEvent("capture_finalized", seconds: state.stopSeconds ?? lastSeconds, source: state.id)
        for id in state.members {
            if store.pendingTakes[id] != nil {
                let end = state.ends[id] ?? state.stopSeconds ?? lastSeconds
                store.finishTakeRegion(at: .from(seconds: end, frameRate: store.project.frameRate),
                    warnings: [capture.lastErrorMessage, state.warnings[id]].compactMap { $0 }, preciseSeconds: end,
                    actualMediaDuration: capture.lastRecordingDuration, laneID: id)
            }
            store.discardArmedBuffer(laneID: id); store.captureEndSeconds[id] = nil
            if capture.lastErrorMessage != nil || unexpectedlyStopped || closing { store.disarmLane(id) }
        }
        if !store.project.media.contains(where: { store.absoluteURL(for: $0.relativePath) == url }) { try? FileManager.default.removeItem(at: url) }
        if let error = capture.lastErrorMessage { store.lastError = "\(inputs.name(for: state.id)): \(error)" }
        else if unexpectedlyStopped { store.lastError = "\(inputs.name(for: state.id)) stopped recording. Other inputs continue. Reconnect it and restart its preview." }
        state.template = nil; state.members.removeAll(); state.ends.removeAll(); state.warnings.removeAll(); state.stopSeconds = nil
        saveLink()
    }
    private func logEvent(_ event: String, seconds: Double, source: String? = nil, lane: String? = nil) {
        guard let document = store.document else { return }
        let url = document.folderURL.appendingPathComponent("logs/capture-events.jsonl")
        var payload = lastDiagnostic
        payload["event"] = event; payload["timelineSeconds"] = seconds
        payload["source"] = source; payload["lane"] = lane
        payload["date"] = ISO8601DateFormatter().string(from: Date())
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard var data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        data.append(0x0a)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            do { try handle.seekToEnd(); try handle.write(contentsOf: data) } catch { }
        }
    }
    func close() {
        guard !closing else { return }
        closing = true
        COSetTransportInterest(bridge, false)
        if let activity = recordingActivity { ProcessInfo.processInfo.endActivity(activity); recordingActivity = nil }
        shutdownHold = self
        recorders.values.forEach { stop($0, at: lastSeconds) }
        store.unarmAllLanes()
        store.saveProject()
    }
}

@MainActor
final class EditorResizeTarget {
    weak var view: NSView?
    private var forwardingKey = false
    func forwardTransportKey(_ event: NSEvent) -> Bool {
        guard !forwardingKey, let view, let hostView = view.superview else { return false }
        forwardingKey = true
        defer { forwardingKey = false }
        // Pass the original key straight to the host's responder chain, bypassing
        // SwiftUI's focus handling. Never simulate a take or a moving host clock.
        hostView.keyDown(with: event)
        return true
    }
    func resize(to size: CGSize) {
        guard let view else { return }
        let desired = CGSize(width: max(720, size.width), height: max(360, size.height))
        if let window = view.window, let content = window.contentView,
           view.bounds.width > content.bounds.width * 0.7, view.bounds.height > content.bounds.height * 0.7 {
            let chrome = CGSize(width: max(0, content.bounds.width - view.bounds.width), height: max(0, content.bounds.height - view.bounds.height))
            let contentRect = NSRect(origin: .zero, size: CGSize(width: desired.width + chrome.width, height: desired.height + chrome.height))
            var frame = window.frameRect(forContentRect: contentRect)
            frame.origin = CGPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
            window.setFrame(frame, display: true)
        }
        view.setFrameSize(desired)
    }
}

@MainActor
private final class ResizableEditorView<Content: View>: NSHostingView<Content> {
    var onProjectCommand: ((NSEvent) -> Bool)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.isKeyWindow == true else { return super.performKeyEquivalent(with: event) }
        let isSave = event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command
            && event.charactersIgnoringModifiers?.lowercased() == "s"
        if let responder = window?.firstResponder, (responder is NSTextView || responder is NSTextField), !isSave {
            return super.performKeyEquivalent(with: event)
        }
        if onProjectCommand?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, let content = window.contentView,
              bounds.width > content.bounds.width * 0.7, bounds.height > content.bounds.height * 0.7 else { return }
        // Only adjust a dedicated editor window, never the host's main window.
        let chromeWidth = max(0, content.bounds.width - bounds.width)
        let chromeHeight = max(0, content.bounds.height - bounds.height)
        window.styleMask.insert(.resizable)
        window.contentMinSize = CGSize(width: 720 + chromeWidth, height: 360 + chromeHeight)
        window.contentMaxSize = CGSize(width: 4096, height: 2160)
    }
}

@_cdecl("CamOrderEnsureSession")
func ensureCamOrderSession(_ pointer: OpaquePointer) {
    MainActor.assumeIsolated {
        guard COBridgeIsAlive(pointer), COGetSession(pointer) == nil else { return }
        COSetSession(pointer, PluginSession(bridge: pointer))
    }
}

@_cdecl("CamOrderCreateView")
func createCamOrderView(_ pointer: OpaquePointer) -> UnsafeMutableRawPointer {
    let address: UInt = MainActor.assumeIsolated {
        let session: PluginSession
        if let existing = COGetSession(pointer) { session = existing.takeUnretainedValue() as! PluginSession }
        else {
            session = PluginSession(bridge: pointer)
            COSetSession(pointer, session)
        }
        let resizeTarget = EditorResizeTarget()
        let view = ResizableEditorView(rootView: StudioShellView(syncEngine: session.sync, cameraEngine: session.camera,
            resizeEditor: { resizeTarget.resize(to: $0) },
            hostTransportKey: { resizeTarget.forwardTransportKey($0) }).environmentObject(session.store).preferredColorScheme(.dark))
        view.sizingOptions = []
        view.onProjectCommand = { [weak session] event in
            guard let session else { return false }
            return session.store.handleProjectShortcut(event, at: session.sync.editorSeconds)
        }
        resizeTarget.view = view
        view.frame = NSRect(x: 0, y: 0, width: 1280, height: 820)
        view.autoresizingMask = [.width, .height]
        return UInt(bitPattern: Unmanaged.passRetained(view).toOpaque())
    }
    return UnsafeMutableRawPointer(bitPattern: address)!
}

@_cdecl("CamOrderCloseSession")
func closeCamOrderSession(_ session: CFTypeRef) {
    MainActor.assumeIsolated { (session as? PluginSession)?.close() }
}
