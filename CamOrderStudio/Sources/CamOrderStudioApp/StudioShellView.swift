import AVFoundation
import CamOrderStudioCore
import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

@MainActor
final class EditPlaybackController: ObservableObject {
    @Published var isEditMode = false
    @Published var isPlaying = false
    @Published var playheadSeconds: Double = 0

    private var timer: Timer?
    private var lastTickDate = Date()
    private var audioPlayer: AVPlayer?
    private var audioURL: URL?

    deinit {
        timer?.invalidate()
        audioPlayer?.pause()
    }

    func seconds(sync: LogicSyncEngine) -> Double {
        sync.isHosted ? sync.editorSeconds : (isEditMode ? playheadSeconds : sync.displaySeconds)
    }
    func playing(sync: LogicSyncEngine) -> Bool {
        sync.isHosted ? sync.isTransportRolling : (isEditMode ? isPlaying : sync.isTransportRolling)
    }

    func togglePlay(duration: Double) {
        isPlaying ? pause() : play(duration: duration)
    }

    func play(duration: Double) {
        isEditMode = true
        if duration > 0 {
            playheadSeconds = min(max(0, duration), playheadSeconds)
        }
        isPlaying = true
        lastTickDate = Date()
        startTimer(duration: duration)
        audioPlayer?.play()
    }

    func pause() {
        isPlaying = false
        timer?.invalidate()
        timer = nil
        audioPlayer?.pause()
    }

    func stop() {
        pause()
        seek(to: 0, audioOffsetSeconds: 0)
    }

    func seek(to seconds: Double, audioOffsetSeconds: Double) {
        playheadSeconds = max(0, seconds)
        seekAudio(audioOffsetSeconds: audioOffsetSeconds)
    }

    func step(by seconds: Double, duration: Double, audioOffsetSeconds: Double) {
        let upperBound = duration > 0 ? max(0, duration) : Double.greatestFiniteMagnitude
        let next = min(upperBound, max(0, playheadSeconds + seconds))
        seek(to: next, audioOffsetSeconds: audioOffsetSeconds)
    }

    func configureMasterAudio(url: URL?, audioOffsetSeconds: Double) {
        guard audioURL != url else {
            seekAudio(audioOffsetSeconds: audioOffsetSeconds)
            return
        }
        audioURL = url
        audioPlayer = url.map { AVPlayer(url: $0) }
        seekAudio(audioOffsetSeconds: audioOffsetSeconds)
        if isPlaying {
            audioPlayer?.play()
        }
    }

    private func startTimer(duration: Double) {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                let now = Date()
                let delta = now.timeIntervalSince(self.lastTickDate)
                self.lastTickDate = now
                self.playheadSeconds = min(max(duration, 0), self.playheadSeconds + delta)
                if duration > 0, self.playheadSeconds >= duration {
                    self.pause()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func seekAudio(audioOffsetSeconds: Double) {
        let audioSeconds = max(0, playheadSeconds - audioOffsetSeconds)
        audioPlayer?.seek(to: CMTime(seconds: audioSeconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

struct StudioShellView: View {
    @EnvironmentObject private var store: ProjectStore
    @State private var syncEngine = LogicSyncEngine()
    @State private var cameraEngine = CameraCaptureEngine()
    @State private var editPlayback = EditPlaybackController()
    @State private var timelineZoom: Double = 18
    @StateObject private var captureRegionController = CaptureRegionController()
    @State private var stageFraction = 0.58
    @State private var monitorFraction = 0.64
    @State private var showLive = true
    @State private var showTimeline = true
    @State private var showSync = false
    @State private var resizeStart: CGSize?
    @State private var showInspector = false
    @State private var showMedia = false
    @State private var showLogicLink = false
    private let resizeEditor: ((CGSize) -> Void)?
    private let hostTransportKey: ((NSEvent) -> Bool)?

    init(syncEngine: LogicSyncEngine? = nil, cameraEngine: CameraCaptureEngine? = nil, resizeEditor: ((CGSize) -> Void)? = nil, hostTransportKey: ((NSEvent) -> Bool)? = nil) {
        self.resizeEditor = resizeEditor
        self.hostTransportKey = hostTransportKey
        _syncEngine = State(initialValue: syncEngine ?? LogicSyncEngine())
        _cameraEngine = State(initialValue: cameraEngine ?? CameraCaptureEngine())
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                TransportSyncBar(syncEngine: syncEngine, cameraEngine: cameraEngine, editPlayback: editPlayback, compact: true, recordInHost: {
                    editPlayback.pause(); editPlayback.isEditMode = false
                    sendHostKey(15, text: "r")
                }, playInHost: { sendHostKey(49, text: " ") })
                HStack(spacing: 12) {
                    Button { showMedia.toggle() } label: { Label("Media", systemImage: "film.stack") }
                        .popover(isPresented: $showMedia) {
                            MediaBrowserView().frame(width: 340, height: 430).environmentObject(store)
                        }
                    Button { showSync.toggle() } label: { Label("Sync", systemImage: "slider.horizontal.3") }
                        .popover(isPresented: $showSync) { VideoSyncPanel(calculator: store.syncCalculator).environmentObject(store) }
                    Spacer()
                    Menu {
                        Toggle("Live Input", isOn: $showLive)
                        Toggle("Timeline", isOn: $showTimeline)
                        Divider()
                        Button("Reset panel sizes") { stageFraction = 0.58; monitorFraction = 0.64; showLive = true; showTimeline = true }
                        if syncEngine.isHosted {
                            Divider()
                            Button("Optional transport fallback…") { showLogicLink = true }
                        }
                    } label: { Label("View", systemImage: "rectangle.split.2x2") }
                    .fixedSize()
                    .popover(isPresented: $showLogicLink) { LogicLinkSetupView(syncEngine: syncEngine) }
                    Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                        .popover(isPresented: $showInspector) {
                            ScrollView { InspectorPane(syncEngine: syncEngine, cameraEngine: cameraEngine, captureRegionController: captureRegionController) }
                                .frame(width: 350, height: min(600, max(340, geometry.size.height - 30))).environmentObject(store)
                        }
                }
                .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 8)
                Group {
                    if showTimeline {
                        StudioSplit(axis: .vertical, fraction: $stageFraction, minimum: 90) {
                            monitors
                        } second: {
                            TimelineView(syncEngine: syncEngine, editPlayback: editPlayback, secondsToPixels: timelineZoom, timelineZoom: $timelineZoom, compact: true)
                        }
                    } else { monitors }
                }.padding(.horizontal, 8)
                HStack {
                    Text("CamOrder · AU 0.6.0").font(.system(size: 9)).foregroundStyle(.tertiary)
                    Spacer()
                    if let resizeEditor {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .frame(width: 24, height: 18).contentShape(Rectangle())
                            .help("Drag to resize the plug-in window freely")
                            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                .onChanged { value in
                                    if resizeStart == nil { resizeStart = geometry.size }
                                    guard let start = resizeStart else { return }
                                    resizeEditor(CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height))
                                }.onEnded { _ in resizeStart = nil })
                    }
                }.padding(.leading, 12)
            }
        }
        .background(Color(red: 0.055, green: 0.06, blue: 0.075))
        .preferredColorScheme(.dark)
        .tint(Color(red: 0.34, green: 0.79, blue: 0.72))
        .background(EditAudioObserver(editPlayback: editPlayback, configure: configureEditAudio).frame(width: 0, height: 0))
        .alert("CamOrder Studio", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.lastError ?? "")
        }
        .onAppear {
            syncEngine.startMTCInput()
            syncEngine.setTempoBPM(store.tempoBPM)
            store.framingPlayheadSeconds = { editPlayback.seconds(sync: syncEngine) }
        }
        .onDisappear { store.cancelRegionEdit(); if syncEngine.isHosted { syncEngine.followHost() }; editPlayback.pause() }
        .onChange(of: store.tempoBPM) { bpm in
            syncEngine.setTempoBPM(bpm)
        }
        .onChange(of: syncEngine.detectedTempoBPM) { bpm in
            if !syncEngine.isHosted, let bpm { store.receiveHostGrid(seconds: 0, beat: 0, tempo: bpm) }
        }
        .onChange(of: store.project.audio.masteredAudioFile) { _ in
            configureEditAudio()
        }
        .onChange(of: store.project.audio.audioOffsetSeconds) { _ in
            configureEditAudio()
        }
        .onChange(of: store.armedLaneId) { lane in
            if syncEngine.isHosted, lane != nil {
                editPlayback.pause()
                editPlayback.isEditMode = false
            }
        }
        .onDeleteCommand {
            store.deleteSelectedClip()
        }
        .background(
            KeyEventMonitorView { event in
                handleKey(event)
            }
            .frame(width: 0, height: 0)
        )
    }

    @ViewBuilder private var monitors: some View {
        if showLive {
            StudioSplit(axis: .horizontal, fraction: $monitorFraction, minimum: 160) {
                PlaybackPreviewPane(syncEngine: syncEngine, editPlayback: editPlayback)
            } second: {
                if let inputs = store.captureInputs {
                    MultiInputPreviewPane(inputs: inputs, discovery: cameraEngine)
                } else {
                    VStack(spacing: 0) {
                        LiveSourceHeader(camera: cameraEngine)
                        LiveInputPreview(cameraEngine: cameraEngine, captureRegionController: captureRegionController)
                    }
                }
            }
        } else { PlaybackPreviewPane(syncEngine: syncEngine, editPlayback: editPlayback) }
    }

    private func sendHostKey(_ code: UInt16, text: String) {
        syncEngine.followHost()
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: NSApp.keyWindow?.windowNumber ?? 0, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) {
            _ = hostTransportKey?(event)
        }
    }

    private func configureEditAudio() {
        guard !syncEngine.isHosted, editPlayback.isEditMode,
              let relativePath = store.project.audio.masteredAudioFile,
              let url = store.absoluteURL(for: relativePath) else {
            editPlayback.configureMasterAudio(url: nil, audioOffsetSeconds: store.project.audio.audioOffsetSeconds)
            return
        }
        editPlayback.configureMasterAudio(url: url, audioOffsetSeconds: store.project.audio.audioOffsetSeconds)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if syncEngine.isHosted, modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           event.keyCode == 15 || event.keyCode == 49 {
            if event.isARepeat { return true }
            syncEngine.followHost(); editPlayback.pause(); editPlayback.isEditMode = false
            return hostTransportKey?(event) ?? false
        }
        if store.handleProjectShortcut(event, at: activePlayheadSeconds) { return true }
        guard !modifierFlags.contains(.command), !modifierFlags.contains(.control), !modifierFlags.contains(.option) else { return false }

        if event.keyCode == 51 || event.keyCode == 117 {
            store.deleteSelectedClip()
            return true
        }

        if !modifierFlags.contains(.command),
           !modifierFlags.contains(.option),
           !modifierFlags.contains(.control),
           event.charactersIgnoringModifiers?.lowercased() == "m" {
            store.insertAutomationMarker(at: activePlayheadSeconds)
            return true
        }

        if syncEngine.isHosted {
            if event.keyCode == 8 { store.cutSelectedClip(at: activePlayheadSeconds); return true }
            if !syncEngine.isTransportRolling && (event.keyCode == 123 || event.keyCode == 124) {
                syncEngine.preview(at: activePlayheadSeconds + (event.keyCode == 123 ? -store.gridSeconds : store.gridSeconds))
                return true
            }
            return false
        }
        guard editPlayback.isEditMode else { return false }

        switch event.keyCode {
        case 49:
            editPlayback.togglePlay(duration: max(store.project.timeline.durationSeconds, editPlayback.playheadSeconds + 10))
            return true
        case 8:
            store.cutSelectedClip(at: editPlayback.playheadSeconds)
            return true
        case 123:
            editPlayback.step(by: -store.gridSeconds, duration: store.project.timeline.durationSeconds, audioOffsetSeconds: store.project.audio.audioOffsetSeconds)
            return true
        case 124:
            editPlayback.step(by: store.gridSeconds, duration: max(store.project.timeline.durationSeconds, editPlayback.playheadSeconds + store.gridSeconds), audioOffsetSeconds: store.project.audio.audioOffsetSeconds)
            return true
        case 126:
            store.makeGridDivisionSmaller()
            return true
        case 125:
            store.makeGridDivisionLarger()
            return true
        default:
            return false
        }
    }

    private var activePlayheadSeconds: Double {
        editPlayback.seconds(sync: syncEngine)
    }
}

private struct StudioWindowBackground: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
            Color(nsColor: .underPageBackgroundColor)
                .opacity(0.74)
            Color.black
                .opacity(0.30)
        }
        .ignoresSafeArea()
    }
}

private struct StudioPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background {
                ZStack {
                    Rectangle()
                        .fill(.regularMaterial)
                    Color.black.opacity(0.22)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.42), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.10), radius: 10, x: 0, y: 5)
    }
}

private struct StatusPill: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(tint.opacity(0.12), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(tint.opacity(0.24), lineWidth: 1)
            }
    }
}

