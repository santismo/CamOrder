import AVFoundation
import CamOrderStudioCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
private final class EditPlaybackController: ObservableObject {
    @Published var isEditMode = false
    @Published var isPlaying = false
    @Published var playheadSeconds: Double = 0

    private var timer: Timer?
    private var lastTickDate = Date()
    private var audioPlayer: AVPlayer?
    private var audioURL: URL?

    func togglePlay(duration: Double) {
        isPlaying ? pause() : play(duration: duration)
    }

    func play(duration: Double) {
        isEditMode = true
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
        let next = max(0, playheadSeconds + seconds)
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
    @StateObject private var syncEngine = LogicSyncEngine()
    @StateObject private var cameraEngine = CameraCaptureEngine()
    @StateObject private var editPlayback = EditPlaybackController()
    @State private var timelineZoom: Double = 18
    @StateObject private var captureRegionController = CaptureRegionController()

    var body: some View {
        VStack(spacing: 0) {
            TransportSyncBar(syncEngine: syncEngine, cameraEngine: cameraEngine, editPlayback: editPlayback)
            Divider()
            VSplitView {
                HSplitView {
                    InspectorPane(syncEngine: syncEngine, cameraEngine: cameraEngine, captureRegionController: captureRegionController)
                        .frame(minWidth: 280, idealWidth: 340)
                    PlaybackPreviewPane(syncEngine: syncEngine, editPlayback: editPlayback)
                        .frame(minWidth: 420)
                    LiveInputAndMediaPane(cameraEngine: cameraEngine, captureRegionController: captureRegionController)
                        .frame(minWidth: 280, idealWidth: 340)
                }
                .frame(minHeight: 260)
                TimelineView(syncEngine: syncEngine, editPlayback: editPlayback, secondsToPixels: timelineZoom, timelineZoom: $timelineZoom)
                    .frame(minHeight: 160, idealHeight: 310)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("CamOrder Studio", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.lastError ?? "")
        }
        .onAppear {
            syncEngine.startMTCInput()
            syncEngine.setTempoBPM(store.tempoBPM)
        }
        .onChange(of: store.tempoBPM) { bpm in
            syncEngine.setTempoBPM(bpm)
        }
        .onChange(of: store.project.audio.masteredAudioFile) { _ in
            configureEditAudio()
        }
        .onChange(of: store.project.audio.audioOffsetSeconds) { _ in
            configureEditAudio()
        }
        .onChange(of: editPlayback.isEditMode) { _ in
            configureEditAudio()
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
        .focusable()
    }

    private func configureEditAudio() {
        guard editPlayback.isEditMode,
              let relativePath = store.project.audio.masteredAudioFile,
              let url = store.absoluteURL(for: relativePath) else {
            editPlayback.configureMasterAudio(url: nil, audioOffsetSeconds: store.project.audio.audioOffsetSeconds)
            return
        }
        editPlayback.configureMasterAudio(url: url, audioOffsetSeconds: store.project.audio.audioOffsetSeconds)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            modifierFlags.contains(.shift) ? store.redoProjectChange() : store.undoProjectChange()
            return true
        }

        if event.keyCode == 51 || event.keyCode == 117 {
            store.deleteSelectedClip()
            return true
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
                guard let self else { return event }
                guard !Self.isTextInputActive else { return event }
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

private struct TransportSyncBar: View {
    @ObservedObject var syncEngine: LogicSyncEngine
    @ObservedObject var cameraEngine: CameraCaptureEngine
    @ObservedObject var editPlayback: EditPlaybackController
    @EnvironmentObject private var store: ProjectStore
    @StateObject private var renderEngine = RenderExportEngine()
    @State private var isRendering = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.document?.project.name ?? "No Project")
                    .font(.headline)
                Text(store.document?.folderURL.path ?? "Create or open a .camorderstudio project")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Button("New") {
                        store.createProject()
                    }
                    Button("Open") {
                        store.openProject()
                    }
                    Button("Save") {
                        store.saveProject()
                    }
                    .disabled(!store.hasOpenProject)
                    Button("Save As") {
                        store.saveProjectAs()
                    }
                    .disabled(!store.hasOpenProject)
                }
                .controlSize(.small)
            }
            Spacer()
            Label(formatTimelineSeconds(activePlayheadSeconds, frameRate: store.project.frameRate, format: store.clockDisplayFormat), systemImage: "timeline.selection")
                .font(.system(.body, design: .monospaced))
            Label(editPlayback.isEditMode ? "edit mode" : syncEngine.state.rawValue, systemImage: syncIcon)
                .foregroundStyle(syncEngine.state == .unstable || syncEngine.state == .error ? .red : .primary)
            Label(recordStatus, systemImage: store.pendingTake == nil ? "record.circle" : "record.circle.fill")
                .foregroundStyle(store.pendingTake == nil ? Color.secondary : Color.red)
            Toggle("Edit", isOn: $editPlayback.isEditMode)
                .toggleStyle(.switch)
            Button {
                editPlayback.togglePlay(duration: max(store.project.timeline.durationSeconds, activePlayheadSeconds + 10))
            } label: {
                Label(editPlayback.isPlaying ? "Pause" : "Play", systemImage: editPlayback.isPlaying ? "pause.fill" : "play.fill")
            }
            .disabled(store.document == nil)
            Button {
                editPlayback.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .disabled(!editPlayback.isEditMode)
            Button("Refresh MIDI") {
                syncEngine.refreshSources()
            }
            Button {
                store.undoProjectChange()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(!store.canUndo)
            Button {
                store.redoProjectChange()
            } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .disabled(!store.canRedo)
            Button {
                renderProject()
            } label: {
                Label("Render", systemImage: "square.and.arrow.down")
            }
            .disabled(store.document == nil || isRendering)
            if isRendering {
                ProgressView(value: renderEngine.progress)
                    .frame(width: 86)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .onAppear {
            startArmedBufferIfNeeded()
        }
        .onChange(of: cameraEngine.lastRecordedFileURL) { recordedURL in
            guard recordedURL != nil else { return }
            if let stopTimecode = store.pendingStopTimecode {
                let warning = cameraEngine.lastErrorMessage.map { [$0] } ?? []
                store.finishTakeRegion(at: stopTimecode, warnings: warning)
                store.unarmAllLanes()
            } else {
                store.discardArmedBuffer()
            }
        }
        .onChange(of: cameraEngine.lastRecordingStartedHostTime) { hostTime in
            guard let hostTime else { return }
            store.markArmedBufferRecordingStarted(hostTime: hostTime)
        }
        .onChange(of: syncEngine.isTransportRolling) { isRolling in
            guard !editPlayback.isEditMode else { return }
            if isRolling {
                guard store.pendingTake == nil, store.hasArmedLane, store.document != nil else { return }
                startVideoTake()
            } else if store.pendingTake != nil {
                stopVideoTake()
            }
        }
        .onChange(of: store.armedLaneId) { armedLaneId in
            if armedLaneId != nil {
                startArmedBufferIfNeeded()
            } else if store.armedBuffer != nil, store.pendingTake == nil {
                cameraEngine.stopRecording()
                store.discardArmedBuffer()
            }
        }
    }

    private var activePlayheadSeconds: Double {
        editPlayback.isEditMode ? editPlayback.playheadSeconds : syncEngine.displaySeconds
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
            store.finishTakeRegion(at: stopTimecode, warnings: warning)
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
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        let project = document.project
        let folderURL = document.folderURL
        isRendering = true
        Task {
            do {
                try await renderEngine.export(project: project, from: folderURL, to: destinationURL)
                store.lastError = "Rendered video to \(destinationURL.path)"
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

    private var recordStatus: String {
        if let pendingTake = store.pendingTake {
            return "Recording \(pendingTake.clipId)"
        }
        if let armedBufferLaneName = store.armedBufferLaneName {
            return "Buffering: \(armedBufferLaneName)"
        }
        if let armedLaneName = store.armedLaneName {
            return "Auto Armed: \(armedLaneName)"
        }
        return "No Lane Armed"
    }
}

private struct MediaBrowserView: View {
    @EnvironmentObject private var store: ProjectStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Media / Takes")
            Spacer(minLength: 8)
            Button {
                store.openVideoMediaFolder()
            } label: {
                Label("Open Video Folder", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 10)
            Button {
                store.importVideo()
            } label: {
                Label("Import Existing Video", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .padding(10)
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
        editPlayback.isEditMode ? editPlayback.playheadSeconds : syncEngine.displaySeconds
    }

    private var isPlaying: Bool {
        editPlayback.isEditMode ? editPlayback.isPlaying : syncEngine.isTransportRolling
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionHeader(editPlayback.isEditMode ? "Edit Playback" : "Recorded Playback")
                Spacer()
                if editPlayback.isEditMode {
                    Text(canvasLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 8)
                }
            }
            if let clip = store.playbackClip(at: playheadSeconds),
               let asset = store.mediaAsset(for: clip),
                      let url = store.absoluteURL(for: asset),
                      FileManager.default.fileExists(atPath: url.path) {
                GeometryReader { geometry in
                    let canvasPixels = liveCanvasPixelSize ?? projectCanvasPixelSize
                    let canvasSize = canvasDisplaySize(in: geometry.size, canvasPixels: canvasPixels)
                    let previewSize = CGSize(width: max(1, geometry.size.width), height: max(1, geometry.size.height))
                    ZStack {
                        Color.black
                        PlaybackCanvasView(
                            previewSize: previewSize,
                            canvasSize: canvasSize,
                            canvasPixelSize: canvasPixels,
                            clip: clip,
                            url: url,
                            playbackSyncOffsetSeconds: store.effectivePlaybackSyncOffsetSeconds(for: clip),
                            playheadSeconds: playheadSeconds,
                            isPlaying: isPlaying,
                            onCanvasPixelSizeChanged: { liveCanvasPixelSize = $0 },
                            onCanvasPixelSizeCommitted: { pixels in
                                liveCanvasPixelSize = nil
                                store.setExportCanvasSize(
                                    width: Int(pixels.width.rounded()),
                                    height: Int(pixels.height.rounded())
                                )
                            }
                        )
                        .frame(width: previewSize.width, height: previewSize.height)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                }
            } else if let asset = store.selectedVideoAsset,
                      let url = store.absoluteURL(for: asset),
                      FileManager.default.fileExists(atPath: url.path) {
                GeometryReader { geometry in
                    let canvasPixels = liveCanvasPixelSize ?? projectCanvasPixelSize
                    let canvasSize = canvasDisplaySize(in: geometry.size, canvasPixels: canvasPixels)
                    let previewSize = CGSize(width: max(1, geometry.size.width), height: max(1, geometry.size.height))
                    ZStack {
                        Color.black
                        PlaybackPlayerView(
                            url: url,
                            clipStartSeconds: 0,
                            trimInSeconds: store.selectedClip()?.trimInSeconds ?? 0,
                            playbackSyncOffsetSeconds: store.selectedClip().map { store.effectivePlaybackSyncOffsetSeconds(for: $0) } ?? 0,
                            playheadSeconds: 0,
                            isPlaying: false,
                            framing: store.selectedClip()?.framing ?? ClipFraming()
                        )
                        .frame(width: previewSize.width, height: previewSize.height)
                        .allowsHitTesting(false)
                        RenderCanvasFrameOverlay(
                            canvasPixelSize: canvasPixels,
                            onCanvasPixelSizeChanged: { liveCanvasPixelSize = $0 },
                            onCanvasPixelSizeCommitted: { pixels in
                                liveCanvasPixelSize = nil
                                store.setExportCanvasSize(
                                    width: Int(pixels.width.rounded()),
                                    height: Int(pixels.height.rounded())
                                )
                            }
                        )
                        .frame(width: canvasSize.width, height: canvasSize.height)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                }
            } else {
                GeometryReader { geometry in
                    let canvasPixels = liveCanvasPixelSize ?? projectCanvasPixelSize
                    let canvasSize = canvasDisplaySize(in: geometry.size, canvasPixels: canvasPixels)
                    ZStack {
                        Color.black
                        VStack(spacing: 10) {
                            Image(systemName: "video")
                                .font(.system(size: 42))
                                .foregroundStyle(.secondary)
                            Text("No Recorded Clip Selected")
                                .font(.headline)
                            Text("Recorded playback will appear here once a region has media.")
                                .foregroundStyle(.secondary)
                        }
                        RenderCanvasFrameOverlay(
                            canvasPixelSize: canvasPixels,
                            onCanvasPixelSizeChanged: { liveCanvasPixelSize = $0 },
                            onCanvasPixelSizeCommitted: { pixels in
                                liveCanvasPixelSize = nil
                                store.setExportCanvasSize(
                                    width: Int(pixels.width.rounded()),
                                    height: Int(pixels.height.rounded())
                                )
                            }
                        )
                        .frame(width: canvasSize.width, height: canvasSize.height)
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
        return CGSize(width: width * max(0.1, scale), height: height * max(0.1, scale))
    }
}

private struct PlaybackCanvasView: View {
    @EnvironmentObject private var store: ProjectStore
    let previewSize: CGSize
    let canvasSize: CGSize
    let canvasPixelSize: CGSize
    let clip: VideoClip
    let url: URL
    let playbackSyncOffsetSeconds: Double
    let playheadSeconds: Double
    let isPlaying: Bool
    let onCanvasPixelSizeChanged: (CGSize) -> Void
    let onCanvasPixelSizeCommitted: (CGSize) -> Void
    @State private var liveClipId: String?
    @State private var liveFraming = ClipFraming()
    @State private var isManipulatingFraming = false
    @State private var pendingCommittedFraming: ClipFraming?

    var body: some View {
        ZStack {
            PlaybackPlayerView(
                url: url,
                clipStartSeconds: clip.timelineStartSeconds,
                trimInSeconds: clip.trimInSeconds,
                playbackSyncOffsetSeconds: playbackSyncOffsetSeconds,
                playheadSeconds: playheadSeconds,
                isPlaying: isPlaying,
                framing: liveFraming
            )
            .frame(width: previewSize.width, height: previewSize.height)
            .allowsHitTesting(false)
            CanvasCropOverlay(
                clip: clip,
                framing: liveFraming,
                panReferenceSize: previewSize,
                canvasPixelSize: canvasPixelSize,
                onFramingChanged: { framing in
                    isManipulatingFraming = true
                    liveFraming = framing
                },
                onFramingCommitted: { framing in
                    liveFraming = framing
                    pendingCommittedFraming = framing
                    store.updateSelectedClipFraming(
                        zoom: framing.zoom,
                        offsetX: framing.offsetX,
                        offsetY: framing.offsetY,
                        rotationDegrees: framing.rotationDegrees,
                        trackUndo: true,
                        save: true,
                        origin: .canvas
                    )
                    isManipulatingFraming = false
                },
                onCanvasPixelSizeChanged: onCanvasPixelSizeChanged,
                onCanvasPixelSizeCommitted: onCanvasPixelSizeCommitted
            )
            .frame(width: canvasSize.width, height: canvasSize.height)
        }
        .onAppear {
            syncLiveFramingIfNeeded()
            store.selectedClipId = clip.id
            store.selectedMediaAssetId = clip.mediaAssetId
        }
        .onChange(of: clip.id) { _ in
            pendingCommittedFraming = nil
            syncLiveFramingIfNeeded(force: true)
        }
        .onChange(of: clip.framing) { _ in
            guard !isManipulatingFraming else { return }
            if let pendingCommittedFraming {
                if framing(clip.framing, matches: pendingCommittedFraming) {
                    self.pendingCommittedFraming = nil
                    syncLiveFramingIfNeeded(force: true)
                    return
                }
                if store.latestFramingEdit?.clipId == clip.id,
                   store.latestFramingEdit?.origin == .inspector {
                    self.pendingCommittedFraming = nil
                } else {
                    return
                }
            }
            syncLiveFramingIfNeeded(force: true)
        }
        .onChange(of: store.latestFramingEdit?.revision) { _ in
            guard store.latestFramingEdit?.clipId == clip.id,
                  store.latestFramingEdit?.origin == .inspector else { return }
            pendingCommittedFraming = nil
            syncLiveFramingFromProject()
        }
    }

    private func syncLiveFramingIfNeeded(force: Bool = false) {
        guard force || liveClipId != clip.id else { return }
        liveClipId = clip.id
        liveFraming = clip.framing ?? ClipFraming()
    }

    private func syncLiveFramingFromProject() {
        liveClipId = clip.id
        liveFraming = store.selectedClip()?.framing ?? clip.framing ?? ClipFraming()
    }

    private func framing(_ lhs: ClipFraming?, matches rhs: ClipFraming) -> Bool {
        let lhs = lhs ?? ClipFraming()
        return abs(lhs.zoom - rhs.zoom) < 0.0001
            && abs(lhs.offsetX - rhs.offsetX) < 0.0001
            && abs(lhs.offsetY - rhs.offsetY) < 0.0001
            && abs(lhs.rotationDegrees - rhs.rotationDegrees) < 0.0001
    }
}

private struct CanvasCropOverlay: View {
    @EnvironmentObject private var store: ProjectStore
    let clip: VideoClip
    let framing: ClipFraming
    let panReferenceSize: CGSize
    let canvasPixelSize: CGSize
    let onFramingChanged: (ClipFraming) -> Void
    let onFramingCommitted: (ClipFraming) -> Void
    let onCanvasPixelSizeChanged: (CGSize) -> Void
    let onCanvasPixelSizeCommitted: (CGSize) -> Void
    @State private var panStart: ClipFraming?
    @State private var zoomStart: ClipFraming?
    @State private var magnifyStart: ClipFraming?
    @State private var pendingFraming: ClipFraming?
    @State private var resizeStart: CGSize?
    @State private var pendingCanvasPixelSize: CGSize?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Rectangle()
                    .strokeBorder(Color.white.opacity(0.85), lineWidth: 2)
                    .background(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(panGesture(size: panReferenceSize))
                    .simultaneousGesture(magnifyGesture)
                zoomHandle
                    .position(x: -10, y: -10)
                zoomHandle
                    .position(x: geometry.size.width + 10, y: -10)
                zoomHandle
                    .position(x: -10, y: geometry.size.height + 10)
                zoomHandle
                    .position(x: geometry.size.width + 10, y: geometry.size.height + 10)
                resizeHandle(.top)
                    .position(x: geometry.size.width / 2, y: -10)
                resizeHandle(.left)
                    .position(x: -10, y: geometry.size.height / 2)
                resizeHandle(.right)
                    .position(x: geometry.size.width + 10, y: geometry.size.height / 2)
                resizeHandle(.bottom)
                    .position(x: geometry.size.width / 2, y: geometry.size.height + 10)
            }
            .onAppear {
                store.selectedClipId = clip.id
                store.selectedMediaAssetId = clip.mediaAssetId
            }
        }
    }

    private var zoomHandle: some View {
        Circle()
            .fill(Color.white)
            .frame(width: 14, height: 14)
            .shadow(radius: 2)
            .contentShape(Circle().inset(by: -10))
            .gesture(zoomGesture)
    }

    private func resizeHandle(_ edge: CanvasResizeEdge) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.white.opacity(0.95))
            .frame(width: edge.isHorizontal ? 44 : 8, height: edge.isHorizontal ? 8 : 44)
            .shadow(radius: 2)
            .contentShape(Rectangle().inset(by: -10))
            .gesture(resizeGesture(edge))
    }

    private func panGesture(size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if panStart == nil {
                    panStart = framing
                }
                let start = panStart ?? ClipFraming()
                let nextX = clamp(start.offsetX + Double(value.translation.width / max(1, size.width)) * 2, -8, 8)
                let nextY = clamp(start.offsetY + Double(value.translation.height / max(1, size.height)) * 2, -8, 8)
                var next = start
                next.offsetX = nextX
                next.offsetY = nextY
                pendingFraming = next
                onFramingChanged(next)
            }
            .onEnded { _ in
                onFramingCommitted(pendingFraming ?? framing)
                pendingFraming = nil
                panStart = nil
            }
    }

    private var zoomGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if zoomStart == nil {
                    zoomStart = framing
                }
                let start = zoomStart ?? ClipFraming()
                let delta = Double(-(value.translation.width + value.translation.height) / 240)
                var next = start
                next.zoom = clamp(start.zoom + delta, 0.25, 16)
                pendingFraming = next
                onFramingChanged(next)
            }
            .onEnded { _ in
                onFramingCommitted(pendingFraming ?? framing)
                pendingFraming = nil
                zoomStart = nil
            }
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if magnifyStart == nil {
                    magnifyStart = framing
                }
                let start = magnifyStart ?? ClipFraming()
                var next = start
                next.zoom = clamp(start.zoom * Double(value), 0.25, 16)
                pendingFraming = next
                onFramingChanged(next)
            }
            .onEnded { _ in
                onFramingCommitted(pendingFraming ?? framing)
                pendingFraming = nil
                magnifyStart = nil
            }
    }

    private func resizeGesture(_ edge: CanvasResizeEdge) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if resizeStart == nil {
                    resizeStart = canvasPixelSize
                }
                let start = resizeStart ?? CGSize(width: 1920, height: 1080)
                let multiplier: CGFloat = 4
                var width = start.width
                var height = start.height
                switch edge {
                case .left:
                    width -= value.translation.width * multiplier
                case .right:
                    width += value.translation.width * multiplier
                case .top:
                    height -= value.translation.height * multiplier
                case .bottom:
                    height += value.translation.height * multiplier
                }
                let next = CGSize(width: min(7680, max(320, width)), height: min(4320, max(180, height)))
                pendingCanvasPixelSize = next
                onCanvasPixelSizeChanged(next)
            }
            .onEnded { _ in
                onCanvasPixelSizeCommitted(pendingCanvasPixelSize ?? canvasPixelSize)
                pendingCanvasPixelSize = nil
                resizeStart = nil
            }
    }

    private func clamp(_ value: Double, _ minimum: Double, _ maximum: Double) -> Double {
        min(maximum, max(minimum, value))
    }
}

private struct RenderCanvasFrameOverlay: View {
    let canvasPixelSize: CGSize
    let onCanvasPixelSizeChanged: (CGSize) -> Void
    let onCanvasPixelSizeCommitted: (CGSize) -> Void
    @State private var resizeStart: CGSize?
    @State private var pendingCanvasPixelSize: CGSize?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Rectangle()
                    .strokeBorder(Color.white.opacity(0.85), lineWidth: 2)
                    .background(Color.clear)
                    .allowsHitTesting(false)
                resizeHandle(.top)
                    .position(x: geometry.size.width / 2, y: -10)
                resizeHandle(.left)
                    .position(x: -10, y: geometry.size.height / 2)
                resizeHandle(.right)
                    .position(x: geometry.size.width + 10, y: geometry.size.height / 2)
                resizeHandle(.bottom)
                    .position(x: geometry.size.width / 2, y: geometry.size.height + 10)
            }
        }
    }

