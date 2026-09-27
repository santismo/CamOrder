import AppKit
import AVFoundation
import CamOrderStudioCore
import UniformTypeIdentifiers

@MainActor
final class ProjectStore: ObservableObject {
    enum FramingEditOrigin: Equatable {
        case canvas
        case inspector
    }

    struct FramingEditEvent: Equatable {
        var clipId: String
        var origin: FramingEditOrigin
        var revision: Int
    }

    var isHosted = false
    let syncCalculator = SyncCalculatorModel()
    var framingPlayheadSeconds: (() -> Double)?
    private var framingEditTime: (clipID: String, localSeconds: Double)?
    var onDocumentChange: (() -> Void)?
    @Published var lastExportURL: URL?
    @Published var document: ProjectDocument?
    @Published var selectedMediaAssetId: String?
    @Published var selectedClipId: String?
    @Published var lastError: String?
    @Published var pendingTakes: [String: PendingTakeRegion] = [:]
    @Published var captureEndSeconds: [String: Double] = [:]
    @Published var armedBuffers: [String: ArmedCaptureBuffer] = [:]
    weak var captureInputs: LaneCaptureInputs?
    var requiresLaneSource = false
    var pendingTake: PendingTakeRegion? {
        get { project.timeline.lanes.compactMap { pendingTakes[$0.id] }.first }
        set {
            if let value = newValue { pendingTakes[value.laneId] = value }
            else if let value = pendingTake { pendingTakes[value.laneId] = nil }
        }
    }
    var armedBuffer: ArmedCaptureBuffer? {
        get { project.timeline.lanes.compactMap { armedBuffers[$0.id] }.first }
        set {
            if let value = newValue { armedBuffers[value.laneId] = value }
            else if let value = armedBuffer { armedBuffers[value.laneId] = nil }
        }
    }
    var hasCaptureActivity: Bool { !pendingTakes.isEmpty || !armedBuffers.isEmpty }
    func laneIsBusy(_ id: String) -> Bool { pendingTakes[id] != nil || armedBuffers[id] != nil }

    @Published var pendingStopTimecode: Timecode?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var latestFramingEdit: FramingEditEvent?

    private var undoStack: [CamOrderProject] = []
    private var redoStack: [CamOrderProject] = []
    private let appCalibrationDefaults = AppCalibrationDefaults()

    struct PendingTakeRegion {
        var laneId: String
        var clipId: String
        var startTimecode: Timecode
        var startSeconds: Double
        var captureLatencyMs: Int
        var playbackSyncOffsetSeconds: Double
        var cameraDeviceId: String?
        var hostTime: UInt64
        var relativeVideoFile: String
        var trimInSeconds: Double
    }

    struct ArmedCaptureBuffer {
        var laneId: String
        var clipId: String
        var cameraDeviceId: String?
        var bufferStartHostTime: UInt64
        var recordingStartedHostTime: UInt64?
        var relativeVideoFile: String
        var playbackSyncOffsetSeconds: Double
    }

    struct AppPlaybackCalibration: Codable, Equatable {
        var cameraDeviceId: String
        var displayName: String
        var playbackSyncOffsetSeconds: Double
    }

    final class AppCalibrationDefaults {
        private let key = "CamOrderStudio.AppPlaybackCalibrations.v1"
        private let userDefaults: UserDefaults

        init(userDefaults: UserDefaults = .standard) {
            self.userDefaults = userDefaults
        }

        func calibration(for cameraDeviceId: String, displayName: String?) -> AppPlaybackCalibration? {
            let searchableName = "\(cameraDeviceId) \(displayName ?? "")".lowercased()
            return allCalibrations().first { calibration in
                calibration.cameraDeviceId == cameraDeviceId ||
                    (!displayNameMatchesSyntheticSource(searchableName) && calibration.displayName.lowercased() == displayName?.lowercased()) ||
                    (displayNameMatchesSyntheticSource(searchableName) && displayNameMatchesSyntheticSource(calibration.displayName.lowercased()))
            }
        }

        func save(cameraDeviceId: String, displayName: String, playbackSyncOffsetSeconds: Double) {
            var calibrations = allCalibrations()
            if let index = calibrations.firstIndex(where: { $0.cameraDeviceId == cameraDeviceId }) {
                calibrations[index] = AppPlaybackCalibration(cameraDeviceId: cameraDeviceId, displayName: displayName, playbackSyncOffsetSeconds: playbackSyncOffsetSeconds)
            } else {
                calibrations.append(AppPlaybackCalibration(cameraDeviceId: cameraDeviceId, displayName: displayName, playbackSyncOffsetSeconds: playbackSyncOffsetSeconds))
            }
            if let data = try? JSONEncoder().encode(calibrations) {
                userDefaults.set(data, forKey: key)
            }
        }

        private func allCalibrations() -> [AppPlaybackCalibration] {
            guard let data = userDefaults.data(forKey: key),
                  let calibrations = try? JSONDecoder().decode([AppPlaybackCalibration].self, from: data) else {
                return []
            }
            return calibrations
        }

        private func displayNameMatchesSyntheticSource(_ value: String) -> Bool {
            value.contains("windowed capture") ||
                value.contains("iphone") ||
                value.contains("continuity") ||
                value.contains("santi camera") ||
                value.contains("santi iphone")
        }
    }

    var project: CamOrderProject {
        get { document?.project ?? CamOrderProject.empty() }
        set {
            guard var document else { return }
            document.project = newValue
            self.document = document
        }
    }

    var selectedVideoAsset: MediaAsset? {
        project.media.first { $0.id == selectedMediaAssetId && $0.kind == .video }
    }

    var hasArmedLane: Bool {
        project.timeline.lanes.contains { $0.isArmed }
    }

    var tempoBPM: Double {
        project.timeline.tempoBPM ?? 120
    }

    var gridDivision: BeatGridDivision {
        project.timeline.gridDivision ?? .beat
    }

    var gridSeconds: Double {
        max(0.001, 60.0 / max(1, tempoBPM) * gridDivision.beats)
    }

    var clockDisplayFormat: ClockDisplayFormat {
        project.sync.clockDisplayFormat ?? .logicTime
    }

    var defaultPlaybackSyncOffsetSeconds: Double {
        project.sync.defaultPlaybackSyncOffsetSeconds ?? 0
    }

    var armedLaneName: String? {
        project.timeline.lanes.first(where: { $0.isArmed })?.name
    }

    var armedLaneId: String? {
        project.timeline.lanes.first(where: { $0.isArmed })?.id
    }

    var armedBufferLaneName: String? {
        guard let armedBuffer else { return nil }
        return project.timeline.lanes.first(where: { $0.id == armedBuffer.laneId })?.name
    }

    var hasOpenProject: Bool {
        document != nil
    }