private struct SymbolToolButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(help)
    }
}

private struct KeyEventMonitorView: NSViewRepresentable {
    let onKeyDown: (NSEvent) -> Bool

    func makeNSView(context: Context) -> KeyMonitorNSView {
        let view = KeyMonitorNSView()
        view.onKeyDown = onKeyDown
        return view
    }

    func updateNSView(_ nsView: KeyMonitorNSView, context: Context) {
        nsView.onKeyDown = onKeyDown
    }
}

private final class KeyMonitorNSView: NSView {
    var onKeyDown: ((NSEvent) -> Bool)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeMonitor()
        } else if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window, self.window?.isKeyWindow == true else { return event }
                let isSave = event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command
                    && event.charactersIgnoringModifiers?.lowercased() == "s"
                guard !Self.isTextInputActive || isSave else { return event }
                return self.onKeyDown?(event) == true ? nil : event
            }
        }
    }

    deinit {
        removeMonitor()
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private static var isTextInputActive: Bool {
        guard let responder = NSApplication.shared.keyWindow?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField
    }
}

private struct LogicLinkSetupView: View {
    @EnvironmentObject private var store: ProjectStore
    @ObservedObject var syncEngine: LogicSyncEngine
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Optional transport fallback").font(.headline)
            Text("Normal use needs only CamOrder enabled on Stereo Out. Use this fallback only if Logic stops sending AU timing; existing connections remain compatible.").font(.caption).foregroundStyle(.secondary)
            Text(syncEngine.logicLinkConnected ? "Receiving Logic timecode" : "Waiting for timecode").foregroundStyle(syncEngine.logicLinkConnected ? .green : .orange)
            Text("Optional setup:")
            Text("1. Open File → Project Settings → Synchronization → MIDI.")
            Text("2. Set a Destination to CamOrder Logic Link. Enable MTC and MMC on that row, plus Transmit MIDI Machine Control.")
            Text("3. Keep Logic in Internal Sync. Press Play or R, then Stop. The connection indicator turns green.")
            Picker("Logic project start", selection: $syncEngine.timecodeOriginHours) {
                ForEach(0..<24) { hour in Text(String(format: "%02d:00:00:00", hour)).tag(hour) }
            }
            Text("Match Logic’s bar-1 SMPTE time in Synchronization → General; the default is 01:00:00:00. This is the project origin, not a video-delay adjustment.").font(.caption).foregroundStyle(.secondary)
            Text("R and Record start Logic recording. Space and Play control Logic. Scrub the CamOrder ruler while stopped to preview an edit; Logic takes over on its next move or Play.").font(.caption)
            Text("While stopped, CamOrder follows position reports sent by Logic. If a move is not sent, press Stop twice to send a Locate command (enable that option in Logic’s MIDI Sync settings).").font(.caption).foregroundStyle(.secondary)
        }.padding(18).frame(width: 420)
            .onChange(of: syncEngine.timecodeOriginHours) { _ in store.onDocumentChange?() }
    }
}

private struct TransportSyncBar: View {
    @ObservedObject var syncEngine: LogicSyncEngine
    @ObservedObject var cameraEngine: CameraCaptureEngine
    @ObservedObject var editPlayback: EditPlaybackController
    @EnvironmentObject private var store: ProjectStore
    @StateObject private var renderEngine = RenderExportEngine()
    @State private var isRendering = false
    @State private var showsSaved = false
    var compact = false
    var recordInHost: (() -> Void)?
    var playInHost: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "video").font(.system(size: 18, weight: .medium)).foregroundStyle(.tint)
                Text("CamOrder").font(.system(size: 16, weight: .semibold))
                Menu {
                    Button("New Project…") { store.createProject() }
                    Button("Open Project…") { store.openProject() }
                    Divider()
                    Button("Save") { store.saveProjectManually() }.disabled(!store.hasOpenProject)
                    Button("Save a Copy…") { store.saveProjectAs() }.disabled(!store.hasOpenProject)
                    if let url = store.lastExportURL { Button("Show last export") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                } label: { Text(store.document?.project.name ?? "Open a project").lineLimit(1) }
                .menuStyle(.borderlessButton).frame(maxWidth: 240, alignment: .leading)
                .disabled(cameraEngine.isRecording || cameraEngine.isFinishingRecording || store.hasCaptureActivity)
                Spacer()
                if isRendering { ProgressView(value: renderEngine.progress).frame(width: 70) }
                Button { store.saveProjectManually() } label: {
                    Label(showsSaved ? "Saved" : "Save", systemImage: showsSaved ? "checkmark" : "square.and.arrow.down")
                }
                .disabled(!store.hasOpenProject)
                .help("Save CamOrder project (⌘S). Edits also save automatically.")
                Button { renderProject() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.hasOpenProject || isRendering || cameraEngine.isRecording || cameraEngine.isFinishingRecording || store.hasCaptureActivity)
            }
            HStack(spacing: 10) { transportStatus; Spacer(minLength: 4); editControls }
        }
        .controlSize(.small).padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
        .task(id: store.lastManualSaveAt) {
            guard store.lastManualSaveAt != nil else { return }
            showsSaved = true
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled { showsSaved = false }
        }
        .onAppear {
            guard !syncEngine.isHosted else { return }
            startArmedBufferIfNeeded()
        }
        .onChange(of: cameraEngine.lastRecordedFileURL) { recordedURL in
            guard !syncEngine.isHosted else { return }
            guard recordedURL != nil else { return }
            if let stopTimecode = store.pendingStopTimecode {
                let warning = cameraEngine.lastErrorMessage.map { [$0] } ?? []
                store.finishTakeRegion(at: stopTimecode, warnings: warning, actualMediaDuration: cameraEngine.lastRecordingDuration)
                store.unarmAllLanes()
            } else {
                store.discardArmedBuffer()
            }
        }
        .onChange(of: cameraEngine.lastRecordingStartedHostTime) { hostTime in
            guard !syncEngine.isHosted else { return }
            guard let hostTime else { return }
            store.markArmedBufferRecordingStarted(hostTime: hostTime)
        }
        .onChange(of: syncEngine.isTransportRolling) { isRolling in
            guard !syncEngine.isHosted else { return }
            guard !editPlayback.isEditMode else { return }
            if isRolling {
                guard store.pendingTake == nil, store.hasArmedLane, store.document != nil else { return }
                startVideoTake()
            } else if store.pendingTake != nil {
                stopVideoTake()
            }
        }
        .onChange(of: store.armedLaneId) { armedLaneId in
            guard !syncEngine.isHosted else { return }
            if armedLaneId != nil {
                startArmedBufferIfNeeded()
            } else if store.armedBuffer != nil, store.pendingTake == nil {
                cameraEngine.stopRecording()
                store.discardArmedBuffer()
            }
        }
    }

    @ViewBuilder private var transportStatus: some View {
        Text(formatTimelineSeconds(activePlayheadSeconds, frameRate: store.project.frameRate, format: .logicTime))
            .font(.system(size: 18, weight: .medium, design: .monospaced)).monospacedDigit()
        Circle().fill(store.pendingTake != nil ? Color.red : (store.hasArmedLane ? .orange : .secondary)).frame(width: 6, height: 6)
        Text(store.pendingTake != nil ? "Recording \(store.pendingTakes.count)" : (store.hasArmedLane ? "Armed" : "Ready"))
            .font(.caption).foregroundStyle(.secondary)
        if syncEngine.hostTimingDelayed {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                .help("Waiting for Logic timing. Keep CamOrder enabled on Stereo Out. An active capture continues until a confirmed Stop or Stop Take.")
        }
        if store.hasArmedLane || store.hasCaptureActivity {
            Button(store.pendingTake == nil ? "Disarm" : "Stop Take") { store.unarmAllLanes() }
        }
    }
    @ViewBuilder private var editControls: some View {
        if !syncEngine.isHosted {
            Picker("Transport", selection: $editPlayback.isEditMode) {
                Text("Sync").tag(false); Text("Edit").tag(true)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 100)
        }
        if syncEngine.isHosted, let recordInHost {
            Button(action: recordInHost) { Image(systemName: "record.circle").foregroundStyle(.red) }
                .help("Record in Logic (R)")
        }
        Button {
            if syncEngine.isHosted { syncEngine.followHost(); playInHost?() }
            else { editPlayback.togglePlay(duration: max(store.project.timeline.durationSeconds, activePlayheadSeconds + 10)) }
        } label: {
            Image(systemName: (editPlayback.playing(sync: syncEngine)) ? "pause.fill" : "play.fill")
        }.disabled(!store.hasOpenProject).help("Play / pause")
        Button {
            if syncEngine.isHosted { syncEngine.followHost(); if syncEngine.isTransportRolling { playInHost?() } }
            else { editPlayback.stop() }
        } label: { Image(systemName: "stop.fill") }.help("Stop")
        Button { store.undoProjectChange() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!store.canUndo).help("Undo")
        Button { store.redoProjectChange() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!store.canRedo).help("Redo")
    }

    private var activePlayheadSeconds: Double {
        editPlayback.seconds(sync: syncEngine)
    }

    private func startVideoTake() {
        let startTimecode = syncEngine.transportStartTimecode ?? syncEngine.currentTimecode
        let selectedDevice = cameraEngine.selectedDeviceInfo()
        store.startTakeRegion(
            at: startTimecode,
            observedTimecode: syncEngine.currentTimecode,
            cameraDeviceId: cameraEngine.selectedDeviceID,
            cameraDisplayName: selectedDevice?.displayName
        )
        guard store.pendingTake != nil, let url = store.pendingRecordingURL() else { return }
        guard !cameraEngine.isRecording else { return }
        do {
            try cameraEngine.startRecording(to: url)
        } catch {
            store.finishTakeRegion(at: syncEngine.currentTimecode, warnings: [error.localizedDescription])
            cameraEngine.markRecordingStoppedForUnsupportedSource()
        }
    }

    private func startArmedBufferIfNeeded() {
        guard store.pendingTake == nil, store.hasArmedLane, store.document != nil, !cameraEngine.isRecording else { return }
        let selectedDevice = cameraEngine.selectedDeviceInfo()
        store.startArmedBuffer(cameraDeviceId: cameraEngine.selectedDeviceID, cameraDisplayName: selectedDevice?.displayName)
        guard let url = store.pendingArmedBufferURL() else { return }
        do {
            try cameraEngine.startRecording(to: url)
        } catch {
            store.discardArmedBuffer()
            cameraEngine.markRecordingStoppedForUnsupportedSource()
            store.lastError = error.localizedDescription
        }
    }

    private func stopVideoTake() {
        let stopTimecode = syncEngine.stopTimecodeForPlacement()
        store.pendingStopTimecode = stopTimecode
        store.unarmAllLanes()
        cameraEngine.stopRecording()
        if !cameraEngine.isFinishingRecording {
            let warning = cameraEngine.lastErrorMessage.map { [$0] } ?? []
            store.finishTakeRegion(at: stopTimecode, warnings: warning, actualMediaDuration: cameraEngine.lastRecordingDuration)
            store.unarmAllLanes()
        }
    }

    private func renderProject() {
        guard let document = store.document else { return }
        let panel = NSSavePanel()
        panel.title = "Render CamOrder Studio Video"
        panel.nameFieldStringValue = "\(document.project.name).\(document.project.exportSettings.container.rawValue)"
        panel.allowedContentTypes = [.quickTimeMovie, .mpeg4Movie, UTType(filenameExtension: "m4v") ?? .mpeg4Movie]
        panel.canCreateDirectories = true
        let selection = ExportRangeSelection(project: document.project, selectedClip: store.selectedClip(), playhead: activePlayheadSeconds)
        let accessory = NSHostingView(rootView: ExportRangeAccessory(selection: selection))
        accessory.frame = NSRect(x: 0, y: 0, width: 454, height: 156)
        panel.accessoryView = accessory
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
        guard let exportRange = selection.range else {
            store.lastError = "Choose an export range with an end after its start."
            return
        }

        let project = document.project
        let folderURL = document.folderURL
        isRendering = true
        Task {
            do {
                try await renderEngine.export(project: project, from: folderURL, to: destinationURL, range: exportRange)
                let start = exportRange.startSeconds
                let notes = """
                CamOrder Studio — Logic movie placement
                Movie: \(destinationURL.lastPathComponent)
                Edited timeline start: \(String(format: "%.6f", start)) seconds from the Logic project timeline origin.

                1. In Logic Pro, choose File > Movie > Open Movie and select this export.
                2. Move Logic's playhead to the start you want (the edited timeline start above to preserve placement).
                3. In Logic's Key Commands, find and use “Move Movie Region to Playhead”.
                   Alternatively set Movie Start in File > Project Settings > Movie; add your project's SMPTE origin offset to the seconds above.

                This export is a rendered movie. CamOrder does not insert or move Logic's movie track automatically.
                The Audio Unit passes audio through; it does not record Logic's mix into the movie.
                Import a bounced mix under Master Audio / Export if you want audio in the export.
                """
                try notes.write(to: destinationURL.deletingPathExtension().appendingPathExtension("logic-placement.txt"), atomically: true, encoding: .utf8)
                store.lastExportURL = destinationURL
                NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
            } catch {
                store.lastError = renderErrorMessage(error)
            }
            isRendering = false
        }
    }

    private func renderErrorMessage(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return error.localizedDescription
        }
        return "\(error.localizedDescription) (\(nsError.domain) \(nsError.code))"
    }

    private var syncIcon: String {
        switch syncEngine.state {
        case .disconnected, .waitingForTimecode: return "antenna.radiowaves.left.and.right.slash"
        case .unstable, .error: return "exclamationmark.triangle"
        default: return "antenna.radiowaves.left.and.right"
        }
    }

    private var syncTint: Color {
        if editPlayback.isEditMode {
            return .accentColor
        }
        switch syncEngine.state {
        case .playing, .chasing:
            return .green
        case .unstable, .error:
            return .red
        case .waitingForTimecode, .disconnected:
            return .secondary
        default:
            return .primary
        }
    }

    private var recordTint: Color {
        if store.pendingTake != nil {
            return .red
        }
        if store.armedBuffer != nil || store.hasArmedLane {
            return .orange
        }
        return .secondary
    }

    private var recordStatus: String {
        if store.pendingTake != nil {
            return "Recording take"
        }
        if let armedBufferLaneName = store.armedBufferLaneName {
            return "Armed · buffering: \(armedBufferLaneName)"
        }
        if let armedLaneName = store.armedLaneName {
            return "Ready: \(armedLaneName)"
        }
        return "Choose a lane to arm"
    }
}