    private func resizeHandle(_ edge: CanvasResizeEdge) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.white.opacity(0.95))
            .frame(width: edge.isHorizontal ? 44 : 8, height: edge.isHorizontal ? 8 : 44)
            .shadow(radius: 2)
            .contentShape(Rectangle().inset(by: -10))
            .gesture(resizeGesture(edge))
    }

    private func resizeGesture(_ edge: CanvasResizeEdge) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if resizeStart == nil {
                    resizeStart = canvasPixelSize
                }
                let start = resizeStart ?? CGSize(width: 1920, height: 1080)
                let multiplier: CGFloat = 4
                var width = start.width
                var height = start.height
                switch edge {
                case .left:
                    width -= value.translation.width * multiplier
                case .right:
                    width += value.translation.width * multiplier
                case .top:
                    height -= value.translation.height * multiplier
                case .bottom:
                    height += value.translation.height * multiplier
                }
                let next = CGSize(width: min(7680, max(320, width)), height: min(4320, max(180, height)))
                pendingCanvasPixelSize = next
                onCanvasPixelSizeChanged(next)
            }
            .onEnded { _ in
                onCanvasPixelSizeCommitted(pendingCanvasPixelSize ?? canvasPixelSize)
                pendingCanvasPixelSize = nil
                resizeStart = nil
            }
    }
}

