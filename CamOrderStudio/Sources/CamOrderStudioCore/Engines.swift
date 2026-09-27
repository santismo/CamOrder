import Foundation
import CoreMIDI
@preconcurrency import AVFoundation
import CoreGraphics

@MainActor
public final class LogicSyncEngine: ObservableObject {
    @Published public private(set) var state: LogicSyncState = .disconnected
    @Published public private(set) var currentTimecode = Timecode(hours: 0, minutes: 0, seconds: 0, frames: 0, frameRate: .fps30)
    @Published public private(set) var displayTimecode = Timecode(hours: 0, minutes: 0, seconds: 0, frames: 0, frameRate: .fps30)
    @Published public private(set) var displaySeconds: Double = 0
    @Published public private(set) var previewSeconds: Double?
    public var editorSeconds: Double { previewSeconds ?? displaySeconds }

    /// A stopped preview never changes the host transport or recording clock.
    public func preview(at seconds: Double) {
        guard !isTransportRolling, seconds.isFinite else { return }
        previewSeconds = max(0, seconds)
    }
    public func followHost() { if previewSeconds != nil { previewSeconds = nil } }
    @Published public private(set) var connectedSourceNames: [String] = []
    @Published public private(set) var lastErrorMessage: String?
    @Published public private(set) var detectedTempoBPM: Double?
    @Published public private(set) var transportStartTimecode: Timecode?

    private var lastRollingDisplayTimecode = Timecode(hours: 0, minutes: 0, seconds: 0, frames: 0, frameRate: .fps30)

    public var isTransportRolling: Bool {
        state == .playing || state == .chasing
    }

    private let parser = MTCParser()
    private var midiClient = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var isRunning = false
    private var lastAnchorSeconds: Double = 0
    private var lastAnchorDate = Date()
    private var lastPacketDate = Date()
    private var lastMovingDate = Date()
    private var tempoBPM: Double = 120
    private var lastMIDIClockDate: Date?
    private var midiClockIntervals: [TimeInterval] = []
    private var displayTimer: Timer?
    private var displayTimerInterval: TimeInterval = 1.0 / 60.0
    private let stoppedAfterPacketGap: TimeInterval = 0.11
    private let idleDisplayInterval: TimeInterval = 0.5
    private var lastIdleDisplayUpdate = Date.distantPast

    @Published public var timecodeOriginHours = 1
    @Published public private(set) var logicLinkConnected = false
    public func setLogicLinkConnected(_ connected: Bool) { if logicLinkConnected != connected { logicLinkConnected = connected } }
    @Published public private(set) var hostTimingDelayed = false
    public func setHostTimingDelayed(_ delayed: Bool) { if hostTimingDelayed != delayed { hostTimingDelayed = delayed } }
    public let isHosted: Bool
    public init(isHosted: Bool = false) { self.isHosted = isHosted }

    public func receiveHostPosition(seconds: Double, playing: Bool, tempo: Double, available: Bool, sourceName: String = "Logic Audio Unit transport") {
        guard isHosted else { return }
        let wasRolling = isTransportRolling
        let position = max(0, seconds.isFinite ? seconds : 0)
        if playing || abs(position - displaySeconds) > 0.001 { followHost() }
        let time = Timecode.from(seconds: position, frameRate: .fps30)
        if currentTimecode != time { currentTimecode = time }
        if displayTimecode != time { displayTimecode = time }
        if displaySeconds != position { displaySeconds = position }
        if tempo.isFinite && tempo > 0 && detectedTempoBPM != tempo { detectedTempoBPM = tempo }
        let sources = available ? [sourceName] : []
        if connectedSourceNames != sources { connectedSourceNames = sources }
        let error = available ? nil : "Waiting for transport from Logic. Keep CamOrder enabled on Stereo Out and start playback."
        if lastErrorMessage != error { lastErrorMessage = error }
        if playing && !wasRolling { transportStartTimecode = time }
        if !playing { transportStartTimecode = nil }
        let nextState: LogicSyncState = available ? (playing ? .playing : .stopped) : .disconnected
        if state != nextState { state = nextState }
    }