private struct MediaBrowserView: View {
    @EnvironmentObject private var store: ProjectStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Media / Takes")
            Spacer(minLength: 8)
            VStack(spacing: 8) {
                Button {
                    store.openVideoMediaFolder()
                } label: {
                    Label("Video Folder", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                Button {
                    store.importVideo()
                } label: {
                    Label("Import Video", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(10)
            .buttonStyle(.bordered)
            Spacer()
        }
    }
}

private struct PlaybackPreviewPane: View {
    @EnvironmentObject private var store: ProjectStore
    @ObservedObject var syncEngine: LogicSyncEngine
    @ObservedObject var editPlayback: EditPlaybackController
    private let canvasHandleOutset: CGFloat = 26
    @State private var liveCanvasPixelSize: CGSize?

    private var playheadSeconds: Double {
        editPlayback.seconds(sync: syncEngine)
    }

    private var isPlaying: Bool {
        editPlayback.playing(sync: syncEngine)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionHeader("Main Stage")
                Spacer()
                Text(canvasLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 8)
            }
            let clips = store.project.playbackClips(at: playheadSeconds)
            if !clips.isEmpty {
                GeometryReader { geometry in
                    let canvasPixels = liveCanvasPixelSize ?? projectCanvasPixelSize
                    let canvasSize = canvasDisplaySize(in: geometry.size, canvasPixels: canvasPixels)
                    let previewSize = CGSize(width: max(1, geometry.size.width), height: max(1, geometry.size.height))
                    ZStack {
                        Color.black
                        PlaybackCanvasView(
                            previewSize: previewSize, canvasSize: canvasSize, canvasPixelSize: canvasPixels,
                            clips: clips, playheadSeconds: playheadSeconds, isPlaying: isPlaying,
                            onCanvasPixelSizeChanged: { liveCanvasPixelSize = $0 },
                            onCanvasPixelSizeCommitted: { pixels in
                                liveCanvasPixelSize = nil
                                store.setExportCanvasSize(width: Int(pixels.width.rounded()), height: Int(pixels.height.rounded()))
                            }
                        )
                        .frame(width: previewSize.width, height: previewSize.height)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                }
            } else {
                GeometryReader { geometry in
                    ZStack {
                        Color.black
                        VStack(spacing: 6) {
                            Image(systemName: "video")
                                .font(.system(size: geometry.size.height < 140 ? 22 : 42))
                                .foregroundStyle(.secondary)
                            Text("No video at playhead")
                                .font(.caption)
                            if geometry.size.height >= 140 {
                                Text("Assign Output Layers to regions: 1 is foreground, followed by 2 and 3.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                }
            }
        }
    }

    private var projectCanvasPixelSize: CGSize {
        CGSize(
            width: CGFloat(max(1, store.project.exportSettings.canvasWidth ?? 1920)),
            height: CGFloat(max(1, store.project.exportSettings.canvasHeight ?? 1080))
        )
    }

    private var canvasAspectRatio: CGFloat {
        let width = max(1, store.project.exportSettings.canvasWidth ?? 1920)
        let height = max(1, store.project.exportSettings.canvasHeight ?? 1080)
        return CGFloat(width) / CGFloat(height)
    }

    private var canvasLabel: String {
        let width = store.project.exportSettings.canvasWidth ?? 1920
        let height = store.project.exportSettings.canvasHeight ?? 1080
        return "\(width)x\(height) \(store.project.exportSettings.container.displayName)"
    }

    private func canvasDisplaySize(in availableSize: CGSize, canvasPixels: CGSize) -> CGSize {
        let width = max(1, canvasPixels.width)
        let height = max(1, canvasPixels.height)
        let scale = min((availableSize.width - canvasHandleOutset * 2) / width, (availableSize.height - canvasHandleOutset * 2) / height, 1)
        return CGSize(width: width * max(0.001, scale), height: height * max(0.001, scale))
    }
}

private struct PlaybackCanvasView: View {
    @EnvironmentObject private var store: ProjectStore
    let previewSize: CGSize
    let canvasSize: CGSize
    let canvasPixelSize: CGSize
    let clips: [VideoClip]
    let playheadSeconds: Double
    let isPlaying: Bool
    let onCanvasPixelSizeChanged: (CGSize) -> Void
    let onCanvasPixelSizeCommitted: (CGSize) -> Void
    @State private var framingEdit: (id: String, seconds: Double)?

    private var target: VideoClip? {
        if let edit = framingEdit, let clip = clips.first(where: { $0.id == edit.id }) { return clip }
        return clips.first(where: { $0.id == store.selectedClipId }) ?? clips.first
    }
    private func framing(_ clip: VideoClip) -> ClipFraming {
        let current = store.clip(id: clip.id).map { store.project.presentedClip($0) } ?? clip
        return current.automatedFraming(atLocalSecond: framingEdit?.id == clip.id
            ? framingEdit!.seconds : playheadSeconds - current.timelineStartSeconds)
    }
    var body: some View {
        ZStack {
            ZStack {
                ForEach(Array(clips.reversed())) { clip in
                    if let asset = store.mediaAsset(for: clip), let url = store.absoluteURL(for: asset) {
                        PlaybackPlayerView(url: url, clipStartSeconds: clip.timelineStartSeconds,
                            trimInSeconds: clip.trimInSeconds, playbackSyncOffsetSeconds: store.effectivePlaybackSyncOffsetSeconds(for: clip),
                            playheadSeconds: playheadSeconds, isPlaying: isPlaying, framing: framing(clip))
                            .allowsHitTesting(false)
                    }
                }
            }.frame(width: canvasSize.width, height: canvasSize.height).clipped()
            if let clip = target {
                CanvasCropOverlay(framing: framing(clip), panReferenceSize: canvasSize, canvasPixelSize: canvasPixelSize,
                    onFramingBegan: {
                        framingEdit = (clip.id, playheadSeconds - clip.timelineStartSeconds)
                        store.beginClipFramingEdit(clip.id)
                        store.selectedClipId = clip.id; store.selectedMediaAssetId = clip.mediaAssetId
                    },
                    onFramingChanged: { value in
                        store.updateClipFraming(clip.id, zoom: value.zoom, offsetX: value.offsetX,
                            offsetY: value.offsetY, rotationDegrees: value.rotationDegrees,
                            referenceLocalSeconds: framingEdit?.seconds ?? playheadSeconds - clip.timelineStartSeconds,
                            trackUndo: false, origin: .canvas)
                    },
                    onFramingCommitted: { store.endClipFramingEdit(); framingEdit = nil },
                    onCanvasPixelSizeChanged: onCanvasPixelSizeChanged, onCanvasPixelSizeCommitted: onCanvasPixelSizeCommitted)
                    .id(clip.id).frame(width: canvasSize.width, height: canvasSize.height)
            }
        }
    }
}

private struct CanvasCropOverlay: View {
    let framing: ClipFraming
    let panReferenceSize: CGSize
    let canvasPixelSize: CGSize
    let onFramingBegan: () -> Void
    let onFramingChanged: (ClipFraming) -> Void
    let onFramingCommitted: () -> Void
    let onCanvasPixelSizeChanged: (CGSize) -> Void
    let onCanvasPixelSizeCommitted: (CGSize) -> Void
    @State private var panStart: ClipFraming?
    @State private var magnifyStart: ClipFraming?
    @State private var pendingFraming: ClipFraming?

    var body: some View {
        ZStack {
            Rectangle()
                .strokeBorder(Color.white.opacity(0.85), lineWidth: 2)
                .background(Color.clear)
                .contentShape(Rectangle())
                .gesture(panGesture)
                .simultaneousGesture(magnifyGesture)
            RenderCanvasFrameOverlay(canvasPixelSize: canvasPixelSize,
                onCanvasPixelSizeChanged: onCanvasPixelSizeChanged,
                onCanvasPixelSizeCommitted: onCanvasPixelSizeCommitted)
        }
        .onDisappear {
            if pendingFraming != nil { onFramingCommitted() }
        }
    }

    private var panGesture: some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                if panStart == nil {
                    if magnifyStart == nil { onFramingBegan() }
                    panStart = pendingFraming ?? framing
                }
                let start = panStart ?? framing
                var next = pendingFraming ?? start
                next.offsetX = clamp(start.offsetX + Double(value.translation.width / max(1, panReferenceSize.width)) * 2, -8, 8)
                next.offsetY = clamp(start.offsetY + Double(value.translation.height / max(1, panReferenceSize.height)) * 2, -8, 8)
                pendingFraming = next
                onFramingChanged(next)
            }
            .onEnded { _ in
                panStart = nil
                if magnifyStart == nil { commit() }
            }
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if magnifyStart == nil {
                    if panStart == nil { onFramingBegan() }
                    magnifyStart = pendingFraming ?? framing
                }
                let start = magnifyStart ?? framing
                var next = pendingFraming ?? start
                next.zoom = clamp(start.zoom * Double(value), 0.25, 16)
                pendingFraming = next
                onFramingChanged(next)
            }
            .onEnded { _ in
                magnifyStart = nil
                if panStart == nil { commit() }
            }
    }

    private func commit() {
        onFramingCommitted()
        pendingFraming = nil
    }

    private func clamp(_ value: Double, _ minimum: Double, _ maximum: Double) -> Double {
        min(maximum, max(minimum, value))
    }
}

private struct RenderCanvasFrameOverlay: View {
    let canvasPixelSize: CGSize
    let onCanvasPixelSizeChanged: (CGSize) -> Void
    let onCanvasPixelSizeCommitted: (CGSize) -> Void
    @State private var resize: CanvasResize?
    @State private var pendingSize: CGSize?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Rectangle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1)
                    .allowsHitTesting(false)
                corner(left: true, top: true, size: geometry.size)
                corner(left: false, top: true, size: geometry.size)
                corner(left: true, top: false, size: geometry.size)
                corner(left: false, top: false, size: geometry.size)
            }
        }
    }
    private func corner(left: Bool, top: Bool, size: CGSize) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.white)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.7), lineWidth: 1))
            .frame(width: 12, height: 12)
            .padding(6).contentShape(Rectangle())
            .help("Resize canvas width and height. Drag inside to move video; pinch to zoom.")
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if resize == nil { resize = CanvasResize(pixels: canvasPixelSize, display: size, left: left, top: top) }
                    guard let resize else { return }
                    let next = resize.size(translation: value.translation)
                    pendingSize = next
                    onCanvasPixelSizeChanged(next)
                }
                .onEnded { _ in
                    if let pendingSize { onCanvasPixelSizeCommitted(pendingSize) }
                    resize = nil; pendingSize = nil
                })
            .position(x: left ? -10 : size.width + 10, y: top ? -10 : size.height + 10)
    }
}

private struct LiveInputAndMediaPane: View {
    @ObservedObject var cameraEngine: CameraCaptureEngine
    @ObservedObject var captureRegionController: CaptureRegionController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Live Input")
            LiveInputPreview(cameraEngine: cameraEngine, captureRegionController: captureRegionController)
                .frame(height: 230)
            Divider()
            MediaBrowserView()
        }
    }
}