private enum CanvasResizeEdge {
    case left
    case right
    case top
    case bottom

    var isHorizontal: Bool {
        self == .top || self == .bottom
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
    @State private var showSyncSection = true
    @State private var showTempoSection = true
    @State private var showCameraSection = true
    @State private var showCalibrationSection = true
    @State private var showAudioSection = false
    @State private var showClipSection = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Inspector")
            Form {
                DisclosureGroup("Sync Status", isExpanded: $showSyncSection) {
                    LabeledContent("Sync State", value: syncEngine.state.rawValue)
                    LabeledContent("Playhead", value: formatTimelineSeconds(syncEngine.displaySeconds, frameRate: store.project.frameRate, format: store.clockDisplayFormat))
                    LabeledContent("MIDI Source", value: syncEngine.connectedSourceNames.isEmpty ? "Not connected" : syncEngine.connectedSourceNames.joined(separator: ", "))
                    if let error = syncEngine.lastErrorMessage {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }

                DisclosureGroup("Tempo Grid", isExpanded: $showTempoSection) {
                    TextField("Project tempo BPM", text: $tempoText)
                        .focused($isTempoFieldFocused)
                        .onSubmit {
                            saveTempo()
                            isTempoFieldFocused = false
                        }
                    HStack {
                        Button("Apply Tempo") {
                            saveTempo()
                            isTempoFieldFocused = false
                        }
                        if let detectedTempo = syncEngine.detectedTempoBPM {
                            Button("Use \(String(format: "%.1f", detectedTempo)) BPM") {
                                tempoText = String(format: "%.2f", detectedTempo)
                                saveTempo()
                            }
                        }
                    }
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

                DisclosureGroup("Camera / Input", isExpanded: $showCameraSection) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Capture Source")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        ForEach(cameraEngine.availableDevices) { device in
                            Button {
                                selectCaptureSource(id: device.id, clearMedia: true)
                            } label: {
                                HStack {
                                    Image(systemName: sourceIcon(for: device.kind))
                                    Text(device.displayName)
                                    Spacer()
                                    if cameraEngine.selectedDeviceID == device.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Picker("Input", selection: cameraSelection) {
                        ForEach(cameraEngine.availableDevices) { device in
                            Text(device.displayName).tag(Optional(device.id))
                        }
                    }
                    HStack {
                        Button("Refresh Cameras") {
                            cameraEngine.refreshDevices()
                            if cameraEngine.isPreviewing {
                                cameraEngine.startPreview()
                            }
                        }
                        Button(cameraEngine.isPreviewing ? "Restart Preview" : "Start Preview") {
                            cameraEngine.startPreview()
                        }
                    }
                    if cameraEngine.selectedDeviceID?.hasPrefix("screen:") == true || cameraEngine.selectedDeviceID?.hasPrefix("window:") == true {
                        HStack {
                            Button("Show Region Box") {
                                captureRegionController.show()
                            }
                            Button("Hide Region Box") {
                                captureRegionController.hide()
                            }
                        }
                    }
                    TextField("Latency ms", text: $latencyText)
                        .onSubmit {
                            saveLatency()
                        }
                    HStack {
                        Button("Estimate") {
                            applyEstimatedLatency()
                        }
                        Button("Apply Latency") {
                            saveLatency()
                        }
                    }
                    LabeledContent("Capture Delay", value: "\(store.captureLatencyMs(for: cameraEngine.selectedDeviceID)) ms")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Calibrate From Observed Times")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        TextField("Logic time seconds", text: $logicObservedText)
                        TextField("CamOrder playback seconds", text: $camObservedText)
                        HStack {
                            Button("Playback Offset") {
                                applyObservedDelta()
                            }
                            Button("Capture Delay") {
                                applyObservedCaptureDelay()
                            }
                        }
                        if let clip = selectedClip {
                            LabeledContent("Playback Sync", value: String(format: "%.3f s", store.effectivePlaybackSyncOffsetSeconds(for: clip)))
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Playback Sync Offset")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        TextField("Playback sync seconds", text: $playbackSyncText)
                        HStack {
                            Button("Save for Input") {
                                savePlaybackSyncOffset()
                            }
                            Button("App Default") {
                                savePlaybackSyncOffsetAsAppDefault()
                            }
                            Button("Selected") {
                                applyPlaybackSyncOffsetToSelected()
                            }
                        }
                        HStack {
                            Button("This Input") {
                                applyPlaybackSyncOffsetToInputClips()
                            }
                            Button("All Regions") {
                                applyPlaybackSyncOffsetToAllClips()
                            }
                        }
                    }
                    if let error = cameraEngine.lastErrorMessage {
                        Text(error)
                            .foregroundStyle(.red)
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
                        Button("Apply Audio Offset") {
                            saveAudioOffset()
                        }
                        Button("Reset") {
                            audioOffsetText = formatSeconds(0)
                            saveAudioOffset()
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
                            .onSubmit { saveCanvasSize() }
                        TextField("Height px", text: $canvasHeightText)
                            .onSubmit { saveCanvasSize() }
                        Button("Apply") {
                            saveCanvasSize()
                        }
                    }
                    LabeledContent("Canvas Size", value: "\(store.project.exportSettings.canvasWidth ?? 1920)x\(store.project.exportSettings.canvasHeight ?? 1080)")
                    LabeledContent("Current Offset", value: "\(formatSeconds(store.project.audio.audioOffsetSeconds)) s")
                }

                if let clip = selectedClip {
                    DisclosureGroup("Selected Clip", isExpanded: $showClipSection) {
                        LabeledContent("Start", value: formatTimelineSeconds(clip.timelineStartSeconds, frameRate: clip.frameRate, format: store.clockDisplayFormat))
                        LabeledContent("Duration", value: String(format: "%.2f s", clip.durationSeconds))
                        LabeledContent("Lane", value: clip.armedLaneId)
                        LabeledContent("Capture Delay", value: "\(clip.captureLatencyMs) ms")
                        LabeledContent("Playback Sync", value: String(format: "%.3f s", store.effectivePlaybackSyncOffsetSeconds(for: clip)))
                        Slider(
                            value: Binding(
                                get: { clip.framing?.zoom ?? 1 },
                                set: { store.updateSelectedClipFraming(zoom: $0) }
                            ),
                            in: 0.25...16
                        ) {
                            Text("Zoom")
                        }
                        LabeledContent("Zoom", value: String(format: "%.2fx", clip.framing?.zoom ?? 1))
                        Slider(
                            value: Binding(
                                get: { clip.framing?.offsetX ?? 0 },
                                set: { store.updateSelectedClipFraming(offsetX: $0) }
                            ),
                            in: -8...8
                        ) {
                            Text("Pan X")
                        }
                        Slider(
                            value: Binding(
                                get: { clip.framing?.offsetY ?? 0 },
                                set: { store.updateSelectedClipFraming(offsetY: $0) }
                            ),
                            in: -8...8
                        ) {
                            Text("Pan Y")
                        }
                        Slider(
                            value: Binding(
                                get: { clip.framing?.rotationDegrees ?? 0 },
                                set: {
                                    store.updateSelectedClipFraming(
                                        rotationDegrees: $0,
                                        trackUndo: false,
                                        save: false,
                                        origin: .inspector
                                    )
                                }
                            ),
                            in: -180...180,
                            onEditingChanged: { isEditing in
                                if !isEditing {
                                    saveCurrentSelectedClipRotation()
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
                        LabeledContent("Rotate", value: String(format: "%.1f deg", clip.framing?.rotationDegrees ?? 0))
                        Button(role: .destructive) {
                            store.deleteSelectedClip()
                        } label: {
                            Label("Delete Region", systemImage: "trash")
                        }
                    }
                }
            }
            .formStyle(.grouped)
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
        let current = selectedClip?.framing?.rotationDegrees ?? 0
        let snapped = (current / 5).rounded() * 5
        setSelectedClipRotation(snapped + degrees)
    }

    private func setSelectedClipRotation(_ degrees: Double) {
        let normalized = normalizeRotation(degrees)
        store.updateSelectedClipFraming(rotationDegrees: normalized, trackUndo: true, save: true, origin: .inspector)
    }

    private func saveCurrentSelectedClipRotation() {
        let current = selectedClip?.framing?.rotationDegrees ?? 0
        store.updateSelectedClipFraming(rotationDegrees: normalizeRotation(current), trackUndo: true, save: true, origin: .inspector)
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
    @ObservedObject var syncEngine: LogicSyncEngine
    @ObservedObject var editPlayback: EditPlaybackController
    let secondsToPixels: Double
    @Binding var timelineZoom: Double
    @State private var lastAutoScrollAnchor = -1

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                SectionHeader("Timeline")
                Button {
                    store.addLane()
                } label: {
                    Label("Add Camera Lane", systemImage: "plus")
                }
                .padding(.trailing, 10)
                Slider(value: $timelineZoom, in: 4...48) {
                    Text("Zoom")
                }
                .frame(width: 180)
                Text("\(Int(timelineZoom)) px/s")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Divider()
                    .frame(height: 18)
                Button("Cut at Playhead") {
                    store.cutSelectedClip(at: activePlayheadSeconds)
                }
                .disabled(store.selectedClip() == nil)
                Button("Snap Start") {
                    store.snapSelectedClipStartToGrid()
                }
                .disabled(store.selectedClip() == nil)
                Button("Snap End") {
                    store.snapSelectedClipEndToGrid()
                }
                .disabled(store.selectedClip() == nil)
                Button("Delete") {
                    store.deleteSelectedClip()
                }
                .disabled(store.selectedClip() == nil)
            }
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Timecode")
                        .font(.caption.bold())
                        .frame(width: 150, height: 28, alignment: .leading)
                    ForEach(store.project.timeline.lanes) { lane in
                        LaneHeader(lane: lane)
                            .frame(width: 150, height: 56, alignment: .leading)
                    }
                    Text("Master Audio")
                        .font(.caption.bold())
                        .frame(width: 150, height: 34, alignment: .leading)
                }
                .padding(.leading, 12)
                .padding(.vertical, 12)
                .background(Color(nsColor: .windowBackgroundColor))

                ScrollViewReader { proxy in
                    ScrollView([.horizontal, .vertical]) {
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
                                            .fill(lane.isArmed ? Color.red.opacity(0.11) : Color(nsColor: .controlBackgroundColor))
                                            .frame(width: timelineWidth, height: 56)
                                            .overlay(alignment: .leading) {
                                                timelineGrid(height: 56)
                                            }
                                        ForEach(lane.clips) { clip in
                                            ClipBlock(
                                                clip: clip,
                                                secondsToPixels: secondsToPixels,
                                                isSelected: store.selectedClipId == clip.id,
                                                onMove: { startSeconds in
                                                    store.updateClipStart(clip.id, startSeconds: startSeconds)
                                                },
                                                onResizeStart: { startSeconds in
                                                    store.updateClipLeftEdge(clip.id, startSeconds: startSeconds)
                                                },
                                                onResizeEnd: { durationSeconds in
                                                    store.updateClipDuration(clip.id, durationSeconds: durationSeconds)
                                                }
                                            )
                                                .offset(x: clip.timelineStartSeconds * secondsToPixels)
                                                .onTapGesture {
                                                    store.selectedClipId = clip.id
                                                    store.selectedMediaAssetId = clip.mediaAssetId
                                                }
                                                .contextMenu {
                                                    Button(role: .destructive) {
                                                        store.deleteClip(clip.id)
                                                    } label: {
                                                        Label("Delete Region", systemImage: "trash")
                                                    }
                                                }
                                        }
                                        if let pending = store.pendingTake, pending.laneId == lane.id {
                                            PendingClipBlock(startSeconds: pending.startSeconds, currentSeconds: syncEngine.displaySeconds, secondsToPixels: secondsToPixels)
                                                .offset(x: pending.startSeconds * secondsToPixels)
                                        }
                                    }
                                }
                                Rectangle()
                                    .fill(Color.blue.opacity(0.18))
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
                                    }
                            }
                            .padding(.vertical, 12)

                        Rectangle()
                                .fill(Color.red)
                                .frame(width: 2, height: timelineContentHeight)
                                .offset(x: activePlayheadSeconds * secondsToPixels, y: 12)
                        }
                    }
                    .onChange(of: Int(activePlayheadSeconds)) { second in
                        let anchor = max(0, (second / 5) * 5)
                        guard anchor != lastAutoScrollAnchor else { return }
                        lastAutoScrollAnchor = anchor
                        withAnimation(.linear(duration: 0.12)) {
                            proxy.scrollTo("time-\(anchor)", anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private var timelineWidth: CGFloat {
        CGFloat(max(1800, (max(store.project.timeline.durationSeconds, activePlayheadSeconds) + 90) * secondsToPixels))
    }

    private var timelineContentHeight: CGFloat {
        max(120, CGFloat(store.project.timeline.lanes.count * 64 + 76))
    }

    private var activePlayheadSeconds: Double {
        editPlayback.isEditMode ? editPlayback.playheadSeconds : syncEngine.displaySeconds
    }

    private func seekTimelineIfEditing(locationX: CGFloat) {
        guard editPlayback.isEditMode else { return }
        let seconds = max(0, Double(locationX) / max(1, secondsToPixels))
        editPlayback.seek(to: seconds, audioOffsetSeconds: store.project.audio.audioOffsetSeconds)
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
                .fill(Color(nsColor: .underPageBackgroundColor))
                .frame(width: timelineWidth, height: 28)
            Canvas { context, size in
                drawGridLines(context: &context, size: size, height: 28, includeMinorTicks: true)
            }
            .frame(width: timelineWidth, height: 28)
            HStack(alignment: .top, spacing: 0) {
                ForEach(labelSeconds, id: \.self) { seconds in
                    Text(formatTimelineSeconds(seconds, frameRate: store.project.frameRate, format: store.clockDisplayFormat))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: labelWidth, height: 28, alignment: .topLeading)
                        .offset(x: CGFloat(seconds) * secondsToPixels)
                        .id("time-\(Int(seconds))")
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
        return (0..<count).map { Double($0) * step }
    }

    private var labelStepSeconds: Double {
        let barSeconds = max(0.001, 60.0 / max(1, store.tempoBPM) * 4)
        if CGFloat(barSeconds) * secondsToPixels < 70 {
            return barSeconds * 2
        }
        return barSeconds
    }

    private var labelWidth: CGFloat {
        max(90, CGFloat(labelStepSeconds) * secondsToPixels)
    }

    private func isMajorGridLine(_ seconds: Double) -> Bool {
        let barSeconds = max(0.001, 60.0 / max(1, store.tempoBPM) * 4)
        let barIndex = (seconds / barSeconds).rounded()
        return abs(seconds - (barIndex * barSeconds)) < 0.01
    }

    private func drawGridLines(context: inout GraphicsContext, size: CGSize, height: CGFloat, includeMinorTicks: Bool) {
        let maxLines = 1600
        let lineCount = min(maxLines, Int((Double(size.width) / max(1, secondsToPixels)) / gridTickSeconds) + 1)
        for index in 0...lineCount {
            let seconds = Double(index) * gridTickSeconds
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
                CameraPreviewView(session: cameraEngine.previewSession)
                    .background(.black)
            } else {
                CameraPreviewView(session: cameraEngine.previewSession)
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
                    .fill(cameraEngine.isRecording ? .red : .green)
                    .frame(width: 8, height: 8)
                Text(cameraEngine.isRecording ? "Marking take region" : "Live input")
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
    private var player: AVPlayer?
    private var currentURL: URL?
    private var wasPlaying = false
    private var lastRequestedClipSeconds: Double = -1
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

    private func configureLayers() {
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
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
        if currentURL != url {
            currentURL = url
            let newPlayer = AVPlayer(url: url)
            newPlayer.automaticallyWaitsToMinimizeStalling = false
            playerLayer.player = newPlayer
            player = newPlayer
            wasPlaying = false
            lastRequestedClipSeconds = -1
        }
        currentFraming = framing
        apply(framing: framing)
        let desiredClipSeconds = max(0, trimInSeconds + playheadSeconds - clipStartSeconds + playbackSyncOffsetSeconds)
        chaseToLogicTime(desiredClipSeconds: desiredClipSeconds, isPlaying: isPlaying)
        wasPlaying = isPlaying
    }

    private func chaseToLogicTime(desiredClipSeconds: Double, isPlaying: Bool) {
        guard let player else { return }
        let actualClipSeconds = player.currentTime().seconds
        let drift = abs(actualClipSeconds - desiredClipSeconds)
        let transportChanged = wasPlaying != isPlaying
        let playheadJumped = abs(desiredClipSeconds - lastRequestedClipSeconds) > 0.20
        let tolerance = isPlaying ? 0.035 : 0.005

        if transportChanged || playheadJumped || drift > tolerance {
            let time = CMTime(seconds: desiredClipSeconds, preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        player.rate = isPlaying ? 1 : 0
        lastRequestedClipSeconds = desiredClipSeconds
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Lane Name", text: laneName)
                .font(.caption.bold())
                .textFieldStyle(.plain)
            HStack(spacing: 6) {
                if lane.isArmed {
                    Button("Armed") {
                        store.armLane(lane.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else {
                    Button("Arm") {
                        store.armLane(lane.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button {
                    store.deleteLane(lane.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(store.project.timeline.lanes.count <= 1)
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

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color.red, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.2)))
            .frame(width: max(72, (currentSeconds - startSeconds) * secondsToPixels), height: 40)
            .overlay {
                Text("recording")
                    .font(.caption2.bold())
                    .foregroundStyle(.red)
            }
    }
}

private struct ClipBlock: View {
    let clip: VideoClip
    let secondsToPixels: Double
    let isSelected: Bool
    let onMove: (Double) -> Void
    let onResizeStart: (Double) -> Void
    let onResizeEnd: (Double) -> Void

    var body: some View {
        let width = max(72, clip.durationSeconds * secondsToPixels)
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(clip.isEnabled ? Color.accentColor.opacity(0.75) : Color.gray.opacity(0.4))
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.yellow : Color.clear, lineWidth: 3)
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.white.opacity(0.45))
                    .frame(width: 6, height: 30)
                    .clipShape(Capsule())
                    .padding(.leading, 3)
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onEnded { value in
                                let deltaSeconds = value.translation.width / secondsToPixels
                                onResizeStart(clip.timelineStartSeconds + deltaSeconds)
                            }
                    )
                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .frame(width: max(44, width - 24), height: 40)
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onEnded { value in
                                let deltaSeconds = value.translation.width / secondsToPixels
                                onMove(max(0, clip.timelineStartSeconds + deltaSeconds))
                            }
                    )
                Rectangle()
                    .fill(Color.white.opacity(0.45))
                    .frame(width: 6, height: 30)
                    .clipShape(Capsule())
                    .padding(.trailing, 3)
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onEnded { value in
                                let deltaSeconds = value.translation.width / secondsToPixels
                                onResizeEnd(clip.durationSeconds + deltaSeconds)
                            }
                    )
            }
            .frame(width: width, height: 40, alignment: .trailing)
            .overlay {
                VStack(spacing: 2) {
                    Text(clip.clipId)
                        .font(.caption2.bold())
                    Text(formatTimelineSeconds(clip.timelineStartSeconds, frameRate: clip.frameRate, format: .logicTime))
                        .font(.caption2.monospacedDigit())
                }
                .lineLimit(1)
                .padding(.horizontal, 6)
            }
        }
        .frame(width: width, height: 40)
    }
}

private struct SectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .underPageBackgroundColor))
    }
}

private func formatTimelineSeconds(_ seconds: Double, frameRate: FrameRate, format: ClockDisplayFormat) -> String {
    switch format {
    case .logicTime:
        let clamped = max(0, seconds)
        let minutes = Int(clamped / 60)
        let remainder = clamped - Double(minutes * 60)
        return String(format: "%02d:%08.5f", minutes, remainder)
    case .smpte:
        return Timecode.from(seconds: seconds, frameRate: frameRate).description
    case .seconds:
        return String(format: "%.5f s", max(0, seconds))
    }
}