    public func startMTCInput() {
        guard !isHosted else { return }
        guard !isRunning else { return }
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        var client = MIDIClientRef()
        var status = MIDIClientCreate("CamOrder Studio MIDI Client" as CFString, nil, nil, &client)
        guard status == noErr else {
            setMIDIError("Could not create CoreMIDI client", status: status)
            return
        }

        var port = MIDIPortRef()
        status = MIDIInputPortCreate(client, "CamOrder Studio MTC Input" as CFString, Self.midiReadProc, selfPointer, &port)
        guard status == noErr else {
            MIDIClientDispose(client)
            setMIDIError("Could not create CoreMIDI input port", status: status)
            return
        }

        midiClient = client
        inputPort = port
        isRunning = true
        startDisplayTimer()
        connectToAvailableSources(preferLogicVirtualOut: true)
        setState(.waitingForTimecode)
    }

    public func stop() {
        if inputPort != 0 {
            MIDIPortDispose(inputPort)
            inputPort = 0
        }
        if midiClient != 0 {
            MIDIClientDispose(midiClient)
            midiClient = 0
        }
        setConnectedSourceNames([])
        isRunning = false
        displayTimer?.invalidate()
        displayTimer = nil
        setState(.stopped)
    }

    public func receiveMIDIPacket(bytes: [UInt8], receivedAt: Date = Date()) {
        if !bytes.isEmpty {
            lastPacketDate = receivedAt
        }
        receiveSystemCommonAndRealtime(bytes: bytes, receivedAt: receivedAt)
        let outputs = parser.receive(bytes: bytes, receivedAt: receivedAt)
        if let output = outputs.last {
            let normalizedTimecode = Self.normalizedLogicTimecode(from: output.timecode)
            let previousFrames = currentTimecode.totalFrames
            let previousTimecode = currentTimecode
            let wasRolling = isTransportRolling
            setCurrentTimecode(normalizedTimecode)
            lastAnchorSeconds = normalizedTimecode.secondsValue
            lastAnchorDate = receivedAt
            setDisplayTimecode(normalizedTimecode)
            setDisplaySeconds(normalizedTimecode.secondsValue)
            if normalizedTimecode.totalFrames != previousFrames {
                lastMovingDate = receivedAt
                setState(.playing)
                lastRollingDisplayTimecode = normalizedTimecode
                if !wasRolling {
                    transportStartTimecode = Self.transportStartAnchor(previous: previousTimecode, firstRolling: normalizedTimecode)
                }
            } else if receivedAt.timeIntervalSince(lastMovingDate) > 0.2 {
                setState(.stopped)
                setTransportStartTimecode(nil)
            } else {
                setState(output.state)
            }
        }
    }

    public func stopTimecodeForPlacement() -> Timecode {
        [currentTimecode, displayTimecode, lastRollingDisplayTimecode].max { lhs, rhs in
            lhs.secondsValue < rhs.secondsValue
        } ?? displayTimecode
    }

    public func refreshSources() {
        guard isRunning else {
            startMTCInput()
            return
        }
        connectToAvailableSources(preferLogicVirtualOut: true)
    }

    public func setTempoBPM(_ bpm: Double) {
        tempoBPM = max(1, bpm)
    }

    private func connectToAvailableSources(preferLogicVirtualOut: Bool) {
        let sourceCount = MIDIGetNumberOfSources()
        guard sourceCount > 0 else {
            setConnectedSourceNames([])
            setState(.disconnected)
            setLastErrorMessage("No CoreMIDI sources are available. Confirm Logic Pro is sending MTC to Logic Pro Virtual Out or an IAC bus.")
            return
        }

        var candidates: [(endpoint: MIDIEndpointRef, name: String)] = []
        for index in 0..<sourceCount {
            let endpoint = MIDIGetSource(index)
            let name = Self.displayName(for: endpoint)
            candidates.append((endpoint, name))
        }

        let logicSources = candidates.filter { candidate in
            let lowercased = candidate.name.lowercased()
            return lowercased.contains("logic") || lowercased.contains("virtual out")
        }
        let selectedSources = preferLogicVirtualOut && !logicSources.isEmpty ? logicSources : candidates

        var connected: [String] = []
        for source in selectedSources {
            let status = MIDIPortConnectSource(inputPort, source.endpoint, nil)
            if status == noErr {
                connected.append(source.name)
            }
        }

        setConnectedSourceNames(connected)
        if connected.isEmpty {
            setState(.error)
            setLastErrorMessage("CoreMIDI sources were found, but CamOrder Studio could not connect to them.")
        } else {
            setState(.waitingForTimecode)
            setLastErrorMessage(nil)
        }
    }