private struct InspectorPane: View {
    @ObservedObject var syncEngine: LogicSyncEngine
    @ObservedObject var cameraEngine: CameraCaptureEngine
    @ObservedObject var captureRegionController: CaptureRegionController
    @EnvironmentObject private var store: ProjectStore
    @State private var latencyText = "0"
    @State private var playbackSyncText = "0.000"
    @State private var tempoText = "120"
    @State private var logicObservedText = ""
    @State private var camObservedText = ""
    @State private var audioOffsetText = "0.00000"
    @State private var canvasWidthText = "1920"
    @State private var canvasHeightText = "1080"
    @FocusState private var isTempoFieldFocused: Bool
    @State private var showSyncSection = false
    @State private var showTempoSection = false
    @State private var showCameraSection = true
    @State private var showCalibrationSection = true
    @State private var showAudioSection = false
    @State private var showClipSection = true
    @State private var isInspectorFramingEditActive = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Inspector")
            Form {
                DisclosureGroup("Sync Status", isExpanded: $showSyncSection) {
                    LabeledContent("Sync State", value: syncEngine.state.rawValue)
                    LabeledContent("Playhead", value: formatTimelineSeconds(syncEngine.displaySeconds, frameRate: store.project.frameRate, format: store.clockDisplayFormat))
                    LabeledContent(syncEngine.isHosted ? "Connection" : "MIDI Source", value: syncEngine.connectedSourceNames.isEmpty ? "Not connected" : syncEngine.connectedSourceNames.joined(separator: ", "))
                    if let error = syncEngine.lastErrorMessage {
                        Text(error)
                            .foregroundStyle(syncEngine.state == .error ? .red : .secondary)
                    }
                }

                DisclosureGroup("Tempo Grid", isExpanded: $showTempoSection) {
                    if store.hostGrid != nil {
                        Label(String(format: "Following Logic · %.2f BPM", store.tempoBPM), systemImage: "metronome")
                        Text("The grid follows the tempo and beat position at Logic’s current playhead. Move Logic to the section you are editing after a tempo change.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                    HStack(spacing: 8) {
                        TextField("BPM", text: $tempoText)
                            .frame(width: 110)
                            .focused($isTempoFieldFocused)
                            .onSubmit {
                                saveTempo()
                                isTempoFieldFocused = false
                            }
                        Stepper("Tempo", value: tempoStepperBinding, in: 20...300, step: 0.5)
                            .labelsHidden()
                        Button {
                            saveTempo()
                            isTempoFieldFocused = false
                        } label: {
                            Image(systemName: "checkmark")
                        }
                        .help("Apply tempo")
                    }
                    }
                    Toggle("Snap cuts and drags to grid", isOn: Binding(get: { store.snapToGrid }, set: store.setSnapToGrid))
                    Picker("Grid", selection: gridDivisionBinding) {
                        ForEach(BeatGridDivision.allCases, id: \.self) { division in
                            Text(division.displayName).tag(division)
                        }
                    }
                    LabeledContent("Grid Size", value: String(format: "%.3f s", store.gridSeconds))
                    Picker("Clock", selection: clockDisplayBinding) {
                        ForEach(ClockDisplayFormat.allCases, id: \.self) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    if selectedClip != nil {
                        HStack {
                            Button("Snap Start") {
                                store.snapSelectedClipStartToGrid()
                            }
                            Button("Snap End") {
                                store.snapSelectedClipEndToGrid()
                            }
                        }
                        HStack {
                            Button("Shorten") {
                                store.shortenSelectedClipByGrid()
                            }
                            Button("Extend") {
                                store.extendSelectedClipByGrid()
                            }
                        }
                    }
                }

                if !store.isHosted { DisclosureGroup("Camera / Input", isExpanded: $showCameraSection) {
                    Picker("Capture Source", selection: cameraSelection) {
                        ForEach(cameraEngine.availableDevices) { device in
                            Label(device.displayName, systemImage: sourceIcon(for: device.kind))
                                .tag(Optional(device.id))
                        }
                    }
                    .disabled(cameraEngine.isRecording || cameraEngine.isFinishingRecording)
                    HStack {
                        Button {
                            cameraEngine.refreshDevices()
                            if cameraEngine.isPreviewing {
                                cameraEngine.startPreview()
                            }
                        } label: {
                            Label("Refresh", systemImage: "arrow.triangle.2.circlepath")
                        }
                        Button {
                            cameraEngine.startPreview()
                        } label: {
                            Label(cameraEngine.isPreviewing ? "Restart" : "Preview", systemImage: "play.rectangle")
                        }
                        Button { cameraEngine.stopPreview() } label: { Image(systemName: "stop.fill") }
                            .help("Stop camera / screen preview")
                            .disabled(!cameraEngine.isPreviewing || cameraEngine.isRecording || cameraEngine.isFinishingRecording)
                    }
                    if cameraEngine.selectedDeviceID?.hasPrefix("screen:") == true || cameraEngine.selectedDeviceID?.hasPrefix("window:") == true {
                        HStack {
                            Button {
                                captureRegionController.show()
                            } label: {
                                Label("Show Region", systemImage: "plus.viewfinder")
                            }
                            Button {
                                cameraEngine.setScreenCropRect(captureRegionController.captureRectForMainDisplay())
                            } label: {
                                Label("Apply", systemImage: "checkmark")
                            }
                            Button {
                                captureRegionController.hide()
                            } label: {
                                Label("Hide", systemImage: "eye.slash")
                            }
                        }
                    }
                    Text("Connect a USB webcam or enable Continuity Camera on your iPhone (USB or wireless). For screen recording, select a display or region above.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Preview starts when you select an input. New takes use capture timestamps and record video only. Disarm to stop buffering. Import a bounced mix below to include audio in the exported movie.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = cameraEngine.lastErrorMessage {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }

                }

                DisclosureGroup("Master Audio / Export", isExpanded: $showAudioSection) {
                    LabeledContent("Frame Rate", value: store.project.frameRate.displayName)
                    LabeledContent("File", value: store.project.audio.masteredAudioFile ?? "No mastered audio imported")
                    Button {
                        store.importMasterAudio()
                        audioOffsetText = formatSeconds(store.project.audio.audioOffsetSeconds)
                    } label: {
                        Label("Import Master Audio", systemImage: "waveform")
                    }
                    TextField("Audio offset seconds", text: $audioOffsetText)
                        .onSubmit {
                            saveAudioOffset()
                        }
                    HStack {
                        Stepper("Audio Offset", value: audioOffsetStepperBinding, in: -30...30, step: 0.001)
                            .labelsHidden()
                        Button {
                            saveAudioOffset()
                        } label: {
                            Label("Apply", systemImage: "checkmark")
                        }
                        Button {
                            audioOffsetText = formatSeconds(0)
                            saveAudioOffset()
                        } label: {
                            Label("Reset", systemImage: "arrow.counterclockwise")
                        }
                    }
                    Picker("Export Audio", selection: exportAudioModeBinding) {
                        ForEach(ExportAudioMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    Picker("Render Format", selection: exportContainerBinding) {
                        ForEach(ExportContainer.allCases, id: \.self) { container in
                            Text(container.displayName).tag(container)
                        }
                    }
                    Picker("Canvas", selection: exportResolutionBinding) {
                        ForEach(ExportResolution.allCases, id: \.self) { resolution in
                            Text(resolution.displayName).tag(resolution)
                        }
                    }
                    HStack {
                        TextField("Width px", text: $canvasWidthText)
                            .frame(width: 84)
                            .onSubmit { saveCanvasSize() }
                        TextField("Height px", text: $canvasHeightText)
                            .frame(width: 84)
                            .onSubmit { saveCanvasSize() }
                        Stepper("W", value: canvasWidthStepperBinding, in: 320...7680, step: 16)
                            .labelsHidden()
                        Stepper("H", value: canvasHeightStepperBinding, in: 180...4320, step: 16)
                            .labelsHidden()
                        Button {
                            saveCanvasSize()
                        } label: {
                            Image(systemName: "checkmark")
                        }
                        .help("Apply canvas size")
                    }
                    LabeledContent("Canvas Size", value: "\(store.project.exportSettings.canvasWidth ?? 1920)x\(store.project.exportSettings.canvasHeight ?? 1080)")
                    LabeledContent("Current Offset", value: "\(formatSeconds(store.project.audio.audioOffsetSeconds)) s")
                }

                if let clip = selectedClip {
                    DisclosureGroup("Selected Clip", isExpanded: $showClipSection) {
                        LabeledContent("Edited start", value: formatTimelineSeconds(clip.timelineStartSeconds, frameRate: clip.frameRate, format: store.clockDisplayFormat))
                        LabeledContent("Duration", value: String(format: "%.2f s", clip.durationSeconds))
                        LabeledContent("Lane", value: clip.armedLaneId)
                        LabeledContent("Capture Delay", value: "\(clip.captureLatencyMs) ms")
                        LabeledContent("Timing", value: store.effectivePlaybackSyncOffsetSeconds(for: clip) == 0 ? "Capture timestamps" : "Saved legacy adjustment")
                        LabeledContent("Automation", value: "\(clip.automationMarkers.count) markers")
                        Slider(
                            value: Binding(
                                get: { store.framingForEditing(store.clip(id: clip.id) ?? clip).zoom },
                                set: {
                                    store.updateClipFraming(clip.id,
                                        zoom: $0,
                                        trackUndo: false,
                                        save: false,
                                        origin: .inspector
                                    )
                                }
                            ),
                            in: 0.25...16,
                            onEditingChanged: handleFramingSliderEditingChanged
                        ) {
                            Text("Zoom")
                        }
                        LabeledContent("Zoom", value: String(format: "%.2fx", store.framingForEditing(clip).zoom))
                        Slider(
                            value: Binding(
                                get: { store.framingForEditing(store.clip(id: clip.id) ?? clip).offsetX },
                                set: {
                                    store.updateClipFraming(clip.id,
                                        offsetX: $0,
                                        trackUndo: false,
                                        save: false,
                                        origin: .inspector
                                    )
                                }
                            ),
                            in: -8...8,
                            onEditingChanged: handleFramingSliderEditingChanged
                        ) {
                            Text("Pan X")
                        }
                        Slider(
                            value: Binding(
                                get: { store.framingForEditing(store.clip(id: clip.id) ?? clip).offsetY },
                                set: {
                                    store.updateClipFraming(clip.id,
                                        offsetY: $0,
                                        trackUndo: false,
                                        save: false,
                                        origin: .inspector
                                    )
                                }
                            ),
                            in: -8...8,
                            onEditingChanged: handleFramingSliderEditingChanged
                        ) {
                            Text("Pan Y")
                        }
                        Slider(
                            value: Binding(
                                get: { store.framingForEditing(store.clip(id: clip.id) ?? clip).rotationDegrees },
                                set: {
                                    store.updateClipFraming(clip.id,
                                        rotationDegrees: $0,
                                        trackUndo: false,
                                        save: false,
                                        origin: .inspector
                                    )
                                }
                            ),
                            in: -180...180,
                            onEditingChanged: { isEditing in
                                if isEditing {
                                    beginInspectorFramingEdit()
                                } else {
                                    normalizeAndCommitSelectedClipRotation()
                                }
                            }
                        ) {
                            Text("Rotate")
                        }
                        HStack {
                            Button("-5 deg") {
                                rotateSelectedClip(by: -5)
                            }
                            Button("+5 deg") {
                                rotateSelectedClip(by: 5)
                            }
                            Button("Reset") {
                                setSelectedClipRotation(0)
                            }
                        }
                        LabeledContent("Rotate", value: String(format: "%.1f deg", store.framingForEditing(clip).rotationDegrees))
                        if !clip.automationMarkers.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Automation Markers")
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                                ForEach(clip.automationMarkers.sorted { $0.timeSeconds < $1.timeSeconds }) { marker in
                                    HStack {
                                        Image(systemName: "flag.fill")
                                            .foregroundStyle(.yellow)
                                        Text(formatTimelineSeconds(store.project.presentedClip(clip).timelineStartSeconds + marker.timeSeconds, frameRate: clip.frameRate, format: store.clockDisplayFormat))
                                            .font(.caption.monospacedDigit())
                                        Spacer()
                                        Button {
                                            store.deleteAutomationMarker(marker.id, in: clip.id)
                                        } label: {
                                            Image(systemName: "trash")
                                        }
                                        .buttonStyle(.borderless)
                                        .help("Delete marker")
                                    }
                                }
                                Button(role: .destructive) {
                                    store.clearSelectedClipAutomation()
                                } label: {
                                    Label("Clear Markers", systemImage: "eraser")
                                }
                            }
                        }
                        Button(role: .destructive) {
                            store.deleteSelectedClip()
                        } label: {
                            Label("Delete Region", systemImage: "trash")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .controlSize(.small)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .onAppear {
                latencyText = "\(store.captureLatencyMs(for: cameraEngine.selectedDeviceID))"
                playbackSyncText = formatSeconds(store.defaultPlaybackSyncOffsetSeconds)
                tempoText = formatTempo(store.tempoBPM)
                audioOffsetText = formatSeconds(store.project.audio.audioOffsetSeconds)
                canvasWidthText = "\(store.project.exportSettings.canvasWidth ?? 1920)"
                canvasHeightText = "\(store.project.exportSettings.canvasHeight ?? 1080)"
                captureRegionController.onRegionChanged = { [weak cameraEngine] rect in
                    cameraEngine?.setScreenCropRect(rect)
                }
            }
            .onChange(of: cameraEngine.selectedDeviceID) { _ in
                latencyText = "\(store.captureLatencyMs(for: cameraEngine.selectedDeviceID))"
                playbackSyncText = formatSeconds(store.playbackSyncOffsetSeconds(for: cameraEngine.selectedDeviceID))
            }
            .onChange(of: store.tempoBPM) { bpm in
                if !isTempoFieldFocused {
                    tempoText = formatTempo(bpm)
                }
            }
            .onChange(of: store.project.audio.audioOffsetSeconds) { offset in
                audioOffsetText = formatSeconds(offset)
            }
            .onChange(of: store.project.exportSettings.canvasWidth) { width in
                canvasWidthText = "\(width ?? 1920)"
            }
            .onChange(of: store.project.exportSettings.canvasHeight) { height in
                canvasHeightText = "\(height ?? 1080)"
            }
        }
    }

    private var cameraSelection: Binding<String?> {
        Binding(
            get: { cameraEngine.selectedDeviceID },
            set: { newValue in
                if let newValue {
                    selectCaptureSource(id: newValue, clearMedia: false)
                }
            }
        )
    }

    private var tempoStepperBinding: Binding<Double> {
        Binding(
            get: { store.tempoBPM },
            set: { value in
                let rounded = (value * 2).rounded() / 2
                tempoText = formatTempo(rounded)
                store.setTempoBPM(rounded)
                syncEngine.setTempoBPM(rounded)
            }
        )
    }

    private var latencyStepperBinding: Binding<Double> {
        Binding(
            get: { Double(store.captureLatencyMs(for: cameraEngine.selectedDeviceID)) },
            set: { value in
                latencyText = "\(Int(value.rounded()))"
                saveLatency()
            }
        )
    }

    private var playbackSyncStepperBinding: Binding<Double> {
        Binding(
            get: { playbackSyncValue() },
            set: { value in
                playbackSyncText = formatSeconds(value)
                savePlaybackSyncOffset()
            }
        )
    }

    private var audioOffsetStepperBinding: Binding<Double> {
        Binding(
            get: { parseObservedSeconds(audioOffsetText) ?? store.project.audio.audioOffsetSeconds },
            set: { value in
                audioOffsetText = formatSeconds(value)
                saveAudioOffset()
            }
        )
    }

    private var canvasWidthStepperBinding: Binding<Double> {
        Binding(
            get: { Double(store.project.exportSettings.canvasWidth ?? 1920) },
            set: { value in
                canvasWidthText = "\(Int(value.rounded()))"
                saveCanvasSize()
            }
        )
    }

    private var canvasHeightStepperBinding: Binding<Double> {
        Binding(
            get: { Double(store.project.exportSettings.canvasHeight ?? 1080) },
            set: { value in
                canvasHeightText = "\(Int(value.rounded()))"
                saveCanvasSize()
            }
        )
    }

    private func selectCaptureSource(id: String, clearMedia: Bool) {
        cameraEngine.selectDevice(id: id)
        latencyText = "\(store.captureLatencyMs(for: id))"
        playbackSyncText = formatSeconds(store.playbackSyncOffsetSeconds(for: id))
        if clearMedia {
            store.clearSelectedMedia()
        }
        if usesRegionBox(id) {
            captureRegionController.show()
            cameraEngine.setScreenCropRect(captureRegionController.captureRectForMainDisplay())
        }
    }

    private func usesRegionBox(_ id: String) -> Bool {
        id == "screen:region" || id.hasPrefix("window:")
    }

    private func saveLatency() {
        let value = Int(latencyText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let deviceName = cameraEngine.availableDevices.first(where: { $0.id == cameraEngine.selectedDeviceID })?.displayName ?? "Default Camera"
        store.setCaptureLatency(ms: value, cameraDeviceId: cameraEngine.selectedDeviceID, displayName: deviceName)
    }

    private func saveTempo() {
        let value = Double(tempoText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? store.tempoBPM
        store.setTempoBPM(value)
        syncEngine.setTempoBPM(value)
        tempoText = formatTempo(value)
    }

    private func savePlaybackSyncOffset() {
        let value = playbackSyncValue()
        let deviceName = cameraEngine.availableDevices.first(where: { $0.id == cameraEngine.selectedDeviceID })?.displayName ?? "Default Camera"
        store.setPlaybackSyncOffset(seconds: value, cameraDeviceId: cameraEngine.selectedDeviceID, displayName: deviceName)
    }

    private func savePlaybackSyncOffsetAsAppDefault() {
        let value = playbackSyncValue()
        let deviceName = cameraEngine.availableDevices.first(where: { $0.id == cameraEngine.selectedDeviceID })?.displayName ?? "Default Camera"
        store.savePlaybackSyncOffsetAsAppDefault(seconds: value, cameraDeviceId: cameraEngine.selectedDeviceID, displayName: deviceName)
    }

    private func applyPlaybackSyncOffsetToSelected() {
        store.updateSelectedClipPlaybackSyncOffset(seconds: playbackSyncValue())
    }

    private func applyPlaybackSyncOffsetToInputClips() {
        store.updatePlaybackSyncOffsetForClips(seconds: playbackSyncValue(), cameraDeviceId: cameraEngine.selectedDeviceID)
    }

    private func applyPlaybackSyncOffsetToAllClips() {
        store.setDefaultPlaybackSyncOffset(seconds: playbackSyncValue(), applyToExisting: true)
    }

    private func saveAudioOffset() {
        let value = parseObservedSeconds(audioOffsetText) ?? 0
        store.setMasterAudioOffset(seconds: value)
        audioOffsetText = formatSeconds(value)
    }

    private func saveCanvasSize() {
        let width = Int(canvasWidthText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1920
        let height = Int(canvasHeightText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1080
        store.setExportCanvasSize(width: width, height: height)
        canvasWidthText = "\(store.project.exportSettings.canvasWidth ?? 1920)"
        canvasHeightText = "\(store.project.exportSettings.canvasHeight ?? 1080)"
    }

    private func rotateSelectedClip(by degrees: Double) {
        let current = selectedClip.map { store.framingForEditing($0).rotationDegrees } ?? 0
        let snapped = (current / 5).rounded() * 5
        setSelectedClipRotation(snapped + degrees)
    }

    private func setSelectedClipRotation(_ degrees: Double) {
        let normalized = normalizeRotation(degrees)
        store.updateSelectedClipFraming(rotationDegrees: normalized, trackUndo: true, save: true, origin: .inspector)
    }

    private func normalizeAndCommitSelectedClipRotation() {
        let current = selectedClip.map { store.framingForEditing($0).rotationDegrees } ?? 0
        store.updateSelectedClipFraming(
            rotationDegrees: normalizeRotation(current),
            trackUndo: false,
            save: false,
            origin: .inspector
        )
        commitInspectorFramingEdit()
    }

    private func handleFramingSliderEditingChanged(_ isEditing: Bool) {
        if isEditing {
            beginInspectorFramingEdit()
        } else {
            commitInspectorFramingEdit()
        }
    }

    private func beginInspectorFramingEdit() {
        guard !isInspectorFramingEditActive else { return }
        isInspectorFramingEditActive = true
        store.beginSelectedClipFramingEdit()
    }

    private func commitInspectorFramingEdit() {
        guard isInspectorFramingEditActive else {
            store.saveProject()
            return
        }
        isInspectorFramingEditActive = false
        store.endClipFramingEdit()
    }

    private func applyEstimatedLatency() {
        let source = cameraEngine.availableDevices.first(where: { $0.id == cameraEngine.selectedDeviceID })
        latencyText = "\(CameraCaptureEngine.estimatedLatencyMs(for: source))"
        saveLatency()
    }

    private func applyObservedDelta() {
        guard let logicSeconds = parseObservedSeconds(logicObservedText),
              let camSeconds = parseObservedSeconds(camObservedText) else {
            return
        }
        let currentOffset = store.selectedClip().map { store.effectivePlaybackSyncOffsetSeconds(for: $0) } ?? playbackSyncValue()
        let playbackSyncOffset = currentOffset + logicSeconds - camSeconds
        playbackSyncText = formatSeconds(playbackSyncOffset)
        store.updateSelectedClipPlaybackSyncOffset(seconds: playbackSyncOffset)
    }

    private func applyObservedCaptureDelay() {
        guard let logicSeconds = parseObservedSeconds(logicObservedText),
              let camSeconds = parseObservedSeconds(camObservedText) else {
            return
        }
        let delayMs = max(0, Int(((camSeconds - logicSeconds) * 1000).rounded()))
        latencyText = "\(delayMs)"
        saveLatency()
        store.updateSelectedClipLatency(ms: delayMs)
    }

    private func playbackSyncValue() -> Double {
        Double(playbackSyncText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private func formatSeconds(_ value: Double) -> String {
        String(format: "%.5f", value)
    }

    private func parseObservedSeconds(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = Double(trimmed) {
            return direct
        }

        let parts = trimmed.split(separator: ":").map(String.init)
        guard parts.count >= 2, parts.count <= 4 else { return nil }
        let numericParts = parts.compactMap(Double.init)
        guard numericParts.count == parts.count else { return nil }

        if numericParts.count == 2 {
            return numericParts[0] * 60 + numericParts[1]
        }
        if numericParts.count == 3 {
            return numericParts[0] * 3600 + numericParts[1] * 60 + numericParts[2]
        }

        let frameRate = store.project.frameRate.framesPerSecond
        return numericParts[0] * 3600 + numericParts[1] * 60 + numericParts[2] + numericParts[3] / frameRate
    }

    private func normalizeRotation(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 {
            value -= 360
        }
        if value < -180 {
            value += 360
        }
        if abs(value) < 0.0001 {
            return 0
        }
        return value
    }

    private func formatTempo(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private var gridDivisionBinding: Binding<BeatGridDivision> {
        Binding(
            get: { store.gridDivision },
            set: { store.setGridDivision($0) }
        )
    }

    private var clockDisplayBinding: Binding<ClockDisplayFormat> {
        Binding(
            get: { store.clockDisplayFormat },
            set: { store.setClockDisplayFormat($0) }
        )
    }

    private var exportAudioModeBinding: Binding<ExportAudioMode> {
        Binding(
            get: { store.project.exportSettings.audioMode },
            set: { store.setExportAudioMode($0) }
        )
    }

    private var exportContainerBinding: Binding<ExportContainer> {
        Binding(
            get: { store.project.exportSettings.container },
            set: { store.setExportContainer($0) }
        )
    }

    private var exportResolutionBinding: Binding<ExportResolution> {
        Binding(
            get: { store.project.exportSettings.resolution },
            set: { store.setExportResolution($0) }
        )
    }

    private func sourceIcon(for kind: CaptureSourceKind) -> String {
        switch kind {
        case .camera: return "video"
        case .screen: return "display"
        case .window: return "macwindow"
        }
    }

    private var selectedClip: VideoClip? {
        store.selectedClip()
    }
}

private struct TimelineView: View {
    @EnvironmentObject private var store: ProjectStore
    let syncEngine: LogicSyncEngine
    let editPlayback: EditPlaybackController
    let secondsToPixels: Double
    @Binding var timelineZoom: Double
    var compact = false
    @State private var followedSeconds = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("TIMELINE")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                SymbolToolButton(systemImage: "plus", help: "Add Camera Lane") {
                    store.addLane()
                }
                .padding(.trailing, 6)
                Slider(value: $timelineZoom, in: 4...240) {
                    Text("Zoom")
                }
                .frame(width: compact ? 100 : 180)
                Text("\(Int(timelineZoom)) px/s")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Divider()
                    .frame(height: 18)
                HStack(spacing: 4) {
                    Button {
                        store.insertAutomationMarker(at: activePlayheadSeconds)
                    } label: {
                        Label("Marker", systemImage: "flag.fill")
                    }
                    .help("Insert automation marker at playhead")
                    .disabled(store.selectedClip() == nil)
                    SymbolToolButton(systemImage: "scissors", help: "Cut Selected Regions at Playhead (T)") {
                        store.cutSelectedClip(at: activePlayheadSeconds)
                    }
                    .disabled(store.selectedClip() == nil)
                    SymbolToolButton(systemImage: "doc.on.doc", help: "Copy Selected Regions (⌘C)") {
                        store.copySelectedRegion()
                    }
                    .disabled(store.selectedClip() == nil)
                    SymbolToolButton(systemImage: "doc.on.clipboard", help: "Paste Regions at Playhead (⌘V)") {
                        store.pasteRegion(at: activePlayheadSeconds)
                    }
                    .disabled(!store.canPasteRegion)
                    SymbolToolButton(systemImage: "trash", help: "Delete Selected Regions") {
                        store.deleteSelectedClip()
                    }
                    .disabled(store.selectedClip() == nil)
                }
                .controlSize(.small)
                .fixedSize()
                Spacer()
                TimelineClock(sync: syncEngine, edit: editPlayback)

            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                ZStack {
                    Rectangle()
                        .fill(Color.white.opacity(0.025))
                    Color.black.opacity(0.12)
                }
            }
            HStack(spacing: 10) {
                Toggle(isOn: Binding(get: { store.snapToGrid }, set: store.setSnapToGrid)) {
                    Label("Snap", systemImage: "grid")
                }.toggleStyle(.button).tint(.cyan)
                Picker("Grid", selection: Binding(get: { store.gridDivision }, set: store.setGridDivision)) {
                    ForEach(BeatGridDivision.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }.labelsHidden().frame(width: 105)
                Text(String(format: "%@ %.1f BPM", store.hostGrid == nil ? "Grid" : "Logic", store.tempoBPM))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Divider().frame(height: 16)
                RegionLayerMenu().environmentObject(store)
                Spacer(minLength: 0)
                Text(store.selectedClipIDs.count > 1 ? "\(store.selectedClipIDs.count) selected" : "Shift-click to select multiple")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .controlSize(.small)
            .padding(.horizontal, 12).padding(.bottom, 7)
            ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Timecode")
                        .font(.caption.bold())
                        .frame(width: 150, height: 28, alignment: .leading)
                    ForEach(store.project.timeline.lanes) { lane in
                        LaneHeader(lane: lane)
                            .frame(width: 150, height: 56, alignment: .leading)
                    }
                    if store.project.audio.masteredAudioFile != nil { Text("Master Audio")
                        .font(.caption.bold())
                        .frame(width: 150, height: 34, alignment: .leading) }
                }
                .padding(.leading, 12)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.025))

                TimelineScrollView(width: timelineWidth, height: timelineContentHeight + 24, scale: secondsToPixels,
                    seconds: { activePlayheadSeconds }, playing: { editPlayback.playing(sync: syncEngine) },
                    zoom: { timelineZoom = $0 }, extend: { followedSeconds = max(followedSeconds, $0) }) {
                        ZStack(alignment: .topLeading) {
                            Color.clear
                                .frame(width: timelineWidth, height: timelineContentHeight)
                                .contentShape(Rectangle())
                                .gesture(seekGesture)
                            VStack(alignment: .leading, spacing: 8) {
                                ruler
                                ForEach(store.project.timeline.lanes) { lane in
                                    ZStack(alignment: .leading) {
                                        Rectangle()
                                            .fill(laneFill(for: lane))
                                            .frame(width: timelineWidth, height: 56)
                                            .overlay(alignment: .leading) {
                                                timelineGrid(height: 56)
                                            }
                                            .opacity(lane.isMuted ? 0.58 : 1)
                                            .contentShape(Rectangle())
                                            .gesture(seekGesture)
                                            .contextMenu {
                                                Button("Paste Region Here at Playhead") { store.pasteRegion(at: activePlayheadSeconds, laneID: lane.id) }
                                                    .disabled(!store.canPasteRegion)
                                            }
                                        ForEach(lane.clips) { originalClip in
                                            let clip = store.project.presentedClip(originalClip, laneID: lane.id)
                                            ClipBlock(
                                                clip: clip,
                                                videoURL: videoURL(for: clip),
                                                secondsToPixels: secondsToPixels,
                                                isSelected: store.selectedClipIDs.contains(clip.id),
                                                preview: store.regionEditPreview,
                                                onSelect: { flags in
                                                    store.selectRegion(clip.id, extending: flags.contains(.shift), preserveGroup: true)
                                                },
                                                onClick: { store.selectRegion(clip.id) },
                                                onMarker: { seconds in
                                                    store.selectRegion(clip.id, preserveGroup: true)
                                                    seekTimelineIfEditing(locationX: CGFloat(seconds * secondsToPixels))
                                                },
                                                onBeginTrim: { store.selectRegion(clip.id, preserveGroup: true) },
                                                onPreview: { kind, delta in
                                                    store.previewRegionEdit(anchor: clip.id, kind: kind, translation: delta,
                                                        bypassSnap: NSEvent.modifierFlags.contains(.option))
                                                },
                                                onCommit: { kind, delta in
                                                    store.commitRegionEdit(anchor: clip.id, kind: kind, translation: delta,
                                                        bypassSnap: NSEvent.modifierFlags.contains(.option))
                                                }
                                            )
                                                .offset(x: clip.timelineStartSeconds * secondsToPixels)
                                                .zIndex(store.selectedClipIDs.contains(clip.id) ? 1 : 0)
                                                .opacity(lane.isMuted ? 0.55 : 1)
                                                .contextMenu {
                                                    Button("Cut Selection at Playhead (T)") {
                                                        store.selectRegion(clip.id, preserveGroup: true); store.cutSelectedClip(at: activePlayheadSeconds)
                                                    }
                                                    Menu("Output Layer") {
                                                        ForEach(1...9, id: \.self) { number in
                                                            Button(regionLayerName(number)) {
                                                                store.selectRegion(clip.id, preserveGroup: true); store.setSelectedRegionLayer(number)
                                                            }
                                                        }
                                                        Button("Automatic · Lane Order (0)") {
                                                            store.selectRegion(clip.id, preserveGroup: true); store.setSelectedRegionLayer(nil)
                                                        }
                                                    }
                                                    Button("Copy Selection") {
                                                        store.selectRegion(clip.id, preserveGroup: true)
                                                        store.copySelectedRegion()
                                                    }
                                                    Button("Paste at Playhead on This Lane") { store.pasteRegion(at: activePlayheadSeconds, laneID: lane.id) }
                                                        .disabled(!store.canPasteRegion)
                                                    Divider()
                                                    Button("Snap Left Edge to Grid") {
                                                        store.selectRegion(clip.id, preserveGroup: true); store.snapSelectedClipStartToGrid()
                                                    }
                                                    Button("Snap Right Edge to Grid") {
                                                        store.selectRegion(clip.id, preserveGroup: true); store.snapSelectedClipEndToGrid()
                                                    }
                                                    Divider()
                                                    Button {
                                                        store.selectRegion(clip.id, preserveGroup: true)
                                                        store.selectedMediaAssetId = clip.mediaAssetId
                                                        store.insertAutomationMarker(at: activePlayheadSeconds)
                                                    } label: {
                                                        Label("Insert Automation Marker", systemImage: "flag.fill")
                                                    }
                                                    Button {
                                                        store.selectRegion(clip.id, preserveGroup: true)
                                                        store.selectedMediaAssetId = clip.mediaAssetId
                                                        store.deleteNearestAutomationMarker(at: activePlayheadSeconds)
                                                    } label: {
                                                        Label("Delete Nearest Marker", systemImage: "flag.slash")
                                                    }
                                                    .disabled(clip.automationMarkers.isEmpty)
                                                    Button(role: .destructive) {
                                                        store.selectRegion(clip.id, preserveGroup: true)
                                                        store.clearSelectedClipAutomation()
                                                    } label: {
                                                        Label("Clear Automation Markers", systemImage: "eraser")
                                                    }
                                                    .disabled(clip.automationMarkers.isEmpty)
                                                    Divider()
                                                    Button(role: .destructive) {
                                                        store.selectRegion(clip.id, preserveGroup: true); store.deleteSelectedClip()
                                                    } label: {
                                                        Label("Delete Region", systemImage: "trash")
                                                    }
                                                }
                                        }
                                        if let pending = store.pendingTakes[lane.id] {
                                            let offset = store.project.videoOffsetSeconds(forLane: lane.id)
                                            PendingRecordingRegion(sync: syncEngine, startSeconds: pending.startSeconds + offset, endSeconds: store.captureEndSeconds[lane.id], videoOffset: offset, scale: secondsToPixels)
                                                .offset(x: (pending.startSeconds + offset) * secondsToPixels)
                                        }
                                    }
                                }
                                if store.project.audio.masteredAudioFile != nil { Rectangle()
                                    .fill(Color.accentColor.opacity(0.12))
                                    .frame(width: timelineWidth, height: 34)
                                    .overlay(alignment: .leading) {
                                        HStack(spacing: 10) {
                                            Button {
                                                store.importMasterAudio()
                                            } label: {
                                                Label("Import Master Audio", systemImage: "waveform")
                                            }
                                            .buttonStyle(.borderless)
                                            Text(store.project.audio.masteredAudioFile ?? "No mastered audio imported")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        .padding(.leading, 8)
                                    } }
                            }
                            .padding(.vertical, 12)

                            TimelineCursor(sync: syncEngine, edit: editPlayback, scale: secondsToPixels, height: timelineContentHeight)

                        }.frame(width: timelineWidth, height: timelineContentHeight + 24, alignment: .topLeading)
                }
                .frame(height: timelineContentHeight + 24)
                .background(Color.black.opacity(0.28))
                .help("Pinch to zoom. Playback follows the playhead; scroll to look elsewhere temporarily.")
            }
            }
        }
    }

    private var timelineWidth: CGFloat {
        CGFloat(max(1800, (max(store.project.presentationTimeline.lanes.flatMap(\.clips).map { $0.timelineStartSeconds + $0.durationSeconds }.max() ?? 0, followedSeconds) + 90) * secondsToPixels))
    }

    private var timelineContentHeight: CGFloat {
        max(120, CGFloat(store.project.timeline.lanes.count * 64 + 76))
    }

    private var activePlayheadSeconds: Double {
        editPlayback.seconds(sync: syncEngine)
    }

    private func videoURL(for clip: VideoClip) -> URL? {
        guard let asset = store.mediaAsset(for: clip),
              let url = store.absoluteURL(for: asset),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    private func laneFill(for lane: VideoLane) -> Color {
        if lane.isArmed {
            return Color.red.opacity(0.16)
        }
        if lane.isMuted {
            return Color.black.opacity(0.30)
        }
        return Color.black.opacity(0.20)
    }

    private func seekTimelineIfEditing(locationX: CGFloat) {
        let seconds = store.snappedTime(max(0, Double(locationX) / max(1, secondsToPixels)), bypass: NSEvent.modifierFlags.contains(.option))
        if syncEngine.isHosted { syncEngine.preview(at: seconds) }
        else { editPlayback.isEditMode = true; editPlayback.seek(to: seconds, audioOffsetSeconds: store.project.audio.audioOffsetSeconds) }
    }

    private var seekGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                seekTimelineIfEditing(locationX: value.location.x)
            }
            .onEnded { value in
                seekTimelineIfEditing(locationX: value.location.x)
            }
    }

    private var ruler: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.black.opacity(0.26))
                .frame(width: timelineWidth, height: 28)
            Canvas { context, size in
                drawGridLines(context: &context, size: size, height: 28, includeMinorTicks: true)
            }
            .frame(width: timelineWidth, height: 28)
            ZStack(alignment: .topLeading) {
                ForEach(labelSeconds, id: \.self) { seconds in
                    Text(formatTimelineSeconds(seconds, frameRate: store.project.frameRate, format: store.clockDisplayFormat))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: labelWidth, height: 28, alignment: .topLeading)
                        .offset(x: CGFloat(seconds) * secondsToPixels)
                        .id(seconds)
                }
            }
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .gesture(seekGesture)
    }

    private func timelineGrid(height: CGFloat) -> some View {
        Canvas { context, size in
            drawGridLines(context: &context, size: size, height: height, includeMinorTicks: false)
        }
        .frame(width: timelineWidth, height: height)
        .allowsHitTesting(false)
    }

    private var gridTickSeconds: Double {
        max(0.001, store.gridSeconds)
    }

    private var labelSeconds: [Double] {
        let visibleDuration = max(120, Double(timelineWidth / max(1, CGFloat(secondsToPixels))))
        let step = labelStepSeconds
        let count = min(400, Int((visibleDuration / step).rounded(.up)) + 1)
        let first = store.musicalGrid.firstTick(atOrAfter: 0, spacing: step)
        return (0..<count).map { first + Double($0) * step }
    }

    private var labelStepSeconds: Double {
        let barSeconds = max(0.001, 60.0 / max(1, store.tempoBPM) * 4)
        // Labels use the same absolute timeline coordinates as clips/playhead.
        // Leave enough space for the full timestamp at every zoom level.
        return barSeconds * max(1, ceil(100 / (barSeconds * max(1, secondsToPixels))))
    }

    private var labelWidth: CGFloat {
        max(90, CGFloat(labelStepSeconds) * secondsToPixels)
    }

    private func isMajorGridLine(_ seconds: Double) -> Bool {
        let barSeconds = max(0.001, 60.0 / max(1, store.tempoBPM) * 4)
        let relative = seconds - store.musicalGrid.originSeconds
        let barIndex = (relative / barSeconds).rounded()
        return abs(relative - (barIndex * barSeconds)) < 0.001
    }

    private func drawGridLines(context: inout GraphicsContext, size: CGSize, height: CGFloat, includeMinorTicks: Bool) {
        // Thin dense marks across the whole timeline instead of dropping every
        // grid line after an arbitrary count on long recordings.
        let duration = Double(size.width) / max(1, secondsToPixels)
        let thinning = max(1, ceil(max(4 / (gridTickSeconds * secondsToPixels), duration / (gridTickSeconds * 12000))))
        let step = gridTickSeconds * thinning
        let first = store.musicalGrid.firstTick(atOrAfter: 0, spacing: step)
        let lineCount = max(0, Int(ceil((duration - first) / step)))
        for index in 0...lineCount {
            let seconds = first + Double(index) * step
            let x = CGFloat(seconds) * secondsToPixels
            let major = isMajorGridLine(seconds)
            let opacity = major ? 0.28 : 0.12
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: includeMinorTicks ? (major ? 12 : 7) : height))
            context.stroke(path, with: .color(Color.secondary.opacity(opacity)), lineWidth: 1)
        }
    }
}

private struct LiveInputPreview: View {
    @ObservedObject var cameraEngine: CameraCaptureEngine
    @ObservedObject var captureRegionController: CaptureRegionController

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if cameraEngine.selectedDeviceID?.hasPrefix("window:") == true {
                CapturePreviewPane(cameraEngine: cameraEngine)
                    .background(.black)
            } else {
                CapturePreviewPane(cameraEngine: cameraEngine)
                    .background(.black)
            }
            if usesRegionBox {
                Button {
                    captureRegionController.show()
                    cameraEngine.setScreenCropRect(captureRegionController.captureRectForMainDisplay())
                } label: {
                    Image(systemName: "plus.viewfinder")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .help("Show capture region box")
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            HStack {
                Circle()
                    .fill(cameraEngine.isRecording ? .red : (cameraEngine.isPreviewing ? .green : .secondary))
                    .frame(width: 8, height: 8)
                Text(liveStatusText)
                    .font(.caption)
            }
            .padding(7)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
            .padding(8)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard usesRegionBox else { return }
            captureRegionController.show()
            cameraEngine.setScreenCropRect(captureRegionController.captureRectForMainDisplay())
        }
    }

