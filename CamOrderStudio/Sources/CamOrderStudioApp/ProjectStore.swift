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

    @Published var document: ProjectDocument?
    @Published var selectedMediaAssetId: String?
    @Published var selectedClipId: String?
    @Published var lastError: String?
    @Published var pendingTake: PendingTakeRegion?
    @Published var pendingStopTimecode: Timecode?
    @Published var armedBuffer: ArmedCaptureBuffer?
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
        project.sync.defaultPlaybackSyncOffsetSeconds ?? 0.333
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
        registerUndo(project: document.project)
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
            document = try ProjectDocument.open(at: url)
            selectedMediaAssetId = document?.project.media.first(where: { $0.kind == .video })?.id
            selectedClipId = nil
            lastError = nil
            clearHistory()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func saveProject() {
        guard let document else { return }
        do {
            try document.save()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func saveProjectAs() {
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
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: document.folderURL, to: destinationURL)
            var copiedDocument = try ProjectDocument.open(at: destinationURL)
            copiedDocument.project.name = destinationURL.deletingPathExtension().lastPathComponent
            try copiedDocument.save()
            self.document = copiedDocument
            lastError = nil
            clearHistory()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func confirmClosingCurrentProject() -> Bool {
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
            let clipNumber = document.project.timeline.lanes.flatMap(\.clips).count + 1
            let clip = VideoClip(
                clipId: String(format: "take_%03d", clipNumber),
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
        var project = project
        registerUndo(project: project)
        let shouldUnarm = project.timeline.lanes.first(where: { $0.id == laneId })?.isArmed == true
        for index in project.timeline.lanes.indices {
            project.timeline.lanes[index].isArmed = shouldUnarm ? false : project.timeline.lanes[index].id == laneId
        }
        self.project = project
        saveProject()
    }

    func addLane() {
        guard var document else {
            createProject()
            return
        }
        registerUndo(project: document.project)
        let number = document.project.timeline.lanes.count + 1
        document.project.timeline.lanes.append(VideoLane(id: "lane_\(number)", name: "Camera \(number)"))
        self.document = document
        saveProject()
    }

    func renameLane(_ laneId: String, name: String) {
        guard var document else { return }
        guard let index = document.project.timeline.lanes.firstIndex(where: { $0.id == laneId }) else { return }
        document.project.timeline.lanes[index].name = name
        self.document = document
    }

    func deleteLane(_ laneId: String) {
        guard var document else { return }
        guard document.project.timeline.lanes.count > 1 else {
            lastError = "Keep at least one camera lane."
            return
        }
        guard let index = document.project.timeline.lanes.firstIndex(where: { $0.id == laneId }) else { return }
        if document.project.timeline.lanes[index].isArmed {
            lastError = "Disarm or arm another lane before deleting this lane."
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
        let id = cameraDeviceId ?? "default-camera"
        let searchableName = "\(id) \(displayName ?? "")".lowercased()
        if let stored = project.captureLatencyProfiles.first(where: { $0.cameraDeviceId == id })?.playbackSyncOffsetSeconds {
            if let normalized = normalizedKnownCalibrationValue(stored, cameraDeviceId: id, searchableName: searchableName) {
                return normalized
            }
            return stored
        }
        if let appDefault = appCalibrationDefaults.calibration(for: id, displayName: displayName) {
            return appDefault.playbackSyncOffsetSeconds
        }
        if id.hasPrefix("window:") {
            return 0.111
        }
        if isIPhoneContinuitySource(searchableName) {
            return 0.245
        }
        return defaultPlaybackSyncOffsetSeconds
    }

    func effectivePlaybackSyncOffsetSeconds(for clip: VideoClip) -> Double {
        let id = clip.cameraDeviceId ?? "default-camera"
        let profileName = project.captureLatencyProfiles.first(where: { $0.cameraDeviceId == id })?.displayName ?? ""
        let searchableName = "\(id) \(profileName)".lowercased()
        if let stored = clip.playbackSyncOffsetSeconds,
           let normalized = normalizedKnownCalibrationValue(stored, cameraDeviceId: id, searchableName: searchableName) {
            return normalized
        }
        return clip.playbackSyncOffsetSeconds ?? playbackSyncOffsetSeconds(for: clip.cameraDeviceId)
    }

    func startTakeRegion(at timecode: Timecode, observedTimecode: Timecode? = nil, cameraDeviceId: String?, cameraDisplayName: String? = nil) {
        guard pendingTake == nil else { return }
        guard let lane = project.timeline.lanes.first(where: { $0.isArmed }) else {
            lastError = "Arm a camera lane before recording a take region."
            return
        }
        if let armedBuffer, armedBuffer.laneId == lane.id {
            let now = DispatchTime.now().uptimeNanoseconds
            let recordingHostTime = armedBuffer.recordingStartedHostTime ?? armedBuffer.bufferStartHostTime
            let elapsedSinceBufferStarted = Double(now - recordingHostTime) / 1_000_000_000.0
            let transportDetectionDelay = max(0, (observedTimecode ?? timecode).secondsValue - timecode.secondsValue)
            let trimInSeconds = max(0, elapsedSinceBufferStarted - transportDetectionDelay)
            pendingTake = PendingTakeRegion(
                laneId: armedBuffer.laneId,
                clipId: armedBuffer.clipId,
                startTimecode: timecode,
                startSeconds: timecode.secondsValue,
                captureLatencyMs: 0,
                playbackSyncOffsetSeconds: armedBuffer.playbackSyncOffsetSeconds,
                cameraDeviceId: armedBuffer.cameraDeviceId,
                hostTime: recordingHostTime,
                relativeVideoFile: armedBuffer.relativeVideoFile,
                trimInSeconds: trimInSeconds
            )
            self.armedBuffer = nil
            return
        }
        let clipNumber = project.timeline.lanes.flatMap(\.clips).count + 1
        let latency = captureLatencyMs(for: cameraDeviceId)
        let playbackSyncOffset = playbackSyncOffsetSeconds(for: cameraDeviceId, displayName: cameraDisplayName)
        pendingTake = PendingTakeRegion(
            laneId: lane.id,
            clipId: String(format: "take_%03d", clipNumber),
            startTimecode: timecode,
            startSeconds: timecode.secondsValue,
            captureLatencyMs: latency,
            playbackSyncOffsetSeconds: playbackSyncOffset,
            cameraDeviceId: cameraDeviceId,
            hostTime: DispatchTime.now().uptimeNanoseconds,
            relativeVideoFile: String(format: "media/video/take_%03d.mov", clipNumber),
            trimInSeconds: 0
        )
    }

    func startArmedBuffer(cameraDeviceId: String?, cameraDisplayName: String? = nil) {
        guard armedBuffer == nil, pendingTake == nil else { return }
        guard let lane = project.timeline.lanes.first(where: { $0.isArmed }) else { return }
        let clipNumber = project.timeline.lanes.flatMap(\.clips).count + 1
        armedBuffer = ArmedCaptureBuffer(
            laneId: lane.id,
            clipId: String(format: "take_%03d", clipNumber),
            cameraDeviceId: cameraDeviceId,
            bufferStartHostTime: DispatchTime.now().uptimeNanoseconds,
            recordingStartedHostTime: nil,
            relativeVideoFile: String(format: "media/video/take_%03d.mov", clipNumber),
            playbackSyncOffsetSeconds: playbackSyncOffsetSeconds(for: cameraDeviceId, displayName: cameraDisplayName)
        )
    }

    func pendingArmedBufferURL() -> URL? {
        guard let armedBuffer, let document else { return nil }
        return document.absoluteURL(for: armedBuffer.relativeVideoFile)
    }

    func markArmedBufferRecordingStarted(hostTime: UInt64) {
        guard armedBuffer != nil else { return }
        armedBuffer?.recordingStartedHostTime = hostTime
    }

    func discardArmedBuffer() {
        armedBuffer = nil
    }

    func pendingRecordingURL() -> URL? {
        guard let pendingTake, let document else { return nil }
        return document.absoluteURL(for: pendingTake.relativeVideoFile)
    }

    func finishTakeRegion(at timecode: Timecode, warnings: [String] = []) {
        guard let pendingTake else { return }
        guard var document else { return }
        guard let laneIndex = document.project.timeline.lanes.firstIndex(where: { $0.id == pendingTake.laneId }) else { return }

        let visibleDuration = max(0.1, timecode.secondsValue - pendingTake.startSeconds)
        let mediaDuration = pendingTake.trimInSeconds + visibleDuration
        let mediaAsset = MediaAsset(
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
            timelineStartSeconds: pendingTake.trimInSeconds > 0 ? pendingTake.startSeconds : nil,
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
        document.project.media.append(mediaAsset)
        document.project.timeline.lanes[laneIndex].clips.append(clip)
        document.project.timeline.durationSeconds = max(document.project.timeline.durationSeconds, clip.timelineStartSeconds + clip.durationSeconds)
        self.document = document
        self.pendingTake = nil
        self.pendingStopTimecode = nil
        selectedMediaAssetId = mediaAsset.id
        selectedClipId = clip.id
        saveProject()
    }

    func beginSelectedClipFramingEdit() {
        guard let document, selectedClip() != nil else { return }
        registerUndo(project: document.project)
    }

    func updateSelectedClipFraming(zoom: Double? = nil, offsetX: Double? = nil, offsetY: Double? = nil, rotationDegrees: Double? = nil, trackUndo: Bool = true, save: Bool = false, origin: FramingEditOrigin = .inspector) {
        guard let selectedClipId else { return }
        guard var document else { return }
        for laneIndex in document.project.timeline.lanes.indices {
            guard let clipIndex = document.project.timeline.lanes[laneIndex].clips.firstIndex(where: { $0.id == selectedClipId }) else {
                continue
            }
            if trackUndo {
                registerUndo(project: document.project)
            }
            var framing = document.project.timeline.lanes[laneIndex].clips[clipIndex].framing ?? ClipFraming()
            if let zoom { framing.zoom = zoom }
            if let offsetX { framing.offsetX = offsetX }
            if let offsetY { framing.offsetY = offsetY }
            if let rotationDegrees { framing.rotationDegrees = rotationDegrees }
            document.project.timeline.lanes[laneIndex].clips[clipIndex].framing = framing
            self.document = document
            let nextRevision = (latestFramingEdit?.revision ?? 0) + 1
            latestFramingEdit = FramingEditEvent(clipId: selectedClipId, origin: origin, revision: nextRevision)
            if save {
                saveProject()
            }
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
            let end = clip.timelineStartSeconds + clip.durationSeconds
            let snappedStart = max(0, (clip.timelineStartSeconds / gridSeconds).rounded() * gridSeconds)
            clip.timelineStartSeconds = min(snappedStart, max(0, end - 0.1))
            clip.durationSeconds = max(0.1, end - clip.timelineStartSeconds)
        }
    }

    func snapSelectedClipEndToGrid() {
        editSelectedClipOnGrid { clip, gridSeconds in
            let end = clip.timelineStartSeconds + clip.durationSeconds
            let snappedEnd = max(clip.timelineStartSeconds + 0.1, (end / gridSeconds).rounded() * gridSeconds)
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
            guard seconds > clip.timelineStartSeconds + 0.05, seconds < clip.timelineStartSeconds + clip.durationSeconds - 0.05 else {
                return
            }
            registerUndo(project: document.project)
            let firstDuration = seconds - clip.timelineStartSeconds
            let secondDuration = clip.durationSeconds - firstDuration
            let firstAutomationMarkers = clip.automationMarkers
                .filter { $0.timeSeconds <= firstDuration }
                .sorted { $0.timeSeconds < $1.timeSeconds }
            let secondAutomationMarkers = clip.automationMarkers
                .filter { $0.timeSeconds >= firstDuration }
                .map { marker in
                    ClipAutomationMarker(
                        id: marker.id,
                        timeSeconds: max(0, marker.timeSeconds - firstDuration),
                        framing: marker.framing
                    )
                }
                .sorted { $0.timeSeconds < $1.timeSeconds }
            document.project.timeline.lanes[laneIndex].clips[clipIndex].durationSeconds = firstDuration
            document.project.timeline.lanes[laneIndex].clips[clipIndex].automationMarkers = firstAutomationMarkers

            var secondClip = clip
            secondClip.id = UUID().uuidString
            secondClip.clipId = "\(clip.clipId)_cut"
            secondClip.timelineStartSeconds = seconds
            secondClip.logicStartSeconds = seconds
            secondClip.logicStartTimecode = Timecode.from(seconds: seconds, frameRate: clip.frameRate)
            secondClip.durationSeconds = secondDuration
            secondClip.automationMarkers = secondAutomationMarkers
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

    func insertAutomationMarker(at timelineSeconds: Double) {
        guard var document else { return }
        guard let location = automationClipLocation(at: timelineSeconds, in: document.project) else {
            lastError = "Select a region or place the playhead over a region before inserting an automation marker."
            return
        }

        registerUndo(project: document.project)
        var clip = document.project.timeline.lanes[location.laneIndex].clips[location.clipIndex]
        let localSeconds = min(max(0, timelineSeconds - clip.timelineStartSeconds), clip.durationSeconds)
        let markerFraming = clip.framing ?? clip.automatedFraming(atLocalSecond: localSeconds)
        let tolerance = max(0.02, 0.5 / max(1, clip.frameRate.framesPerSecond))
        if let markerIndex = clip.automationMarkers.firstIndex(where: { abs($0.timeSeconds - localSeconds) <= tolerance }) {
            clip.automationMarkers[markerIndex].timeSeconds = localSeconds
            clip.automationMarkers[markerIndex].framing = markerFraming
        } else {
            clip.automationMarkers.append(
                ClipAutomationMarker(timeSeconds: localSeconds, framing: markerFraming)
            )
        }
        clip.automationMarkers.sort { $0.timeSeconds < $1.timeSeconds }
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
        let localSeconds = min(max(0, timelineSeconds - clip.timelineStartSeconds), clip.durationSeconds)
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
            clip.timelineStartSeconds = max(0, startSeconds)
        }
    }

    func updateClipLeftEdge(_ clipId: String, startSeconds: Double) {
        editClip(clipId) { clip in
            let oldStart = clip.timelineStartSeconds
            let oldEnd = clip.timelineStartSeconds + clip.durationSeconds
            let requestedStart = max(0, min(startSeconds, oldEnd - 0.1))
            let delta = requestedStart - oldStart
            let requestedTrimIn = clip.trimInSeconds + delta
            let clampedTrimIn = max(0, requestedTrimIn)
            let adjustedStart = oldStart + (clampedTrimIn - clip.trimInSeconds)
            clip.timelineStartSeconds = min(adjustedStart, oldEnd - 0.1)
            clip.trimInSeconds = clampedTrimIn
            clip.durationSeconds = max(0.1, oldEnd - clip.timelineStartSeconds)
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
        redoStack.append(document.project)
        document.project = previous
        self.document = document
        reconcileSelection()
        updateUndoRedoState()
        saveProject()
    }

    func redoProjectChange() {
        guard var document, let next = redoStack.popLast() else { return }
        undoStack.append(document.project)
        document.project = next
        self.document = document
        reconcileSelection()
        updateUndoRedoState()
        saveProject()
    }

    func selectedClip() -> VideoClip? {
        project.timeline.lanes.flatMap(\.clips).first { $0.id == selectedClipId }
    }

    func playbackClip(at seconds: Double) -> VideoClip? {
        if let selected = selectedClip(), selected.containsTimelineSecond(seconds) {
            return selected
        }
        for lane in project.timeline.lanes where !lane.isMuted {
            if let clip = lane.clips.last(where: { $0.isEnabled && $0.containsTimelineSecond(seconds) }) {
                return clip
            }
        }
        return nil
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
                    clip.id == selectedClipId && clip.containsTimelineSecond(timelineSeconds)
                }) {
                    return ClipLocation(laneIndex: laneIndex, clipIndex: clipIndex)
                }
            }
        }

        for laneIndex in project.timeline.lanes.indices where !project.timeline.lanes[laneIndex].isMuted {
            if let clipIndex = project.timeline.lanes[laneIndex].clips.lastIndex(where: { clip in
                clip.isEnabled && clip.containsTimelineSecond(timelineSeconds)
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
        second >= timelineStartSeconds && second <= timelineStartSeconds + durationSeconds
    }
}