    func unarmAllLanes() {
        guard var document else { return }
        guard document.project.timeline.lanes.contains(where: { $0.isArmed }) else { return }
        for index in document.project.timeline.lanes.indices {
            document.project.timeline.lanes[index].isArmed = false
        }
        self.document = document
        saveProject()
    }

    func createProject() {
        guard confirmClosingCurrentProject() else { return }
        let panel = NSSavePanel()
        panel.title = "Create CamOrder Studio Project"
        panel.nameFieldStringValue = "MyProject.\(ProjectDocument.fileExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: ProjectDocument.fileExtension) ?? .folder]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let projectName = url.deletingPathExtension().lastPathComponent
            document = try ProjectDocument.create(at: url, project: CamOrderProject.empty(name: projectName))
            selectedMediaAssetId = nil
            selectedClipId = nil
            lastError = nil
            clearHistory()
            onDocumentChange?()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func openProject() {
        guard confirmClosingCurrentProject() else { return }
        let panel = NSOpenPanel()
        panel.title = "Open CamOrder Studio Project"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var opened = try ProjectDocument.open(at: url)
            for index in opened.project.timeline.lanes.indices { opened.project.timeline.lanes[index].isArmed = false }
            document = opened
            selectedMediaAssetId = document?.project.media.first(where: { $0.kind == .video })?.id
            selectedClipId = nil
            lastError = nil
            clearHistory()
            onDocumentChange?()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func saveProject() {
        guard let document else { return }
        do {
            try document.save()
            onDocumentChange?()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func saveProjectAs() {
        guard !hasCaptureActivity, !hasArmedLane else {
            lastError = "Stop recording and disarm the input before saving a copy."
            return
        }
        guard let document else {
            createProject()
            return
        }

        saveProject()
        let panel = NSSavePanel()
        panel.title = "Save CamOrder Studio Project As"
        panel.nameFieldStringValue = "\(document.project.name).\(ProjectDocument.fileExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: ProjectDocument.fileExtension) ?? .folder]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        do {
            guard destinationURL.standardizedFileURL != document.folderURL.standardizedFileURL,
                  !destinationURL.standardizedFileURL.path.hasPrefix(document.folderURL.standardizedFileURL.path + "/"),
                  !FileManager.default.fileExists(atPath: destinationURL.path) else {
                lastError = "Choose a new, empty project location. Existing projects will not be replaced."
                return
            }
            try FileManager.default.copyItem(at: document.folderURL, to: destinationURL)
            var copiedDocument = try ProjectDocument.open(at: destinationURL)
            copiedDocument.project.name = destinationURL.deletingPathExtension().lastPathComponent
            try copiedDocument.save()
            self.document = copiedDocument
            lastError = nil
            clearHistory()
            onDocumentChange?()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func cancelPendingTake(message: String? = nil, laneID: String? = nil) {
        if let id = laneID ?? pendingTake?.laneId ?? armedBuffer?.laneId ?? armedLaneId {
            pendingTakes[id] = nil
            armedBuffers[id] = nil
            disarmLane(id)
        }
        pendingStopTimecode = nil
        if let message { lastError = message }
    }

    func disarmLane(_ id: String) {
        guard var document, let index = document.project.timeline.lanes.firstIndex(where: { $0.id == id }), document.project.timeline.lanes[index].isArmed else { return }
        document.project.timeline.lanes[index].isArmed = false
        self.document = document
        saveProject()
    }

    func setLaneCaptureSource(_ id: String, sourceID: String?, name: String? = nil) {
        guard var document, let index = document.project.timeline.lanes.firstIndex(where: { $0.id == id }) else { return }
        guard !document.project.timeline.lanes[index].isArmed, !laneIsBusy(id) else {
            lastError = "Disarm this lane and wait for its take to finish before changing its input."
            return
        }
        registerUndo(project: document.project)
        document.project.timeline.lanes[index].captureSourceID = sourceID
        document.project.timeline.lanes[index].captureSourceName = sourceID == nil ? nil : name
        self.document = document
        saveProject()
        captureInputs?.reconcile()
    }

    func setDefaultCaptureSource(_ sourceID: String?) {
        guard var document else { return }
        guard !document.project.timeline.lanes.contains(where: { $0.captureSourceID == nil && ($0.isArmed || laneIsBusy($0.id)) }) else {
            lastError = "Disarm the lanes using the default input and wait for their takes to finish before changing it."
            return
        }
        registerUndo(project: document.project)
        document.project.defaultCaptureSourceID = sourceID
        self.document = document
        saveProject()
        captureInputs?.reconcile()
    }

    func setLaneCaptureCrop(_ id: String, rect: CGRect?) {
        guard var document, let index = document.project.timeline.lanes.firstIndex(where: { $0.id == id }), !laneIsBusy(id) else { return }
        document.project.timeline.lanes[index].captureCrop = rect.map { [$0.minX, $0.minY, $0.width, $0.height] }
        self.document = document
        saveProject()
        captureInputs?.reconcile()
    }

    private func confirmClosingCurrentProject() -> Bool {
        guard !hasCaptureActivity, !hasArmedLane else {
            lastError = "Stop recording and disarm the input before switching projects."
            return false
        }
        guard let document else { return true }
        let hasWork = !document.project.timeline.lanes.flatMap(\.clips).isEmpty ||
            document.project.audio.masteredAudioFile != nil ||
            !document.project.media.isEmpty
        guard hasWork else { return true }

        let alert = NSAlert()
        alert.messageText = "Save current project before continuing?"
        alert.informativeText = "CamOrder Studio autosaves most changes, but saving now makes sure the current project is written before opening or creating another project."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveProject()
            return true
        case .alertSecondButtonReturn:
            return false
        default:
            return true
        }
    }

    func importVideo() {
        guard document != nil else {
            createProject()
            guard self.document != nil else { return }
            importVideo()
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Import Video"
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .audiovisualContent]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }

        Task {
            await importVideoFile(from: sourceURL)
        }
    }

    private func importVideoFile(from sourceURL: URL) async {
        guard var document else { return }

        do {
            let videoFolder = document.folderURL.appendingPathComponent("media/video")
            try FileManager.default.createDirectory(at: videoFolder, withIntermediateDirectories: true)
            let destinationURL = uniqueDestinationURL(for: sourceURL.lastPathComponent, in: videoFolder)
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

            let relativePath = "media/video/\(destinationURL.lastPathComponent)"
            let duration = await videoDurationSeconds(for: destinationURL)
            let mediaAsset = MediaAsset(
                kind: .video,
                displayName: sourceURL.deletingPathExtension().lastPathComponent,
                relativePath: relativePath,
                durationSeconds: duration,
                frameRate: document.project.frameRate
            )

            registerUndo(project: document.project)
            document.project.media.append(mediaAsset)
            ensureAtLeastOneLane(project: &document.project)
            let laneId = document.project.timeline.lanes[0].id
            let takeID = "import_" + UUID().uuidString
            let clip = VideoClip(
                clipId: takeID,
                mediaAssetId: mediaAsset.id,
                videoFile: relativePath,
                armedLaneId: laneId,
                logicStartTimecode: Timecode(hours: 0, minutes: 0, seconds: 0, frames: 0, frameRate: document.project.frameRate),
                logicStartSeconds: 0,
                durationSeconds: duration ?? 0,
                frameRate: document.project.frameRate
            )
            document.project.timeline.lanes[0].clips.append(clip)
            document.project.timeline.durationSeconds = max(document.project.timeline.durationSeconds, clip.timelineStartSeconds + clip.durationSeconds)
            try document.save()

            self.document = document
            selectedMediaAssetId = mediaAsset.id
            selectedClipId = clip.id
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func importMasterAudio() {
        guard var document else {
            createProject()
            guard self.document != nil else { return }
            importMasterAudio()
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Import Master Audio"
        panel.allowedContentTypes = [.wav, .aiff, .mpeg4Audio, .mp3, .audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }

        do {
            let audioFolder = document.folderURL.appendingPathComponent("media/audio")
            try FileManager.default.createDirectory(at: audioFolder, withIntermediateDirectories: true)
            let destinationURL = uniqueDestinationURL(for: sourceURL.lastPathComponent, in: audioFolder)
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

            let relativePath = "media/audio/\(destinationURL.lastPathComponent)"
            let mediaAsset = MediaAsset(
                kind: .audio,
                displayName: sourceURL.deletingPathExtension().lastPathComponent,
                relativePath: relativePath
            )

            registerUndo(project: document.project)
            document.project.media.append(mediaAsset)
            document.project.audio.masteredAudioFile = relativePath
            self.document = document
            saveProject()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func armLane(_ laneId: String) {
        guard var document, let target = document.project.timeline.lanes.firstIndex(where: { $0.id == laneId }) else { return }
        let shouldUnarm = document.project.timeline.lanes[target].isArmed
        if !shouldUnarm, pendingTakes[laneId] != nil {
            lastError = "This lane is still finishing a take. Stop the other lanes sharing its input before rearming it."
            return
        }
        if !shouldUnarm, requiresLaneSource, captureInputs?.sourceID(for: document.project.timeline.lanes[target]) == nil {
            lastError = "Choose an input for this lane before arming it."
            return
        }
        if !isHosted {
            for index in document.project.timeline.lanes.indices { document.project.timeline.lanes[index].isArmed = false }
        }
        document.project.timeline.lanes[target].isArmed = !shouldUnarm
        self.document = document
        saveProject()
    }

    func addLane() {
        guard var document else {
            createProject()
            return
        }
        registerUndo(project: document.project)
        let number = document.project.timeline.lanes.count + 1
        document.project.timeline.lanes.append(VideoLane(name: "Camera \(number)"))
        self.document = document
        saveProject()
    }

    func renameLane(_ laneId: String, name: String) {
        guard var document else { return }
        guard let index = document.project.timeline.lanes.firstIndex(where: { $0.id == laneId }) else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, document.project.timeline.lanes[index].name != name else { return }
        registerUndo(project: document.project)
        document.project.timeline.lanes[index].name = name
        self.document = document
        saveProject()
    }

    func deleteLane(_ laneId: String) {
        guard var document else { return }
        guard document.project.timeline.lanes.count > 1 else {
            lastError = "Keep at least one camera lane."
            return
        }
        guard let index = document.project.timeline.lanes.firstIndex(where: { $0.id == laneId }) else { return }
        if document.project.timeline.lanes[index].isArmed || laneIsBusy(laneId) {
            lastError = "Disarm this lane and wait for its take to finish before deleting it."
            return
        }
        registerUndo(project: document.project)
        let deletedClipIds = Set(document.project.timeline.lanes[index].clips.map(\.id))
        document.project.timeline.lanes.remove(at: index)
        if let selectedClipId, deletedClipIds.contains(selectedClipId) {
            self.selectedClipId = nil
            self.selectedMediaAssetId = nil
        }
        self.document = document
        saveProject()
    }

    func toggleLaneMuted(_ laneId: String) {
        guard var document else { return }
        guard let index = document.project.timeline.lanes.firstIndex(where: { $0.id == laneId }) else { return }
        registerUndo(project: document.project)
        document.project.timeline.lanes[index].isMuted.toggle()
        self.document = document
        saveProject()
    }

    func clearSelectedMedia() {
        selectedMediaAssetId = nil
    }

    func openVideoMediaFolder() {
        guard let document else {
            createProject()
            return
        }
        let url = document.folderURL.appendingPathComponent("media/video")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    func setTempoBPM(_ bpm: Double) {
        guard var document else { return }
        registerUndo(project: document.project)
        document.project.timeline.tempoBPM = max(1, bpm)
        self.document = document
        saveProject()
    }

    func setGridDivision(_ division: BeatGridDivision) {
        guard var document else { return }
        registerUndo(project: document.project)
        document.project.timeline.gridDivision = division
        self.document = document
        saveProject()
    }

    func makeGridDivisionSmaller() {
        adjustGridDivision(by: 1)
    }

    func makeGridDivisionLarger() {
        adjustGridDivision(by: -1)
    }

    func setClockDisplayFormat(_ format: ClockDisplayFormat) {
        guard var document else { return }
        registerUndo(project: document.project)
        document.project.sync.clockDisplayFormat = format
        self.document = document
        saveProject()
    }

    func setCaptureLatency(ms: Int, cameraDeviceId: String?, displayName: String) {
        guard var document else { return }
        registerUndo(project: document.project)
        let id = cameraDeviceId ?? "default-camera"
        if let index = document.project.captureLatencyProfiles.firstIndex(where: { $0.cameraDeviceId == id }) {
            document.project.captureLatencyProfiles[index].latencyMs = ms
            document.project.captureLatencyProfiles[index].displayName = displayName
        } else {
            document.project.captureLatencyProfiles.append(CaptureLatencyProfile(cameraDeviceId: id, displayName: displayName, latencyMs: ms))
        }
        self.document = document
        saveProject()
    }

    func setPlaybackSyncOffset(seconds: Double, cameraDeviceId: String?, displayName: String) {
        guard var document else { return }
        registerUndo(project: document.project)
        let id = cameraDeviceId ?? "default-camera"
        if let index = document.project.captureLatencyProfiles.firstIndex(where: { $0.cameraDeviceId == id }) {
            document.project.captureLatencyProfiles[index].playbackSyncOffsetSeconds = seconds
            document.project.captureLatencyProfiles[index].displayName = displayName
        } else {
            document.project.captureLatencyProfiles.append(CaptureLatencyProfile(cameraDeviceId: id, displayName: displayName, playbackSyncOffsetSeconds: seconds))
        }
        self.document = document
        saveProject()
    }

    func savePlaybackSyncOffsetAsAppDefault(seconds: Double, cameraDeviceId: String?, displayName: String) {
        let id = cameraDeviceId ?? "default-camera"
        appCalibrationDefaults.save(cameraDeviceId: id, displayName: displayName, playbackSyncOffsetSeconds: seconds)
        setPlaybackSyncOffset(seconds: seconds, cameraDeviceId: cameraDeviceId, displayName: displayName)
    }

    func setDefaultPlaybackSyncOffset(seconds: Double, applyToExisting: Bool) {
        guard var document else { return }
        registerUndo(project: document.project)
        document.project.sync.defaultPlaybackSyncOffsetSeconds = seconds
        if applyToExisting {
            for laneIndex in document.project.timeline.lanes.indices {
                for clipIndex in document.project.timeline.lanes[laneIndex].clips.indices {
                    document.project.timeline.lanes[laneIndex].clips[clipIndex].playbackSyncOffsetSeconds = seconds
                }
            }
        }
        self.document = document
        saveProject()
    }

    func captureLatencyMs(for cameraDeviceId: String?) -> Int {
        let id = cameraDeviceId ?? "default-camera"
        return project.captureLatencyProfiles.first(where: { $0.cameraDeviceId == id })?.latencyMs ?? defaultCaptureLatencyMs(for: id)
    }

    func playbackSyncOffsetSeconds(for cameraDeviceId: String?) -> Double {
        playbackSyncOffsetSeconds(for: cameraDeviceId, displayName: nil)
    }

    func playbackSyncOffsetSeconds(for cameraDeviceId: String?, displayName: String?) -> Double {
        // New takes use sample timestamps; no guessed camera-specific correction.
        return 0
    }

    func effectivePlaybackSyncOffsetSeconds(for clip: VideoClip) -> Double {
        // Preserve explicit adjustments in older projects without applying new guesses.
        clip.playbackSyncOffsetSeconds ?? project.sync.defaultPlaybackSyncOffsetSeconds ?? 0
    }

    func startTakeRegion(at timecode: Timecode, observedTimecode: Timecode? = nil, cameraDeviceId: String?, cameraDisplayName: String? = nil, preciseSeconds: Double? = nil, captureHostSeconds: Double? = nil, laneID: String? = nil) {
        guard let lane = project.timeline.lanes.first(where: { $0.isArmed && (laneID == nil || $0.id == laneID) }), pendingTakes[lane.id] == nil else {
            lastError = "Arm a camera lane before recording a take region."
            return
        }
        if let armedBuffer = armedBuffers[lane.id] {
            let now = DispatchTime.now().uptimeNanoseconds
            let recordingHostTime = armedBuffer.recordingStartedHostTime ?? armedBuffer.bufferStartHostTime
            let elapsedSinceBufferStarted = max(0, (captureHostSeconds ?? Double(now) / 1_000_000_000.0) - Double(recordingHostTime) / 1_000_000_000.0)
            let transportDetectionDelay = captureHostSeconds == nil ? max(0, (observedTimecode ?? timecode).secondsValue - timecode.secondsValue) : 0
            let trimInSeconds = max(0, elapsedSinceBufferStarted - transportDetectionDelay)
            pendingTakes[lane.id] = PendingTakeRegion(
                laneId: armedBuffer.laneId,
                clipId: armedBuffer.clipId,
                startTimecode: timecode,
                startSeconds: preciseSeconds ?? timecode.secondsValue,
                captureLatencyMs: 0,
                playbackSyncOffsetSeconds: armedBuffer.playbackSyncOffsetSeconds,
                cameraDeviceId: armedBuffer.cameraDeviceId,
                hostTime: recordingHostTime,
                relativeVideoFile: armedBuffer.relativeVideoFile,
                trimInSeconds: trimInSeconds
            )
            self.armedBuffers[lane.id] = nil
            return
        }
        let takeID = "take_" + UUID().uuidString
        let latency = 0
        let playbackSyncOffset = playbackSyncOffsetSeconds(for: cameraDeviceId, displayName: cameraDisplayName)
        pendingTakes[lane.id] = PendingTakeRegion(
            laneId: lane.id,
            clipId: takeID,
            startTimecode: timecode,
            startSeconds: preciseSeconds ?? timecode.secondsValue,
            captureLatencyMs: latency,
            playbackSyncOffsetSeconds: playbackSyncOffset,
            cameraDeviceId: cameraDeviceId,
            hostTime: DispatchTime.now().uptimeNanoseconds,
            relativeVideoFile: "media/video/\(takeID).mov",
            trimInSeconds: 0
        )
    }

    func startArmedBuffer(cameraDeviceId: String?, cameraDisplayName: String? = nil, laneID: String? = nil) {
        guard let lane = project.timeline.lanes.first(where: { $0.isArmed && (laneID == nil || $0.id == laneID) }), armedBuffers[lane.id] == nil, pendingTakes[lane.id] == nil else { return }
        let takeID = "take_" + UUID().uuidString
        armedBuffers[lane.id] = ArmedCaptureBuffer(
            laneId: lane.id,
            clipId: takeID,
            cameraDeviceId: cameraDeviceId,
            bufferStartHostTime: DispatchTime.now().uptimeNanoseconds,
            recordingStartedHostTime: nil,
            relativeVideoFile: "media/video/\(takeID).mov",
            playbackSyncOffsetSeconds: playbackSyncOffsetSeconds(for: cameraDeviceId, displayName: cameraDisplayName)
        )
    }

    func pendingArmedBufferURL(laneID: String? = nil) -> URL? {
        guard let armedBuffer = laneID.flatMap({ armedBuffers[$0] }) ?? (laneID == nil ? armedBuffer : nil), let document else { return nil }
        return document.absoluteURL(for: armedBuffer.relativeVideoFile)
    }

    func markArmedBufferRecordingStarted(hostTime: UInt64, laneID: String? = nil) {
        guard let id = laneID ?? armedBuffer?.laneId, armedBuffers[id] != nil else { return }
        guard armedBuffers[id]?.recordingStartedHostTime != hostTime else { return }
        armedBuffers[id]?.recordingStartedHostTime = hostTime
    }

    func discardArmedBuffer(laneID: String? = nil) {
        if let id = laneID ?? armedBuffer?.laneId { armedBuffers[id] = nil }
    }

    func pendingRecordingURL(laneID: String? = nil) -> URL? {
        guard let pendingTake = laneID.flatMap({ pendingTakes[$0] }) ?? (laneID == nil ? pendingTake : nil), let document else { return nil }
        return document.absoluteURL(for: pendingTake.relativeVideoFile)
    }

    func finishTakeRegion(at timecode: Timecode, warnings: [String] = [], preciseSeconds: Double? = nil, actualMediaDuration: Double? = nil, laneID: String? = nil) {
        guard let pendingTake = laneID.flatMap({ pendingTakes[$0] }) ?? (laneID == nil ? pendingTake : nil) else { return }
        guard var document else { return }
        guard let laneIndex = document.project.timeline.lanes.firstIndex(where: { $0.id == pendingTake.laneId }) else { return }

        let requestedDuration = max(0, (preciseSeconds ?? timecode.secondsValue) - pendingTake.startSeconds)
        let availableDuration = actualMediaDuration.map { max(0, $0 - pendingTake.trimInSeconds) } ?? requestedDuration
        let visibleDuration = min(requestedDuration, availableDuration)
        guard visibleDuration > 0, FileManager.default.fileExists(atPath: document.absoluteURL(for: pendingTake.relativeVideoFile).path) else {
            cancelPendingTake(message: "No usable video was recorded. Check the input and try again.", laneID: pendingTake.laneId)
            return
        }
        let mediaDuration = actualMediaDuration ?? (pendingTake.trimInSeconds + visibleDuration)
        let existingMedia = document.project.media.first { $0.relativePath == pendingTake.relativeVideoFile }
        let mediaAsset = existingMedia ?? MediaAsset(
            kind: .video,
            displayName: pendingTake.clipId,
            relativePath: pendingTake.relativeVideoFile,
            durationSeconds: mediaDuration,
            frameRate: timecode.frameRate
        )
        let clip = VideoClip(
            clipId: pendingTake.clipId,
            mediaAssetId: mediaAsset.id,
            videoFile: pendingTake.relativeVideoFile,
            armedLaneId: pendingTake.laneId,
            logicStartTimecode: pendingTake.startTimecode,
            logicStartSeconds: pendingTake.startSeconds,
            timelineStartSeconds: pendingTake.startSeconds,
            appCaptureStartHostTime: pendingTake.hostTime,
            captureLatencyMs: pendingTake.captureLatencyMs,
            durationSeconds: visibleDuration,
            frameRate: timecode.frameRate,
            cameraDeviceId: pendingTake.cameraDeviceId,
            droppedFrameWarnings: warnings,
            trimInSeconds: pendingTake.trimInSeconds,
            trimOutSeconds: mediaDuration,
            playbackSyncOffsetSeconds: pendingTake.playbackSyncOffsetSeconds
        )

        registerUndo(project: document.project)
        if existingMedia == nil { document.project.media.append(mediaAsset) }
        document.project.timeline.lanes[laneIndex].clips.append(clip)
        document.project.timeline.durationSeconds = max(document.project.timeline.durationSeconds, clip.timelineStartSeconds + clip.durationSeconds)
        self.document = document
        self.pendingTakes[pendingTake.laneId] = nil
        self.pendingStopTimecode = nil
        selectedMediaAssetId = mediaAsset.id
        selectedClipId = clip.id
        saveProject()
    }

    func setVideoOffsetMS(_ value: Double, laneID: String? = nil) {
        guard value.isFinite, var document else { return }
        let value = min(5000, max(-5000, value))
        registerUndo(project: document.project)
        if let laneID {
            guard let index = document.project.timeline.lanes.firstIndex(where: { $0.id == laneID }) else { return }
            document.project.timeline.lanes[index].videoOffsetMS = value
        } else { document.project.sync.videoOffsetMS = value }
        self.document = document
        saveProject()
    }

    func beginSelectedClipFramingEdit() {
        guard let selectedClipId else { return }
        beginClipFramingEdit(selectedClipId)
    }

    func beginClipFramingEdit(_ clipId: String) {
        guard let document, let clip = clip(id: clipId) else { return }
        framingEditTime = nil
        framingEditTime = (clipId, framingLocalSeconds(for: clip))
        registerUndo(project: document.project)
    }

    func endClipFramingEdit() { framingEditTime = nil; saveProject() }

    func framingLocalSeconds(for clip: VideoClip) -> Double {
        if let edit = framingEditTime, edit.clipID == clip.id { return edit.localSeconds }
        return min(clip.durationSeconds, max(0, (framingPlayheadSeconds?() ?? clip.timelineStartSeconds)
            - project.presentedClip(clip).timelineStartSeconds))
    }

    func framingForEditing(_ clip: VideoClip) -> ClipFraming {
        clip.automatedFraming(atLocalSecond: framingLocalSeconds(for: clip))
    }

    func updateSelectedClipFraming(zoom: Double? = nil, offsetX: Double? = nil, offsetY: Double? = nil, rotationDegrees: Double? = nil, trackUndo: Bool = true, save: Bool = false, origin: FramingEditOrigin = .inspector) {
        guard let selectedClipId else { return }
        updateClipFraming(selectedClipId, zoom: zoom, offsetX: offsetX, offsetY: offsetY,
                          rotationDegrees: rotationDegrees, trackUndo: trackUndo, save: save, origin: origin)
    }

    func updateClipFraming(_ clipId: String, zoom: Double? = nil, offsetX: Double? = nil, offsetY: Double? = nil,
                           rotationDegrees: Double? = nil, referenceLocalSeconds: Double? = nil,
                           trackUndo: Bool = true, save: Bool = false, origin: FramingEditOrigin = .inspector) {
        guard var document else { return }
        for laneIndex in document.project.timeline.lanes.indices {
            guard let clipIndex = document.project.timeline.lanes[laneIndex].clips.firstIndex(where: { $0.id == clipId }) else { continue }
            if trackUndo { registerUndo(project: document.project) }
            var clip = document.project.timeline.lanes[laneIndex].clips[clipIndex]
            let localSeconds = referenceLocalSeconds ?? framingLocalSeconds(for: clip)
            let reference = clip.automatedFraming(atLocalSecond: localSeconds)
            var target = reference
            if let zoom { target.zoom = min(16, max(0.25, zoom)) }
            if let offsetX { target.offsetX = min(8, max(-8, offsetX)) }
            if let offsetY { target.offsetY = min(8, max(-8, offsetY)) }
            if let rotationDegrees { target.rotationDegrees = rotationDegrees }
            if clip.automationMarkers.isEmpty {
                clip.framing = target
            } else {
                // With animation enabled, edit the pose at this time, not every key.
                clip.setAutomationFraming(target, atLocalSecond: localSeconds)
            }
            document.project.timeline.lanes[laneIndex].clips[clipIndex] = clip
            self.document = document
            latestFramingEdit = FramingEditEvent(clipId: clipId, origin: origin, revision: (latestFramingEdit?.revision ?? 0) + 1)
            if save { saveProject() }
            return
        }
    }

    func updateSelectedClipLatency(ms: Int) {
        guard let selectedClipId else { return }
        guard var document else { return }
        for laneIndex in document.project.timeline.lanes.indices {
            guard let clipIndex = document.project.timeline.lanes[laneIndex].clips.firstIndex(where: { $0.id == selectedClipId }) else {
                continue
            }
            registerUndo(project: document.project)
            let logicStartSeconds = document.project.timeline.lanes[laneIndex].clips[clipIndex].logicStartSeconds
            document.project.timeline.lanes[laneIndex].clips[clipIndex].captureLatencyMs = ms
            document.project.timeline.lanes[laneIndex].clips[clipIndex].timelineStartSeconds = VideoClip.timelineStart(logicStartSeconds: logicStartSeconds, captureLatencyMs: ms)
            self.document = document
            saveProject()
            return
        }
    }

    func updateSelectedClipPlaybackSyncOffset(seconds: Double) {
        guard let selectedClipId else { return }
        guard var document else { return }
        for laneIndex in document.project.timeline.lanes.indices {
            guard let clipIndex = document.project.timeline.lanes[laneIndex].clips.firstIndex(where: { $0.id == selectedClipId }) else {
                continue
            }
            registerUndo(project: document.project)
            document.project.timeline.lanes[laneIndex].clips[clipIndex].playbackSyncOffsetSeconds = seconds
            self.document = document
            saveProject()
            return
        }
    }

    func setMasterAudioOffset(seconds: Double) {
        guard var document else { return }
        registerUndo(project: document.project)
        document.project.audio.audioOffsetSeconds = seconds
        self.document = document
        saveProject()
    }

    func setExportAudioMode(_ mode: ExportAudioMode) {
        guard var document else { return }
        registerUndo(project: document.project)
        document.project.exportSettings.audioMode = mode
        self.document = document
        saveProject()
    }

    func setExportContainer(_ container: ExportContainer) {
        guard var document else { return }
        registerUndo(project: document.project)
        document.project.exportSettings.container = container
        self.document = document
        saveProject()
    }

    func setExportResolution(_ resolution: ExportResolution) {
        guard var document else { return }
        registerUndo(project: document.project)
        document.project.exportSettings.resolution = resolution
        switch resolution {
        case .hd1080: document.project.exportSettings.canvasWidth = 1920; document.project.exportSettings.canvasHeight = 1080
        case .uhd4k: document.project.exportSettings.canvasWidth = 3840; document.project.exportSettings.canvasHeight = 2160
        case .source: break
        }
        self.document = document
        saveProject()
    }

    func setExportCanvasSize(width: Int, height: Int, save: Bool = true) {
        guard var document else { return }
        let clampedWidth = min(max(width, 320), 7680)
        let clampedHeight = min(max(height, 180), 4320)
        if document.project.exportSettings.canvasWidth == clampedWidth,
           document.project.exportSettings.canvasHeight == clampedHeight {
            if save {
                saveProject()
            }
            return
        }
        if save {
            registerUndo(project: document.project)
        }
        document.project.exportSettings.canvasWidth = clampedWidth
        document.project.exportSettings.canvasHeight = clampedHeight
        self.document = document
        if save {
            saveProject()
        }
    }

    func updatePlaybackSyncOffsetForClips(seconds: Double, cameraDeviceId: String?) {
        guard var document else { return }
        let hasMatchingClip = document.project.timeline.lanes.flatMap(\.clips).contains { clip in
            cameraDeviceId == nil || clip.cameraDeviceId == cameraDeviceId
        }
        guard hasMatchingClip else { return }
        registerUndo(project: document.project)
        var changed = false
        for laneIndex in document.project.timeline.lanes.indices {
            for clipIndex in document.project.timeline.lanes[laneIndex].clips.indices {
                if cameraDeviceId == nil || document.project.timeline.lanes[laneIndex].clips[clipIndex].cameraDeviceId == cameraDeviceId {
                    document.project.timeline.lanes[laneIndex].clips[clipIndex].playbackSyncOffsetSeconds = seconds
                    changed = true
                }
            }
        }
        guard changed else { return }
        self.document = document
        saveProject()
    }

    func snapSelectedClipStartToGrid() {
        editSelectedClipOnGrid { clip, gridSeconds in
            let offset = project.videoOffsetSeconds(forLane: clip.armedLaneId)
            let snappedStart = ((clip.timelineStartSeconds + offset) / gridSeconds).rounded() * gridSeconds - offset
            clip.trimLeftEdge(to: snappedStart)
        }
    }

    func snapSelectedClipEndToGrid() {
        editSelectedClipOnGrid { clip, gridSeconds in
            let end = clip.timelineStartSeconds + clip.durationSeconds
            let offset = project.videoOffsetSeconds(forLane: clip.armedLaneId)
            let snappedEnd = max(clip.timelineStartSeconds + 0.1, ((end + offset) / gridSeconds).rounded() * gridSeconds - offset)
            clip.durationSeconds = max(0.1, snappedEnd - clip.timelineStartSeconds)
        }
    }

    func extendSelectedClipByGrid() {
        editSelectedClipOnGrid { clip, gridSeconds in
            clip.durationSeconds += gridSeconds
        }
    }

    func shortenSelectedClipByGrid() {
        editSelectedClipOnGrid { clip, gridSeconds in
            clip.durationSeconds = max(0.1, clip.durationSeconds - gridSeconds)
        }
    }

    func cutSelectedClip(at seconds: Double) {
        guard let selectedClipId else { return }
        guard var document else { return }
        for laneIndex in document.project.timeline.lanes.indices {
            guard let clipIndex = document.project.timeline.lanes[laneIndex].clips.firstIndex(where: { $0.id == selectedClipId }) else {
                continue
            }
            let clip = document.project.timeline.lanes[laneIndex].clips[clipIndex]
            let seconds = seconds - document.project.videoOffsetSeconds(forLane: document.project.timeline.lanes[laneIndex].id)
            guard seconds > clip.timelineStartSeconds + 0.05, seconds < clip.timelineStartSeconds + clip.durationSeconds - 0.05 else {
                return
            }
            registerUndo(project: document.project)
            guard let (firstClip, secondClip) = clip.split(at: seconds) else { return }
            document.project.timeline.lanes[laneIndex].clips[clipIndex] = firstClip
            document.project.timeline.lanes[laneIndex].clips.insert(secondClip, at: clipIndex + 1)
            self.selectedClipId = secondClip.id
            selectedMediaAssetId = secondClip.mediaAssetId
            self.document = document
            saveProject()
            return
        }
    }

    func canInsertAutomationMarker(at timelineSeconds: Double) -> Bool {
        automationClipLocation(at: timelineSeconds) != nil
    }

    func insertAutomationMarker(at timelineSeconds: Double, framing explicitFraming: ClipFraming? = nil) {
        guard var document else { return }
        guard let location = automationClipLocation(at: timelineSeconds, in: document.project) else {
            lastError = "Select a region or place the playhead over a region before inserting an automation marker."
            return
        }

        registerUndo(project: document.project)
        var clip = document.project.timeline.lanes[location.laneIndex].clips[location.clipIndex]
        let localSeconds = min(max(0, timelineSeconds - document.project.presentedClip(clip).timelineStartSeconds), clip.durationSeconds)
        let markerFraming = explicitFraming ?? clip.automatedFraming(atLocalSecond: localSeconds)
        clip.setAutomationFraming(markerFraming, atLocalSecond: localSeconds)
        document.project.timeline.lanes[location.laneIndex].clips[location.clipIndex] = clip
        self.document = document
        selectedClipId = clip.id
        selectedMediaAssetId = clip.mediaAssetId
        saveProject()
    }

    func deleteNearestAutomationMarker(at timelineSeconds: Double) {
        guard var document else { return }
        guard let location = automationClipLocation(at: timelineSeconds, in: document.project) else { return }
        var clip = document.project.timeline.lanes[location.laneIndex].clips[location.clipIndex]
        guard !clip.automationMarkers.isEmpty else { return }
        let localSeconds = min(max(0, timelineSeconds - document.project.presentedClip(clip).timelineStartSeconds), clip.durationSeconds)
        guard let markerIndex = clip.automationMarkers.indices.min(by: {
            abs(clip.automationMarkers[$0].timeSeconds - localSeconds) < abs(clip.automationMarkers[$1].timeSeconds - localSeconds)
        }) else {
            return
        }
        registerUndo(project: document.project)
        clip.automationMarkers.remove(at: markerIndex)
        document.project.timeline.lanes[location.laneIndex].clips[location.clipIndex] = clip
        self.document = document
        saveProject()
    }

    func deleteAutomationMarker(_ markerId: String, in clipId: String) {
        guard var document else { return }
        for laneIndex in document.project.timeline.lanes.indices {
            guard let clipIndex = document.project.timeline.lanes[laneIndex].clips.firstIndex(where: { $0.id == clipId }) else {
                continue
            }
            guard document.project.timeline.lanes[laneIndex].clips[clipIndex].automationMarkers.contains(where: { $0.id == markerId }) else { return }
            registerUndo(project: document.project)
            document.project.timeline.lanes[laneIndex].clips[clipIndex].automationMarkers.removeAll { $0.id == markerId }
            self.document = document
            saveProject()
            return
        }
    }

    func clearSelectedClipAutomation() {
        guard let selectedClipId else { return }
        guard var document else { return }
        for laneIndex in document.project.timeline.lanes.indices {
            guard let clipIndex = document.project.timeline.lanes[laneIndex].clips.firstIndex(where: { $0.id == selectedClipId }) else {
                continue
            }
            guard !document.project.timeline.lanes[laneIndex].clips[clipIndex].automationMarkers.isEmpty else { return }
            registerUndo(project: document.project)
            document.project.timeline.lanes[laneIndex].clips[clipIndex].automationMarkers.removeAll()
            self.document = document
            saveProject()
            return
        }
    }

    func updateClipStart(_ clipId: String, startSeconds: Double) {
        editClip(clipId) { clip in
            clip.timelineStartSeconds = max(0, startSeconds - project.videoOffsetSeconds(forLane: clip.armedLaneId))
        }
    }

    func updateClipLeftEdge(_ clipId: String, startSeconds: Double) {
        editClip(clipId) { clip in
            clip.trimLeftEdge(to: startSeconds - project.videoOffsetSeconds(forLane: clip.armedLaneId))
        }
    }

    func updateClipDuration(_ clipId: String, durationSeconds: Double) {
        editClip(clipId) { clip in
            clip.durationSeconds = max(0.1, durationSeconds)
        }
    }

    func deleteSelectedClip() {
        guard let selectedClipId else { return }
        deleteClip(selectedClipId)
    }

    func deleteClip(_ clipId: String) {
        guard var document else { return }
        var removedMediaAssetId: String?
        for laneIndex in document.project.timeline.lanes.indices {
            guard let clipIndex = document.project.timeline.lanes[laneIndex].clips.firstIndex(where: { $0.id == clipId }) else {
                continue
            }
            registerUndo(project: document.project)
            removedMediaAssetId = document.project.timeline.lanes[laneIndex].clips[clipIndex].mediaAssetId
            document.project.timeline.lanes[laneIndex].clips.remove(at: clipIndex)
            break
        }
        if let removedMediaAssetId, !isMediaAssetReferenced(removedMediaAssetId, in: document.project) {
            document.project.media.removeAll { $0.id == removedMediaAssetId }
        }
        if selectedClipId == clipId {
            selectedClipId = nil
            if selectedMediaAssetId == removedMediaAssetId {
                selectedMediaAssetId = nil
            }
        }
        self.document = document
        saveProject()
    }

    func undoProjectChange() {
        guard var document, let previous = undoStack.popLast() else { return }
        framingEditTime = nil
        redoStack.append(document.project)
        document.project = restoringHistory(previous, preservingRuntimeFrom: document.project)
        self.document = document
        reconcileSelection()
        updateUndoRedoState()
        saveProject()
    }

    func redoProjectChange() {
        guard var document, let next = redoStack.popLast() else { return }
        framingEditTime = nil
        undoStack.append(document.project)
        document.project = restoringHistory(next, preservingRuntimeFrom: document.project)
        self.document = document
        reconcileSelection()
        updateUndoRedoState()
        saveProject()
    }

    private func restoringHistory(_ snapshot: CamOrderProject, preservingRuntimeFrom current: CamOrderProject) -> CamOrderProject {
        var restored = snapshot
        // Arm state and capture connections are live controls, never undoable edits.
        for index in restored.timeline.lanes.indices {
            let id = restored.timeline.lanes[index].id
            let live = current.timeline.lanes.first { $0.id == id }
            restored.timeline.lanes[index].isArmed = live?.isArmed ?? false
            if let live, live.isArmed || laneIsBusy(id) {
                restored.timeline.lanes[index].captureSourceID = live.captureSourceID
                restored.timeline.lanes[index].captureSourceName = live.captureSourceName
                restored.timeline.lanes[index].captureCrop = live.captureCrop
            }
        }
        for (index, lane) in current.timeline.lanes.enumerated() where (lane.isArmed || laneIsBusy(lane.id)) && !restored.timeline.lanes.contains(where: { $0.id == lane.id }) {
            restored.timeline.lanes.insert(lane, at: min(index, restored.timeline.lanes.count))
        }
        if hasArmedLane || hasCaptureActivity { restored.defaultCaptureSourceID = current.defaultCaptureSourceID }
        return restored
    }

    func selectedClip() -> VideoClip? {
        project.timeline.lanes.flatMap(\.clips).first { $0.id == selectedClipId }
    }

    func clip(id: String) -> VideoClip? {
        project.timeline.lanes.lazy.flatMap(\.clips).first { $0.id == id }
    }

    func playbackClip(at seconds: Double) -> VideoClip? {
        project.playbackClip(at: seconds)
    }

    func mediaAsset(for clip: VideoClip) -> MediaAsset? {
        project.media.first { $0.id == clip.mediaAssetId }
    }

    func absoluteURL(for asset: MediaAsset) -> URL? {
        document?.absoluteURL(for: asset.relativePath)
    }

    func absoluteURL(for relativePath: String) -> URL? {
        document?.absoluteURL(for: relativePath)
    }

    private func ensureAtLeastOneLane(project: inout CamOrderProject) {
        if project.timeline.lanes.isEmpty {
            project.timeline.lanes.append(VideoLane(id: "lane_1", name: "Lane 1"))
        }
    }

    private func registerUndo(project: CamOrderProject) {
        undoStack.append(project)
        if undoStack.count > 100 {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
        updateUndoRedoState()
    }

    private func clearHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        updateUndoRedoState()
    }

    private func updateUndoRedoState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    private func reconcileSelection() {
        let mediaIds = Set(project.media.map(\.id))
        let clipIds = Set(project.timeline.lanes.flatMap(\.clips).map(\.id))
        if let selectedMediaAssetId, !mediaIds.contains(selectedMediaAssetId) {
            self.selectedMediaAssetId = nil
        }
        if let selectedClipId, !clipIds.contains(selectedClipId) {
            self.selectedClipId = nil
        }
    }

    private func isMediaAssetReferenced(_ mediaAssetId: String, in project: CamOrderProject) -> Bool {
        project.timeline.lanes.flatMap(\.clips).contains { $0.mediaAssetId == mediaAssetId }
    }

    private func defaultCaptureLatencyMs(for cameraDeviceId: String) -> Int {
        return 0
    }

    private func isIPhoneContinuitySource(_ searchableName: String) -> Bool {
        searchableName.contains("iphone") ||
            searchableName.contains("continuity") ||
            searchableName.contains("santi camera") ||
            searchableName.contains("santi iphone")
    }

    private func normalizedKnownCalibrationValue(_ value: Double, cameraDeviceId: String, searchableName: String) -> Double? {
        if cameraDeviceId.hasPrefix("window:") {
            let staleWindowValues = [0.245, 0.333, 0.665, 1.6, 2.02]
            if staleWindowValues.contains(where: { abs(value - $0) < 0.0001 }) {
                return 0.111
            }
        }

        if isIPhoneContinuitySource(searchableName) {
            let staleIPhoneValues = [0.333, 0.666, 2.02, 2.11, 2.19]
            if staleIPhoneValues.contains(where: { abs(value - $0) < 0.0001 }) {
                return 0.245
            }
        }

        return nil
    }

    private func adjustGridDivision(by delta: Int) {
        let divisions = BeatGridDivision.allCases
        guard let currentIndex = divisions.firstIndex(of: gridDivision) else { return }
        let nextIndex = min(max(0, currentIndex + delta), divisions.count - 1)
        guard nextIndex != currentIndex else { return }
        setGridDivision(divisions[nextIndex])
    }

    private func editSelectedClipOnGrid(_ edit: (inout VideoClip, Double) -> Void) {
        guard let selectedClipId else { return }
        guard var document else { return }
        for laneIndex in document.project.timeline.lanes.indices {
            guard let clipIndex = document.project.timeline.lanes[laneIndex].clips.firstIndex(where: { $0.id == selectedClipId }) else {
                continue
            }
            registerUndo(project: document.project)
            let bpm = document.project.timeline.tempoBPM ?? 120
            let division = document.project.timeline.gridDivision ?? .beat
            let gridSeconds = max(0.001, 60.0 / max(1, bpm) * division.beats)
            edit(&document.project.timeline.lanes[laneIndex].clips[clipIndex], gridSeconds)
            let mediaId = document.project.timeline.lanes[laneIndex].clips[clipIndex].mediaAssetId
            let mediaDuration = document.project.media.first { $0.id == mediaId }?.durationSeconds
            document.project.timeline.lanes[laneIndex].clips[clipIndex].constrainDuration(toSourceDuration: mediaDuration)
            let clip = document.project.timeline.lanes[laneIndex].clips[clipIndex]
            document.project.timeline.durationSeconds = max(document.project.timeline.durationSeconds, clip.timelineStartSeconds + clip.durationSeconds)
            self.document = document
            saveProject()
            return
        }
    }

    private func editClip(_ clipId: String, _ edit: (inout VideoClip) -> Void) {
        guard var document else { return }
        for laneIndex in document.project.timeline.lanes.indices {
            guard let clipIndex = document.project.timeline.lanes[laneIndex].clips.firstIndex(where: { $0.id == clipId }) else {
                continue
            }
            registerUndo(project: document.project)
            edit(&document.project.timeline.lanes[laneIndex].clips[clipIndex])
            let mediaId = document.project.timeline.lanes[laneIndex].clips[clipIndex].mediaAssetId
            let mediaDuration = document.project.media.first { $0.id == mediaId }?.durationSeconds
            document.project.timeline.lanes[laneIndex].clips[clipIndex].constrainDuration(toSourceDuration: mediaDuration)
            let clip = document.project.timeline.lanes[laneIndex].clips[clipIndex]
            document.project.timeline.durationSeconds = max(document.project.timeline.durationSeconds, clip.timelineStartSeconds + clip.durationSeconds)
            self.document = document
            saveProject()
            return
        }
    }

    private func uniqueDestinationURL(for fileName: String, in folder: URL) -> URL {
        let base = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: fileName).pathExtension
        var candidate = folder.appendingPathComponent(fileName)
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let suffixedName = ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
            candidate = folder.appendingPathComponent(suffixedName)
            suffix += 1
        }
        return candidate
    }

    private struct ClipLocation {
        var laneIndex: Int
        var clipIndex: Int
    }

    private func automationClipLocation(at timelineSeconds: Double) -> ClipLocation? {
        automationClipLocation(at: timelineSeconds, in: project)
    }

    private func automationClipLocation(at timelineSeconds: Double, in project: CamOrderProject) -> ClipLocation? {
        if let selectedClipId {
            for laneIndex in project.timeline.lanes.indices {
                if let clipIndex = project.timeline.lanes[laneIndex].clips.firstIndex(where: { clip in
                    clip.id == selectedClipId && project.presentedClip(clip).containsTimelineSecond(timelineSeconds)
                }) {
                    return ClipLocation(laneIndex: laneIndex, clipIndex: clipIndex)
                }
            }
        }

        for laneIndex in project.timeline.lanes.indices where !project.timeline.lanes[laneIndex].isMuted {
            if let clipIndex = project.timeline.lanes[laneIndex].clips.lastIndex(where: { clip in
                clip.isEnabled && project.presentedClip(clip).containsTimelineSecond(timelineSeconds)
            }) {
                return ClipLocation(laneIndex: laneIndex, clipIndex: clipIndex)
            }
        }

        return nil
    }

    private func videoDurationSeconds(for url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }
}

private extension VideoClip {
    func containsTimelineSecond(_ second: Double) -> Bool {
        second >= timelineStartSeconds && second < timelineStartSeconds + durationSeconds
    }
}