    private var usesRegionBox: Bool {
        cameraEngine.selectedDeviceID == "screen:region" || cameraEngine.selectedDeviceID?.hasPrefix("window:") == true
    }

    private var liveStatusText: String {
        if cameraEngine.isRecording {
            return "Recording buffer"
        }
        return cameraEngine.isPreviewing ? "Live input" : "Preview idle"
    }
}

private struct PlaybackPlayerView: NSViewRepresentable {
    let url: URL
    let clipStartSeconds: Double
    let trimInSeconds: Double
    let playbackSyncOffsetSeconds: Double
    let playheadSeconds: Double
    let isPlaying: Bool
    let framing: ClipFraming

    func makeNSView(context: Context) -> PlaybackPlayerNSView {
        let view = PlaybackPlayerNSView()
        view.update(url: url, clipStartSeconds: clipStartSeconds, trimInSeconds: trimInSeconds, playbackSyncOffsetSeconds: playbackSyncOffsetSeconds, playheadSeconds: playheadSeconds, isPlaying: isPlaying, framing: framing)
        return view
    }

    func updateNSView(_ nsView: PlaybackPlayerNSView, context: Context) {
        nsView.update(url: url, clipStartSeconds: clipStartSeconds, trimInSeconds: trimInSeconds, playbackSyncOffsetSeconds: playbackSyncOffsetSeconds, playheadSeconds: playheadSeconds, isPlaying: isPlaying, framing: framing)
    }
}

private final class PlaybackPlayerNSView: NSView {
    private let playback = TimelineVideoPlayer()
    private var currentFraming = ClipFraming()
    private let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayers()
    }