    private func setMIDIError(_ message: String, status: OSStatus) {
        setState(.error)
        setLastErrorMessage("\(message). CoreMIDI status: \(status).")
    }

    private func startDisplayTimer() {
        startDisplayTimer(interval: desiredDisplayTimerInterval())
    }

    private func startDisplayTimer(interval: TimeInterval) {
        displayTimer?.invalidate()
        displayTimerInterval = interval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateDisplayPlayhead()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    private func retuneDisplayTimerIfNeeded() {
        guard !isHosted else { return }
        let nextInterval = desiredDisplayTimerInterval()
        guard abs(displayTimerInterval - nextInterval) > 0.001 else { return }
        startDisplayTimer(interval: nextInterval)
    }

    private func desiredDisplayTimerInterval() -> TimeInterval {
        switch state {
        case .playing, .chasing, .locating:
            return 1.0 / 60.0
        default:
            return idleDisplayInterval
        }
    }

    private func updateDisplayPlayhead(now: Date = Date()) {
        let packetElapsed = now.timeIntervalSince(lastPacketDate)
        if packetElapsed > 12, state != .stopped, state != .waitingForTimecode, state != .disconnected {
            setState(.unstable)
            return
        }
        if packetElapsed > stoppedAfterPacketGap {
            guard now.timeIntervalSince(lastIdleDisplayUpdate) >= idleDisplayInterval else { return }
            lastIdleDisplayUpdate = now
            setState(.stopped)
            setTransportStartTimecode(nil)
            setDisplaySeconds(currentTimecode.secondsValue)
            setDisplayTimecode(currentTimecode)
            return
        }
        guard state == .chasing || state == .playing || state == .locating else { return }
        let frameDuration = 1.0 / max(1, currentTimecode.frameRate.framesPerSecond)
        let elapsed = min(now.timeIntervalSince(lastAnchorDate), frameDuration)
        let seconds = lastAnchorSeconds + elapsed
        setDisplaySeconds(seconds)
        setDisplayTimecode(Timecode.from(seconds: seconds, frameRate: currentTimecode.frameRate))
        lastRollingDisplayTimecode = displayTimecode
    }

    private func setState(_ nextState: LogicSyncState) {
        guard state != nextState else { return }
        state = nextState
        retuneDisplayTimerIfNeeded()
    }

    private func setCurrentTimecode(_ nextTimecode: Timecode) {
        guard currentTimecode != nextTimecode else { return }
        currentTimecode = nextTimecode
    }

    private func setDisplayTimecode(_ nextTimecode: Timecode) {
        guard displayTimecode != nextTimecode else { return }
        displayTimecode = nextTimecode
    }

    private func setDisplaySeconds(_ nextSeconds: Double) {
        guard abs(displaySeconds - nextSeconds) > 0.0001 else { return }
        displaySeconds = nextSeconds
    }

    private func setConnectedSourceNames(_ nextSourceNames: [String]) {
        guard connectedSourceNames != nextSourceNames else { return }
        connectedSourceNames = nextSourceNames
    }

    private func setLastErrorMessage(_ nextMessage: String?) {
        guard lastErrorMessage != nextMessage else { return }
        lastErrorMessage = nextMessage
    }

    private func setTransportStartTimecode(_ nextTimecode: Timecode?) {
        guard transportStartTimecode != nextTimecode else { return }
        transportStartTimecode = nextTimecode
    }

    private func receiveSystemCommonAndRealtime(bytes: [UInt8], receivedAt: Date) {
        var index = 0
        while index < bytes.count {
            switch bytes[index] {
            case 0xF2 where index + 2 < bytes.count:
                let songPositionPointer = Int(bytes[index + 1] & 0x7F) | (Int(bytes[index + 2] & 0x7F) << 7)
                receiveSongPositionPointer(songPositionPointer, receivedAt: receivedAt)
                index += 3
            case 0xF8:
                receiveMIDIClock(receivedAt: receivedAt)
                index += 1
            default:
                index += 1
            }
        }
    }

    private func receiveSongPositionPointer(_ value: Int, receivedAt: Date) {
        let quarterNotes = Double(value) / 4.0
        let seconds = quarterNotes * 60.0 / max(1, tempoBPM)
        let timecode = Timecode.from(seconds: seconds, frameRate: currentTimecode.frameRate)
        setCurrentTimecode(timecode)
        setDisplayTimecode(timecode)
        setDisplaySeconds(seconds)
        lastAnchorSeconds = seconds
        lastAnchorDate = receivedAt
        setTransportStartTimecode(nil)
        setState(.locating)
    }

    private func receiveMIDIClock(receivedAt: Date) {
        defer { lastMIDIClockDate = receivedAt }
        guard let lastMIDIClockDate else { return }
        let interval = receivedAt.timeIntervalSince(lastMIDIClockDate)
        guard interval > 0.001, interval < 0.5 else {
            midiClockIntervals.removeAll()
            return
        }
        midiClockIntervals.append(interval)
        if midiClockIntervals.count > 48 {
            midiClockIntervals.removeFirst(midiClockIntervals.count - 48)
        }
        guard midiClockIntervals.count >= 12 else { return }
        let averageInterval = midiClockIntervals.reduce(0, +) / Double(midiClockIntervals.count)
        let bpm = 60.0 / (averageInterval * 24.0)
        guard bpm.isFinite, bpm >= 20, bpm <= 300 else { return }
        guard detectedTempoBPM.map({ abs($0 - bpm) > 0.05 }) ?? true else { return }
        detectedTempoBPM = bpm
    }

    private static func displayName(for endpoint: MIDIEndpointRef) -> String {
        var unmanagedName: Unmanaged<CFString>?
        let status = MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &unmanagedName)
        if status == noErr, let name = unmanagedName?.takeRetainedValue() as String?, !name.isEmpty {
            return name
        }

        unmanagedName = nil
        let fallbackStatus = MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &unmanagedName)
        if fallbackStatus == noErr, let name = unmanagedName?.takeRetainedValue() as String?, !name.isEmpty {
            return name
        }