    deinit {
        playerLayer.player = nil
    }

    private func configureLayers() {
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.clear.cgColor
        playerLayer.backgroundColor = NSColor.clear.cgColor
        playerLayer.player = playback.player
        playerLayer.videoGravity = .resizeAspect
        playerLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        playerLayer.actions = [
            "transform": NSNull(),
            "position": NSNull(),
            "bounds": NSNull()
        ]
        layer?.addSublayer(playerLayer)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.bounds = bounds
        playerLayer.position = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        CATransaction.commit()
        apply(framing: currentFraming)
    }

    func update(url: URL, clipStartSeconds: Double, trimInSeconds: Double, playbackSyncOffsetSeconds: Double, playheadSeconds: Double, isPlaying: Bool, framing: ClipFraming) {
        if currentFraming != framing {
            currentFraming = framing
            apply(framing: framing)
        }
        let sourceSeconds = max(0, trimInSeconds + playheadSeconds - clipStartSeconds + playbackSyncOffsetSeconds)
        playback.update(url: url, sourceSeconds: sourceSeconds, isPlaying: isPlaying)
    }

    private func apply(framing: ClipFraming) {
        let scale = max(0.25, min(16, framing.zoom))
        let translationX = framing.offsetX * bounds.width * 0.5
        let translationY = -framing.offsetY * bounds.height * 0.5
        let radians = CGFloat(framing.rotationDegrees * .pi / 180)
        var transform = CATransform3DIdentity
        transform = CATransform3DScale(transform, scale, scale, 1)
        transform = CATransform3DRotate(transform, radians, 0, 0, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.position = CGPoint(
            x: bounds.width / 2 + translationX,
            y: bounds.height / 2 + translationY
        )
        playerLayer.transform = transform
        CATransaction.commit()
    }
}

private struct LaneHeader: View {
    @EnvironmentObject private var store: ProjectStore
    let lane: VideoLane
    @State private var showOffset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            LaneNameEditor(name: lane.name) { store.renameLane(lane.id, name: $0) }.frame(height: 17)
            if let inputs = store.captureInputs {
                LaneSourcePicker(inputs: inputs, discovery: inputs.discovery, lane: lane)
            }
            HStack(spacing: 6) {
                if lane.isArmed {
                    Button {
                        store.armLane(lane.id)
                    } label: {
                        Label("Armed", systemImage: "record.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else {
                    Button {
                        store.armLane(lane.id)
                    } label: {
                        Label("Arm", systemImage: "record.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button {
                    store.toggleLaneMuted(lane.id)
                } label: {
                    Image(systemName: lane.isMuted ? "eye.slash" : "eye")
                        .frame(width: 16)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(lane.isMuted ? "Unmute lane" : "Mute lane")
                Button { showOffset.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.borderless).help("Lane video sync")
                    .popover(isPresented: $showOffset) {
                        VideoOffsetControl(title: lane.name + " · video sync", value: lane.videoOffsetMS ?? 0) { store.setVideoOffsetMS($0, laneID: lane.id) }
                            .padding(16).frame(width: 280)
                    }
                Button {
                    store.deleteLane(lane.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(store.project.timeline.lanes.count <= 1 || lane.isArmed || store.laneIsBusy(lane.id))
            }
        }
    }

    private var laneName: Binding<String> {
        Binding(
            get: { lane.name },
            set: { store.renameLane(lane.id, name: $0) }
        )
    }
}

private struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> CameraPreviewNSView {
        let view = CameraPreviewNSView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        nsView.previewLayer.session = session
    }
}

private final class CameraPreviewNSView: NSView {
    override func makeBackingLayer() -> CALayer {
        AVCaptureVideoPreviewLayer()
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspect
    }
}

private struct PendingClipBlock: View {
    let startSeconds: Double
    let currentSeconds: Double
    let secondsToPixels: Double
    var finishing = false

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color.red, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.2)))
            .frame(width: max(1, (currentSeconds - startSeconds) * secondsToPixels), height: 40)
            .overlay {
                Text(finishing ? "finishing" : "recording")
                    .font(.caption2.bold())
                    .foregroundStyle(.red)
            }
    }
}

private struct ClipBlock: View {
    let clip: VideoClip
    let videoURL: URL?
    let secondsToPixels: Double
    let isSelected: Bool
    let preview: ProjectStore.RegionEditPreview?
    let onSelect: (NSEvent.ModifierFlags) -> Void
    let onClick: () -> Void
    let onMarker: (Double) -> Void
    let onBeginTrim: () -> Void
    let onPreview: (ProjectStore.RegionEditKind, Double) -> Void
    let onCommit: (ProjectStore.RegionEditKind, Double) -> Void