        return "MIDI Source \(endpoint)"
    }

    private static func normalizedLogicTimecode(from timecode: Timecode) -> Timecode {
        let seconds = timecode.secondsValue
        let normalizedSeconds = seconds >= 3600 ? seconds - 3600 : seconds
        return Timecode.from(seconds: normalizedSeconds, frameRate: timecode.frameRate)
    }

    private static func transportStartAnchor(previous: Timecode, firstRolling: Timecode) -> Timecode {
        let delta = firstRolling.secondsValue - previous.secondsValue
        let frameDuration = 1.0 / max(1, firstRolling.frameRate.framesPerSecond)
        if delta >= 0, delta <= 0.35 {
            return previous
        }
        let estimatedStartSeconds = max(0, firstRolling.secondsValue - frameDuration)
        return Timecode.from(seconds: estimatedStartSeconds, frameRate: firstRolling.frameRate)
    }

    nonisolated private static let midiReadProc: MIDIReadProc = { packetList, readProcRefCon, _ in
        guard let readProcRefCon else { return }
        let engine = Unmanaged<LogicSyncEngine>.fromOpaque(readProcRefCon).takeUnretainedValue()
        var packet = packetList.pointee.packet

        for _ in 0..<packetList.pointee.numPackets {
            let length = Int(packet.length)
            let bytes = withUnsafeBytes(of: packet.data) { rawBuffer -> [UInt8] in
                Array(rawBuffer.prefix(length))
            }
            Task { @MainActor in
                engine.receiveMIDIPacket(bytes: bytes)
            }
            packet = MIDIPacketNext(&packet).pointee
        }
    }
}

public struct MIDIClockParser {
    public init() {}
    // Future secondary sync path: MIDI Clock plus Song Position Pointer for beat-based chase.
}

public enum CameraCaptureError: LocalizedError {
    case unsupportedSource
    case outputUnavailable

    public var errorDescription: String? {
        switch self {
        case .unsupportedSource:
            return "This capture source cannot record to a movie file yet."
        case .outputUnavailable:
            return "Movie recording output is unavailable."
        }
    }
}