    private func delta(_ kind: ProjectStore.RegionEditKind) -> Double {
        guard let preview, preview.ids.contains(clip.id), preview.kind == kind else { return 0 }
        return preview.delta
    }

    var body: some View {
        let leftDelta = delta(.left)
        let rightDelta = delta(.right)
        let previewDuration = max(min(0.1, clip.durationSeconds), clip.durationSeconds - leftDelta + rightDelta)
        let width = max(1, previewDuration * secondsToPixels)
        let leftGripOffset = width < 42 ? -min(12, max(0, (clip.timelineStartSeconds + leftDelta) * secondsToPixels)) : 0
        let rightGripOffset = width < 42 ? max(12, leftGripOffset + 28 - width) : 0
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.46))
            if let videoURL {
                TimelineClipFilmstripView(
                    url: videoURL,
                    trimInSeconds: max(0, clip.trimInSeconds + leftDelta),
                    durationSeconds: previewDuration,
                    width: width
                )
                .frame(width: width, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .opacity(clip.isEnabled ? 0.90 : 0.42)
            }
            RoundedRectangle(cornerRadius: 6)
                .fill(clipOverlayColor(hasVideo: videoURL != nil))
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(regionLayerColor(clip.compositingLayer).opacity(clip.compositingLayer == nil ? 0.25 : 1), lineWidth: 2)
            RoundedRectangle(cornerRadius: 7)
                .stroke(isSelected ? Color.yellow : Color.clear, lineWidth: 2)
                .padding(-3)
            VStack(spacing: 2) {
                Text(clip.compositingLayer.map { "L\($0) · \(clip.clipId)" } ?? clip.clipId)
                    .font(.caption2.bold())
                Text(formatTimelineSeconds(clip.timelineStartSeconds + delta(.move) + leftDelta, frameRate: clip.frameRate, format: .logicTime))
                    .font(.caption2.monospacedDigit())
            }
            .frame(maxWidth: max(0, width - 14))
            .clipped()
            .lineLimit(1)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.28), radius: 1, x: 0, y: 1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.black.opacity(videoURL == nil ? 0.14 : 0.44), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .allowsHitTesting(false)
            RegionMoveHandle(clipID: clip.id, onSelect: onSelect, onClick: onClick,
                onChange: { onPreview(.move, seconds(for: $0)) },
                onEnd: { onCommit(.move, seconds(for: $0)) })
                .frame(width: width, height: 40)
            ForEach(visibleAutomationMarkers) { marker in
                automationMarkerView
                    .offset(x: markerX(for: marker, width: width) - width / 2)
                    .contentShape(Rectangle())
                    .onTapGesture { onMarker(clip.timelineStartSeconds + marker.timeSeconds) }
                    .help("Preview and edit this automation marker")
            }
        }
        .frame(width: width, height: 40)
        .overlay(alignment: .topLeading) {
            if let layer = clip.compositingLayer {
                Text("\(layer)").font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(.black).padding(.horizontal, 4).padding(.vertical, 1)
                    .background(regionLayerColor(layer), in: RoundedRectangle(cornerRadius: 3))
                    .offset(x: 15, y: -5).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .leading) {
            RegionTrimHandle(clipID: clip.id, left: true, selected: isSelected, onSelect: onBeginTrim,
                onChange: { onPreview(.left, seconds(for: $0)) },
                onEnd: { onCommit(.left, seconds(for: $0)) })
                .frame(width: 14, height: 40).offset(x: leftGripOffset)
        }
        .overlay(alignment: .trailing) {
            RegionTrimHandle(clipID: clip.id, left: false, selected: isSelected, onSelect: onBeginTrim,
                onChange: { onPreview(.right, seconds(for: $0)) },
                onEnd: { onCommit(.right, seconds(for: $0)) })
                .frame(width: 14, height: 40).offset(x: rightGripOffset)
        }
        // Keep exterior grips inside the parent hit-test bounds without changing
        // the region's actual timeline width or source time.
        .padding(.horizontal, 28)
        .offset(x: (delta(.move) + leftDelta) * secondsToPixels - 28)
    }

    private var visibleAutomationMarkers: [ClipAutomationMarker] {
        clip.automationMarkers.filter { marker in
            marker.timeSeconds >= 0 && marker.timeSeconds <= clip.durationSeconds
        }
    }

    private func clipOverlayColor(hasVideo: Bool) -> Color {
        if !clip.isEnabled {
            return Color.gray.opacity(hasVideo ? 0.26 : 0.42)
        }
        return Color.accentColor.opacity(hasVideo ? 0.16 : 0.82)
    }

    private var automationMarkerView: some View {
        VStack(spacing: 0) {
            Image(systemName: "flag.fill")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(.yellow, .black.opacity(0.72))
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(.black.opacity(0.58), in: Capsule())
            Rectangle()
                .fill(Color.yellow)
                .frame(width: 3, height: 31)
                .overlay {
                    Rectangle()
                        .stroke(Color.black.opacity(0.68), lineWidth: 1)
                }
        }
        .shadow(color: .black.opacity(0.72), radius: 2, x: 0, y: 1)
    }

    private func markerX(for marker: ClipAutomationMarker, width: CGFloat) -> CGFloat {
        let rawX = marker.timeSeconds * secondsToPixels
        return min(max(12, rawX), max(12, width - 12))
    }

    private func seconds(for translationWidth: CGFloat) -> Double {
        Double(translationWidth) / max(1, secondsToPixels)
    }


}