@MainActor
public final class RenderExportEngine: ObservableObject {
    @Published public private(set) var progress: Double = 0

    public init() {}

    public func export(project: CamOrderProject, from folderURL: URL, to destinationURL: URL, fromFirstClip: Bool = false, range: MovieExportRange? = nil) async throws {
        progress = 0
        let composition = AVMutableComposition()
        let renderSize = Self.renderSize(for: project.exportSettings)
        let frameDuration = CMTime(seconds: 1.0 / max(1, project.frameRate.framesPerSecond), preferredTimescale: 600)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = frameDuration

        let allSegments = Self.videoSegments(for: project)
        let edited = Self.editedRange(in: project)
        // Keep the file anchored to the edited range BEFORE sync adjustments.
        // Offsets move content inside this fixed window, not the import position.
        let exportStart = range?.startSeconds ?? (fromFirstClip ? (edited?.startSeconds ?? 0) : 0)
        let exportEnd = range?.endSeconds ?? edited?.endSeconds ?? 0
        let segments = allSegments.compactMap { segment -> RenderSegment? in
            let start = max(exportStart, segment.startSeconds)
            let end = min(exportEnd, segment.startSeconds + segment.durationSeconds)
            guard end > start else { return nil }
            return RenderSegment(clips: segment.clips, startSeconds: start, durationSeconds: end - start)
        }
        guard exportEnd > exportStart else { throw RenderExportError.noRenderableVideo }
        // Export never overwrites project media, even if the save panel points at it.
        guard !project.media.contains(where: {
            folderURL.appendingPathComponent($0.relativePath).resolvingSymlinksInPath() == destinationURL.resolvingSymlinksInPath()
        }) else { throw NSError(domain: "CamOrderExport", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose an export location outside your source media."]) }
        var instructions: [AVVideoCompositionInstructionProtocol] = []
        var cursor: Double = 0
        func movieTime(_ seconds: Double) -> CMTime {
            CMTime(value: Int64((seconds * 600).rounded()), timescale: 600)
        }
        func appendGap(until end: Double) {
            let range = CMTimeRange(start: movieTime(cursor), end: movieTime(end))
            guard range.duration.value > 0 else { return }
            let gap = AVMutableVideoCompositionInstruction()
            gap.timeRange = range
            gap.backgroundColor = CGColor(gray: 0, alpha: 1)
            gap.layerInstructions = []
            instructions.append(gap)
            cursor = end
        }
        var maxVideoEndSeconds: Double = 0
        var videoTracks: [String: AVMutableCompositionTrack] = [:]
        var audioTracks: [String: AVMutableCompositionTrack] = [:]
        var sources: [String: (asset: AVURLAsset, video: AVAssetTrack, audio: AVAssetTrack?, duration: Double, size: CGSize)] = [:]
        for segment in segments {
            let destinationTime = movieTime(segment.startSeconds - exportStart)
            let segmentEnd = movieTime(segment.startSeconds + segment.durationSeconds - exportStart)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: destinationTime, end: segmentEnd)
            instruction.backgroundColor = CGColor(gray: 0, alpha: 1)
            var layers: [AVVideoCompositionLayerInstruction] = []
            // AVFoundation lists foreground layers first, matching lane order.
            for clip in segment.clips {
                if sources[clip.mediaAssetId] == nil {
                    guard let asset = project.media.first(where: { $0.id == clip.mediaAssetId }) else {
                        throw NSError(domain: "CamOrderExport", code: 2, userInfo: [NSLocalizedDescriptionKey: "A timeline clip is missing its media reference."])
                    }
                    let sourceAsset = AVURLAsset(url: folderURL.appendingPathComponent(asset.relativePath))
                    guard let track = try await sourceAsset.loadTracks(withMediaType: .video).first else {
                        throw NSError(domain: "CamOrderExport", code: 3, userInfo: [NSLocalizedDescriptionKey: "No readable video track in \(asset.displayName)."])
                    }
                    sources[clip.mediaAssetId] = (sourceAsset, track, try await sourceAsset.loadTracks(withMediaType: .audio).first,
                        try await sourceAsset.load(.duration).seconds, try await Self.displaySize(for: track))
                }
                guard let source = sources[clip.mediaAssetId] else { continue }
                let sourceStart = max(0, clip.trimInSeconds + segment.startSeconds - clip.timelineStartSeconds
                    + (clip.playbackSyncOffsetSeconds ?? project.sync.defaultPlaybackSyncOffsetSeconds ?? 0))
                let duration = min(segment.durationSeconds, max(0, source.duration - sourceStart))
                guard duration > 0 else { continue }
                if videoTracks[clip.armedLaneId] == nil {
                    videoTracks[clip.armedLaneId] = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                }
                guard let videoTrack = videoTracks[clip.armedLaneId] else { throw RenderExportError.couldNotCreateVideoTrack }
                let destinationEnd = movieTime(segment.startSeconds + duration - exportStart)
                let sourceRange = CMTimeRange(start: movieTime(sourceStart), duration: CMTimeSubtract(destinationEnd, destinationTime))
                guard sourceRange.duration.value > 0 else { continue }
                try videoTrack.insertTimeRange(sourceRange, of: source.video, at: destinationTime)
                if project.exportSettings.audioMode == .cameraOnly || project.exportSettings.audioMode == .masteredAndCamera,
                   let audio = source.audio {
                    if audioTracks[clip.armedLaneId] == nil {
                        audioTracks[clip.armedLaneId] = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                    }
                    if let audioTrack = audioTracks[clip.armedLaneId] { try audioTrack.insertTimeRange(sourceRange, of: audio, at: destinationTime) }
                }
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
                layer.setTransformRamp(
                    fromStart: try await Self.transform(for: source.video, sourceSize: source.size, renderSize: renderSize,
                        framing: clip.automatedFraming(atTimelineSecond: segment.startSeconds)),
                    toEnd: try await Self.transform(for: source.video, sourceSize: source.size, renderSize: renderSize,
                        framing: clip.automatedFraming(atTimelineSecond: segment.startSeconds + duration)),
                    timeRange: CMTimeRange(start: destinationTime, duration: sourceRange.duration))
                if destinationEnd < segmentEnd { layer.setOpacity(0, at: destinationEnd) }
                layers.append(layer)
                maxVideoEndSeconds = max(maxVideoEndSeconds, destinationEnd.seconds)
            }
            appendGap(until: destinationTime.seconds)
            instruction.layerInstructions = layers
            instructions.append(instruction)
            cursor = segmentEnd.seconds
        }

        guard maxVideoEndSeconds > 0 else {
            throw RenderExportError.noRenderableVideo
        }
        let outputDuration = exportEnd - exportStart
        appendGap(until: outputDuration)
        if composition.duration.seconds < outputDuration {
            composition.insertEmptyTimeRange(CMTimeRange(start: composition.duration, duration: movieTime(outputDuration - composition.duration.seconds)))
        }
        var audioProject = project
        audioProject.audio.audioOffsetSeconds -= exportStart
        try await insertMasterAudioIfNeeded(project: audioProject, folderURL: folderURL, composition: composition, outputDuration: movieTime(outputDuration).seconds)
        videoComposition.instructions = instructions

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw RenderExportError.couldNotCreateExportSession
        }
        let temporaryURL = destinationURL.deletingLastPathComponent().appendingPathComponent(".camorder-export-\(UUID().uuidString).\(destinationURL.pathExtension)")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        exportSession.outputURL = temporaryURL
        exportSession.timeRange = CMTimeRange(start: .zero, duration: movieTime(outputDuration))
        exportSession.outputFileType = Self.outputFileType(for: project.exportSettings, destinationURL: destinationURL)
        exportSession.videoComposition = videoComposition

        let exportSessionBox = ExportSessionBox(exportSession)
        let progressTimer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.progress = Double(exportSessionBox.session.progress) }
        }
        RunLoop.main.add(progressTimer, forMode: .common)
        defer { progressTimer.invalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportSessionBox.session.exportAsynchronously {
                switch exportSessionBox.session.status {
                case .completed:
                    continuation.resume()
                case .failed, .cancelled:
                    continuation.resume(throwing: exportSessionBox.session.error ?? RenderExportError.exportFailed)
                default:
                    continuation.resume(throwing: RenderExportError.exportFailed)
                }
            }
        }
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        }
        progress = 1
    }

    public static func editedRange(in project: CamOrderProject) -> MovieExportRange? {
        let clips = project.timeline.lanes.filter { !$0.isMuted }.flatMap(\.clips).filter(\.isEnabled)
        guard let start = clips.map(\.timelineStartSeconds).min(),
              let end = clips.map({ $0.timelineStartSeconds + $0.durationSeconds }).max() else { return nil }
        return MovieExportRange(startSeconds: start, endSeconds: end)
    }

    public static func firstVisibleClipSeconds(in project: CamOrderProject) -> Double {
        editedRange(in: project)?.startSeconds ?? 0
    }

    private func insertMasterAudioIfNeeded(project: CamOrderProject, folderURL: URL, composition: AVMutableComposition, outputDuration: Double) async throws {
        guard project.exportSettings.audioMode == .masteredOnly || project.exportSettings.audioMode == .masteredAndCamera,
              let relativePath = project.audio.masteredAudioFile else {
            return
        }
        let asset = AVURLAsset(url: folderURL.appendingPathComponent(relativePath))
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else { return }
        let duration = try await asset.load(.duration)
        let timelineDuration = outputDuration
        let sourceStartSeconds = max(0, -project.audio.audioOffsetSeconds)
        let destinationSeconds = max(0, project.audio.audioOffsetSeconds)
        let usableDuration = min(duration.seconds - sourceStartSeconds, timelineDuration - destinationSeconds)
        guard usableDuration > 0, let compositionTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return }
        try compositionTrack.insertTimeRange(
            CMTimeRange(
                start: CMTime(seconds: sourceStartSeconds, preferredTimescale: 600),
                duration: CMTime(seconds: usableDuration, preferredTimescale: 600)
            ),
            of: sourceTrack,
            at: CMTime(seconds: destinationSeconds, preferredTimescale: 600)
        )
    }

    private static func renderSize(for settings: ExportSettings) -> CGSize {
        switch settings.resolution {
        case .hd1080:
            return CGSize(width: settings.canvasWidth ?? 1920, height: settings.canvasHeight ?? 1080)
        case .uhd4k:
            return CGSize(width: settings.canvasWidth ?? 3840, height: settings.canvasHeight ?? 2160)
        case .source:
            return CGSize(width: settings.canvasWidth ?? 1920, height: settings.canvasHeight ?? 1080)
        }
    }

    private static func outputFileType(for settings: ExportSettings, destinationURL: URL) -> AVFileType {
        switch destinationURL.pathExtension.lowercased() {
        case "mp4":
            return .mp4
        case "m4v":
            return .m4v
        case "mov":
            return .mov
        default:
            switch settings.container {
            case .mp4:
                return .mp4
            case .m4v:
                return .m4v
            case .mov:
                return .mov
            }
        }
    }

    private static func videoSegments(for project: CamOrderProject) -> [RenderSegment] {
        var boundaries: Set<Double> = [0, project.timeline.durationSeconds]
        for lane in project.presentationTimeline.lanes where !lane.isMuted {
            for clip in lane.clips where clip.isEnabled {
                boundaries.insert(clip.timelineStartSeconds)
                boundaries.insert(clip.timelineStartSeconds + clip.durationSeconds)
                for marker in clip.automationMarkers {
                    let markerSeconds = clip.timelineStartSeconds + marker.timeSeconds
                    if markerSeconds > clip.timelineStartSeconds,
                       markerSeconds < clip.timelineStartSeconds + clip.durationSeconds {
                        boundaries.insert(markerSeconds)
                    }
                }
                guard !clip.automationMarkers.isEmpty else { continue }
                let localAutomationTimes = ([0, clip.durationSeconds] + clip.automationMarkers.map(\.timeSeconds))
                    .filter { $0.isFinite && $0 >= 0 && $0 <= clip.durationSeconds }
                    .sorted()
                let uniqueLocalAutomationTimes = localAutomationTimes.reduce(into: [Double]()) { result, seconds in
                    guard result.last.map({ abs($0 - seconds) > 0.001 }) ?? true else { return }
                    result.append(seconds)
                }
                for index in 0..<(max(0, uniqueLocalAutomationTimes.count - 1)) {
                    let start = uniqueLocalAutomationTimes[index]
                    let end = uniqueLocalAutomationTimes[index + 1]
                    guard end - start > 0.25 else { continue }
                    for step in 1..<8 {
                        let progress = Double(step) / 8.0
                        boundaries.insert(clip.timelineStartSeconds + start + (end - start) * progress)
                    }
                }
            }
        }
        // Every composition instruction must meet its neighbour on the same
        // CMTime tick. Independently rounded start/duration values can leave a
        // sub-millisecond gap that AVFoundation rejects after an animated cut.
        let sortedBoundaries = Array(Set(boundaries.filter { $0.isFinite && $0 >= 0 }
            .map { ($0 * 600).rounded() / 600 })).sorted()
        guard sortedBoundaries.count >= 2 else { return [] }

        var segments: [RenderSegment] = []
        for index in 0..<(sortedBoundaries.count - 1) {
            let start = sortedBoundaries[index]
            let end = sortedBoundaries[index + 1]
            guard end - start > 0.001 else { continue }
            let clips = project.playbackClips(at: (start + end) / 2)
            guard !clips.isEmpty else { continue }
            segments.append(RenderSegment(clips: clips, startSeconds: start, durationSeconds: end - start))
        }
        return segments
    }

    private static func topClip(at seconds: Double, in project: CamOrderProject) -> VideoClip? {
        project.playbackClip(at: seconds)
    }

    private static func displaySize(for track: AVAssetTrack) async throws -> CGSize {
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    private static func transform(for track: AVAssetTrack, sourceSize: CGSize, renderSize: CGSize, framing: ClipFraming) async throws -> CGAffineTransform {
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let normalize = CGAffineTransform(translationX: -transformedRect.minX, y: -transformedRect.minY)
        let baseScale = min(renderSize.width / max(1, sourceSize.width), renderSize.height / max(1, sourceSize.height))
        let scale = baseScale * max(0.25, min(16, framing.zoom))
        let scaledWidth = sourceSize.width * scale
        let scaledHeight = sourceSize.height * scale
        let translateX = (renderSize.width - scaledWidth) / 2 + CGFloat(framing.offsetX) * renderSize.width * 0.5
        // Video-composition coordinates run down from the top; the native
        // preview layer runs up from the bottom. Match the user's downward pan.
        let translateY = (renderSize.height - scaledHeight) / 2 + CGFloat(framing.offsetY) * renderSize.height * 0.5
        var transform = preferredTransform
            .concatenating(normalize)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: translateX, y: translateY))
        let radians = CGFloat(-framing.rotationDegrees * .pi / 180)
        if abs(radians) > 0.0001 {
            let center = CGPoint(x: renderSize.width / 2 + CGFloat(framing.offsetX) * renderSize.width * 0.5,
                                 y: renderSize.height / 2 + CGFloat(framing.offsetY) * renderSize.height * 0.5)
            transform = transform
                .concatenating(CGAffineTransform(translationX: -center.x, y: -center.y))
                .concatenating(CGAffineTransform(rotationAngle: radians))
                .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
        }
        return transform
    }
}

private struct RenderSegment {
    var clips: [VideoClip]
    var startSeconds: Double
    var durationSeconds: Double
}

private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }
}

public enum RenderExportError: LocalizedError {
    case couldNotCreateExportSession
    case couldNotCreateVideoTrack
    case noRenderableVideo
    case exportFailed

    public var errorDescription: String? {
        switch self {
        case .couldNotCreateExportSession:
            return "Could not create the AVFoundation export session."
        case .couldNotCreateVideoTrack:
            return "Could not create a render video track."
        case .noRenderableVideo:
            return "There are no enabled video regions available to render."
        case .exportFailed:
            return "The video export did not complete."
        }
    }
}

public final class MasterAudioImporter {
    public init() {}

    public func importAudio(from sourceURL: URL, into document: ProjectDocument) throws -> MediaAsset {
        let destination = document.folderURL
            .appendingPathComponent("media/audio")
            .appendingPathComponent(sourceURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return MediaAsset(
            kind: .audio,
            displayName: sourceURL.deletingPathExtension().lastPathComponent,
            relativePath: "media/audio/\(sourceURL.lastPathComponent)"
        )
    }
}