private struct TimelineClipFilmstripView: NSViewRepresentable {
    let url: URL
    let trimInSeconds: Double
    let durationSeconds: Double
    let width: CGFloat

    func makeNSView(context: Context) -> TimelineClipFilmstripNSView {
        TimelineClipFilmstripNSView()
    }

    func updateNSView(_ nsView: TimelineClipFilmstripNSView, context: Context) {
        nsView.update(
            url: url,
            trimInSeconds: trimInSeconds,
            durationSeconds: durationSeconds,
            expectedWidth: width
        )
    }
}

private final class TimelineClipFilmstripNSView: NSView {
    private static let renderQueue = DispatchQueue(label: "CamOrderStudio.timeline-filmstrip", qos: .userInitiated, attributes: .concurrent)
    private static let cache = NSCache<NSString, TimelineClipFilmstripCacheEntry>()

    private var requestKey: String?
    private var images: [CGImage] = []
    private var renderedSize = CGSize.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func layout() {
        super.layout()
        if renderedSize != bounds.size { render(images: images) }
    }

    func update(url: URL, trimInSeconds: Double, durationSeconds: Double, expectedWidth: CGFloat) {
        let sampleCount = Self.sampleCount(for: expectedWidth)
        let key = Self.cacheKey(
            url: url,
            trimInSeconds: trimInSeconds,
            durationSeconds: durationSeconds,
            sampleCount: sampleCount
        )
        guard key != requestKey else { return }
        requestKey = key

        if let cached = Self.cache.object(forKey: key as NSString) {
            images = cached.images
            render(images: cached.images)
            return
        }

        images = []
        renderPlaceholder()

        Self.renderQueue.async { [weak self] in
            let generatedImages = Self.generateImages(
                url: url,
                trimInSeconds: trimInSeconds,
                durationSeconds: durationSeconds,
                sampleCount: sampleCount
            )
            Self.cache.setObject(TimelineClipFilmstripCacheEntry(images: generatedImages), forKey: key as NSString)
            DispatchQueue.main.async {
                guard let self, self.requestKey == key else { return }
                self.images = generatedImages
                self.render(images: generatedImages)
            }
        }
    }

    private func configure() {
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.36).cgColor
        layer?.masksToBounds = true
    }

    private func render(images: [CGImage]) {
        renderedSize = bounds.size
        guard let layer else { return }
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard !images.isEmpty, bounds.width > 0, bounds.height > 0 else {
            renderPlaceholder()
            return
        }

        let tileWidth = bounds.width / CGFloat(images.count)
        for (index, image) in images.enumerated() {
            let imageLayer = CALayer()
            imageLayer.contents = image
            imageLayer.contentsGravity = .resizeAspectFill
            imageLayer.masksToBounds = true
            imageLayer.frame = CGRect(
                x: CGFloat(index) * tileWidth,
                y: 0,
                width: tileWidth + 0.5,
                height: bounds.height
            )
            layer.addSublayer(imageLayer)
        }
    }

    private func renderPlaceholder() {
        guard let layer else { return }
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        layer.backgroundColor = NSColor.black.withAlphaComponent(0.38).cgColor
    }

    private static func generateImages(url: URL, trimInSeconds: Double, durationSeconds: Double, sampleCount: Int) -> [CGImage] {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 180, height: 90)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.15, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.15, preferredTimescale: 600)

        let count = max(1, sampleCount)
        let duration = max(0.1, durationSeconds)
        return (0..<count).compactMap { index in
            let progress = count == 1 ? 0.5 : Double(index) / Double(count - 1)
            let seconds = max(0, trimInSeconds + duration * progress)
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            return try? generator.copyCGImage(at: time, actualTime: nil)
        }
    }

    private static func sampleCount(for width: CGFloat) -> Int {
        min(12, max(1, Int((max(72, width) / 58).rounded(.up))))
    }

    private static func cacheKey(url: URL, trimInSeconds: Double, durationSeconds: Double, sampleCount: Int) -> String {
        let trimKey = Int((trimInSeconds * 10).rounded())
        let durationKey = Int((durationSeconds * 10).rounded())
        return "\(url.path)|\(trimKey)|\(durationKey)|\(sampleCount)"
    }
}

private final class TimelineClipFilmstripCacheEntry: NSObject {
    let images: [CGImage]

    init(images: [CGImage]) {
        self.images = images
    }
}

private struct SectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    Rectangle()
                        .fill(Color.white.opacity(0.025))
                    Color.black.opacity(0.14)
                }
            }
    }
}

private func formatTimelineSeconds(_ seconds: Double, frameRate: FrameRate, format: ClockDisplayFormat) -> String {
    switch format {
    case .logicTime:
        let clamped = max(0, seconds)
        let minutes = Int(clamped / 60)
        let remainder = clamped - Double(minutes * 60)
        return String(format: "%02d:%06.3f", minutes, remainder)
    case .smpte:
        return Timecode.from(seconds: seconds, frameRate: frameRate).description
    case .seconds:
        return String(format: "%.5f s", max(0, seconds))
    }
}

struct CapturePreviewPane: View {
    @ObservedObject var cameraEngine: CameraCaptureEngine
    var body: some View {
        if cameraEngine.usesCaptureHelper {
            LivePreviewImage(frames: cameraEngine.previewFrames)
        } else { CameraPreviewView(session: cameraEngine.previewSession) }
    }
}

private struct LivePreviewImage: NSViewRepresentable {
    let frames: CapturePreviewFrames
    func makeNSView(context: Context) -> LivePreviewLayerView { LivePreviewLayerView(frames: frames) }
    func updateNSView(_ view: LivePreviewLayerView, context: Context) {}
}

private final class LivePreviewLayerView: NSView {
    private var subscription: AnyCancellable?
    init(frames: CapturePreviewFrames) {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.actions = ["contents": NSNull(), "bounds": NSNull()]
        subscription = frames.$image.sink { [weak self] image in self?.layer?.contents = image }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private struct StudioSplit<First: View, Second: View>: View {
    let axis: Axis
    @Binding var fraction: Double
    var minimum: CGFloat
    @ViewBuilder let first: () -> First
    @ViewBuilder let second: () -> Second
    @State private var dragStart: Double?
    var body: some View {
        GeometryReader { geometry in
            let length = axis == .horizontal ? geometry.size.width : geometry.size.height
            let available = max(1, length - 8)
            let lower = min(minimum, available * 0.4)
            let secondMinimum = min(axis == .vertical ? 150 : minimum, available - lower)
            let split = min(available - secondMinimum, max(lower, available * fraction))
            Group {
                if axis == .horizontal {
                    HStack(spacing: 0) {
                        first().frame(width: split).clipped()
                        handle(available: available).frame(width: 8)
                        second().frame(width: available - split).clipped()
                    }
                } else {
                    VStack(spacing: 0) {
                        first().frame(height: split).clipped()
                        handle(available: available).frame(height: 8)
                        second().frame(height: available - split).clipped()
                    }
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
    private func handle(available: CGFloat) -> some View {
        ZStack {
            Color.clear
            Capsule().fill(Color.white.opacity(0.22))
                .frame(width: axis == .horizontal ? 2 : 32, height: axis == .horizontal ? 32 : 2)
        }.contentShape(Rectangle())
            .help(axis == .horizontal ? "Drag to resize Main Stage and Live Input" : "Drag to resize the monitors and timeline")
            .onHover { inside in
                if inside { (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() }
                else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if dragStart == nil { dragStart = fraction }
                    let delta = axis == .horizontal ? value.translation.width : value.translation.height
                    fraction = min(0.85, max(0.15, (dragStart ?? fraction) + Double(delta / available)))
                }.onEnded { _ in dragStart = nil })
    }
}

private struct EditAudioObserver: View {
    @ObservedObject var editPlayback: EditPlaybackController
    let configure: () -> Void
    var body: some View { Color.clear.onChange(of: editPlayback.isEditMode) { _ in configure() } }
}

private struct TimelineClock: View {
    @ObservedObject var sync: LogicSyncEngine
    @ObservedObject var edit: EditPlaybackController
    var body: some View {
        Text(formatTimelineSeconds(edit.seconds(sync: sync), frameRate: .fps30, format: .logicTime))
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
    }
}

private struct TimelineCursor: View {
    @ObservedObject var sync: LogicSyncEngine
    @ObservedObject var edit: EditPlaybackController
    let scale: Double
    let height: CGFloat
    private var seconds: Double { edit.seconds(sync: sync) }
    var body: some View {
        Rectangle().fill(Color(red: 0.42, green: 0.89, blue: 0.78))
            .frame(width: 1.5, height: height).offset(x: seconds * scale, y: 12)
            .allowsHitTesting(false)
    }
}

private struct PendingRecordingRegion: View {
    @ObservedObject var sync: LogicSyncEngine
    let startSeconds: Double
    let endSeconds: Double?
    let videoOffset: Double
    let scale: Double
    var body: some View { PendingClipBlock(startSeconds: startSeconds, currentSeconds: (endSeconds ?? sync.displaySeconds) + videoOffset, secondsToPixels: scale, finishing: endSeconds != nil) }
}

private struct LiveSourceHeader: View {
    @ObservedObject var camera: CameraCaptureEngine
    var body: some View {
        HStack(spacing: 6) {
            Text("Live Input").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Picker("Input", selection: Binding(get: { camera.selectedDeviceID }, set: { if let id = $0 { camera.selectDevice(id: id) } })) {
                Text("Choose input").tag(Optional<String>.none)
                ForEach(camera.availableDevices) { device in Text(device.displayName).tag(Optional(device.id)) }
            }.labelsHidden().pickerStyle(.menu).controlSize(.small)
                .disabled(camera.isRecording || camera.isFinishingRecording)
            Button { camera.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).help("Refresh inputs")
        }.padding(.horizontal, 10).frame(height: 32)
    }
}

private struct VideoSyncPanel: View {
    @EnvironmentObject private var store: ProjectStore
    @ObservedObject var calculator: SyncCalculatorModel
    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("Sync tools", selection: $calculator.showingCalculator) {
                    Text("Offsets").tag(false)
                    Text("Calculator").tag(true)
                }.pickerStyle(.segmented)
                if calculator.showingCalculator {
                    SyncCalculatorView(model: calculator)
                } else {
                Text("Video sync").font(.headline)
                Text("Negative moves video earlier. Positive moves it later. Project and lane adjustments add together in Main Stage and export.")
                    .font(.caption).foregroundStyle(.secondary)
                VideoOffsetControl(title: "Whole project", value: store.project.sync.videoOffsetMS ?? 0) { store.setVideoOffsetMS($0) }
                Divider()
                ForEach(store.project.timeline.lanes) { lane in
                    VideoOffsetControl(title: lane.name, value: lane.videoOffsetMS ?? 0) { store.setVideoOffsetMS($0, laneID: lane.id) }
                }
                Text(String(format: "1/64 note at %.1f BPM = %.2f ms", store.tempoBPM, 60000 / max(1, store.tempoBPM) / 16))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text("Original recordings and edit points stay unchanged. Reset to 0 ms at any time.")
                    .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(20)
        }
        .onChange(of: calculator.result) { result in
            if result != nil { withAnimation { proxy.scrollTo("sync-calculator-result", anchor: .bottom) } }
        }
        }.frame(width: calculator.showingCalculator ? 440 : 330,
                height: calculator.showingCalculator ? 650 : min(560, CGFloat(250 + store.project.timeline.lanes.count * 68)))
    }
}

private struct VideoOffsetControl: View {
    let title: String
    let value: Double
    let apply: (Double) -> Void
    @State private var text = "0"
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(title).font(.caption.weight(.semibold)); Spacer(); Button("Reset") { apply(0) }.buttonStyle(.link).font(.caption) }
            HStack {
                TextField("0", text: $text).textFieldStyle(.roundedBorder).frame(width: 100)
                    .onSubmit { if let next = Double(text) { apply(next) } else { text = String(format: "%.2f", value) } }
                Text("ms").foregroundStyle(.secondary)
                Stepper("Milliseconds", onIncrement: { apply(value + 1) }, onDecrement: { apply(value - 1) }).labelsHidden()
                Spacer()
                Button("Apply") { if let next = Double(text) { apply(next) } }.controlSize(.small)
            }
        }.onAppear { text = String(format: "%.2f", value) }
            .onChange(of: value) { text = String(format: "%.2f", $0) }
    }
}
