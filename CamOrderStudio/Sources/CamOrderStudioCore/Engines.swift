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

    public init() {}

    public func startMTCInput() {
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

@MainActor
public final class CameraCaptureEngine: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    @Published public private(set) var isPreviewing = false
    @Published public private(set) var isRecording = false
    @Published public private(set) var isFinishingRecording = false
    @Published public private(set) var availableDevices: [CameraDeviceInfo] = []
    @Published public private(set) var selectedDeviceID: String?
    @Published public private(set) var lastErrorMessage: String?
    @Published public private(set) var lastRecordedFileURL: URL?
    @Published public private(set) var lastRecordingStartedHostTime: UInt64?

    public let previewSession = AVCaptureSession()
    public private(set) var screenCropRect: CGRect?
    private var currentInput: AVCaptureDeviceInput?
    private var currentScreenInput: AVCaptureScreenInput?
    private var selectedDeviceDisplayName: String?
    private let movieOutput = AVCaptureMovieFileOutput()

    public override init() {
        super.init()
        refreshDevices()
    }

    public func refreshDevices() {
        var deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .externalUnknown]
        if #available(macOS 14.0, *) {
            deviceTypes.append(.continuityCamera)
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        )
        var seenDeviceIds = Set<String>()
        var devices = discovery.devices.compactMap { device -> CameraDeviceInfo? in
            guard seenDeviceIds.insert(device.uniqueID).inserted else { return nil }
            return CameraDeviceInfo(id: device.uniqueID, displayName: device.localizedName, kind: .camera)
        }
        devices.append(CameraDeviceInfo(id: "screen:main", displayName: "Main Display Screen Capture", kind: .screen))
        devices.append(CameraDeviceInfo(id: "screen:all", displayName: "Whole Screen Capture", kind: .screen))
        devices.append(CameraDeviceInfo(id: "screen:region", displayName: "Custom Screen Region", kind: .screen))
        devices.append(CameraDeviceInfo(id: "window:region", displayName: "Windowed Capture", kind: .window))
        if let selectedDeviceID, !devices.contains(where: { $0.id == selectedDeviceID }) {
            let displayName = selectedDeviceDisplayName ?? "Previous Camera"
            devices.insert(CameraDeviceInfo(id: selectedDeviceID, displayName: "\(displayName) (reconnect)", kind: .camera), at: 0)
        }
        availableDevices = devices
        if selectedDeviceID == nil {
            selectedDeviceID = availableDevices.first?.id
            selectedDeviceDisplayName = availableDevices.first?.displayName
        } else if let selected = availableDevices.first(where: { $0.id == selectedDeviceID }) {
            selectedDeviceDisplayName = selected.displayName.replacingOccurrences(of: " (reconnect)", with: "")
        }
    }

    public func selectDevice(id: String) {
        selectedDeviceID = id
        selectedDeviceDisplayName = availableDevices.first(where: { $0.id == id })?.displayName.replacingOccurrences(of: " (reconnect)", with: "")
        if isPreviewing {
            startPreview()
        }
    }

    public func selectedDeviceInfo() -> CameraDeviceInfo? {
        refreshDevices()
        return availableDevices.first { $0.id == selectedDeviceID }
    }

    public func setScreenCropRect(_ rect: CGRect?) {
        screenCropRect = rect
        if selectedDeviceID?.hasPrefix("screen:") == true || selectedDeviceID?.hasPrefix("window:") == true {
            if let rect, selectedDeviceID != "screen:all" {
                currentScreenInput?.cropRect = rect
            } else {
                startPreview()
            }
        }
    }

    public func startPreview() {
        refreshDevices()
        guard let selectedDeviceID else {
            lastErrorMessage = "No camera is selected."
            return
        }

        if selectedDeviceID.hasPrefix("screen:") {
            configureScreenCapturePreview()
            return
        }

        if selectedDeviceID.hasPrefix("window:") {
            configureWindowCapturePreview()
            return
        }

        guard let device = AVCaptureDevice(uniqueID: selectedDeviceID) else {
            lastErrorMessage = "The selected camera is not currently available. Reconnect it, wake the iPhone, confirm Continuity Camera is enabled, then use Refresh Cameras."
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            previewSession.beginConfiguration()
            if let currentInput {
                previewSession.removeInput(currentInput)
            }
            if let currentScreenInput {
                previewSession.removeInput(currentScreenInput)
                self.currentScreenInput = nil
            }
            if previewSession.canAddInput(input) {
                previewSession.addInput(input)
                currentInput = input
            }
            if !previewSession.outputs.contains(movieOutput), previewSession.canAddOutput(movieOutput) {
                previewSession.addOutput(movieOutput)
            }
            previewSession.commitConfiguration()
            if !previewSession.isRunning {
                DispatchQueue.global(qos: .userInitiated).async { [previewSession] in
                    previewSession.startRunning()
                }
            }
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
        isPreviewing = true
    }

    private func configureScreenCapturePreview() {
        guard ensureScreenCapturePermission() else { return }
        guard let screenInput = AVCaptureScreenInput(displayID: CGMainDisplayID()) else {
            lastErrorMessage = "Could not create a screen capture input."
            return
        }
        screenInput.capturesCursor = true
        screenInput.capturesMouseClicks = false
        screenInput.minFrameDuration = CMTime(value: 1, timescale: 30)
        if selectedDeviceID == "screen:region", let screenCropRect {
            screenInput.cropRect = screenCropRect
        }

        configure(screenInput: screenInput)
        lastErrorMessage = nil
    }

    private func configureWindowCapturePreview() {
        guard ensureScreenCapturePermission() else { return }
        guard let screenInput = AVCaptureScreenInput(displayID: CGMainDisplayID()) else {
            lastErrorMessage = "Could not create a window capture input."
            return
        }
        screenInput.capturesCursor = true
        screenInput.capturesMouseClicks = false
        screenInput.minFrameDuration = CMTime(value: 1, timescale: 30)
        if let screenCropRect {
            screenInput.cropRect = screenCropRect
            lastErrorMessage = nil
        } else if let logicBounds = Self.logicWindowBoundsOnMainDisplay() {
            screenInput.cropRect = logicBounds
            lastErrorMessage = nil
        } else {
            lastErrorMessage = "Logic Pro window was not found. Use Show Region Box, place it over Logic, then Apply Region."
        }
        configure(screenInput: screenInput)
    }

    private func configure(screenInput: AVCaptureScreenInput) {
        previewSession.beginConfiguration()
        if let currentInput {
            previewSession.removeInput(currentInput)
            self.currentInput = nil
        }
        if let currentScreenInput {
            previewSession.removeInput(currentScreenInput)
        }
        if previewSession.canAddInput(screenInput) {
            previewSession.addInput(screenInput)
            currentScreenInput = screenInput
        }
        if !previewSession.outputs.contains(movieOutput), previewSession.canAddOutput(movieOutput) {
            previewSession.addOutput(movieOutput)
        }
        previewSession.commitConfiguration()
        if !previewSession.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [previewSession] in
                previewSession.startRunning()
            }
        }
        isPreviewing = true
    }

    private func ensureScreenCapturePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        let granted = CGRequestScreenCaptureAccess()
        if !granted {
            lastErrorMessage = "macOS reports Screen Recording permission is not available for CamOrder Studio. Toggle CamOrder Studio off/on in System Settings, quit the app, then reopen it."
        }
        return granted
    }

    public func stopPreview() {
        if previewSession.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [previewSession] in
                previewSession.stopRunning()
            }
        }
        isPreviewing = false
    }

    public func startRecording(to destinationURL: URL) throws {
        guard selectedDeviceID != nil else {
            lastErrorMessage = "Select a capture source before recording."
            throw CameraCaptureError.unsupportedSource
        }
        if !isPreviewing || !previewSession.outputs.contains(movieOutput) {
            startPreview()
        }
        guard previewSession.outputs.contains(movieOutput) else {
            lastErrorMessage = "Movie recording output is not available for this camera."
            throw CameraCaptureError.outputUnavailable
        }
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        lastRecordedFileURL = nil
        lastRecordingStartedHostTime = nil
        lastErrorMessage = nil
        isFinishingRecording = false
        isRecording = true
        movieOutput.startRecording(to: destinationURL, recordingDelegate: self)
    }

    public func stopRecording() {
        guard movieOutput.isRecording else {
            isRecording = false
            return
        }
        isFinishingRecording = true
        movieOutput.stopRecording()
    }

    nonisolated public func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        Task { @MainActor in
            self.isRecording = false
            self.isFinishingRecording = false
            self.lastRecordedFileURL = outputFileURL
            self.lastErrorMessage = error?.localizedDescription
        }
    }

    nonisolated public func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        Task { @MainActor in
            self.isRecording = true
            self.lastRecordedFileURL = nil
            self.lastRecordingStartedHostTime = DispatchTime.now().uptimeNanoseconds
            self.lastErrorMessage = nil
        }
    }

    public func markRecordingStoppedForUnsupportedSource() {
        isRecording = false
        isFinishingRecording = false
    }

    public static func estimatedLatencyMs(for source: CameraDeviceInfo?) -> Int {
        guard let source else { return 0 }
        let name = source.displayName.lowercased()
        switch source.kind {
        case .screen, .window:
            return 0
        case .camera:
            if name.contains("iphone") || name.contains("continuity") {
                return 140
            }
            if name.contains("obs") {
                return 120
            }
            if name.contains("facetime") || name.contains("built-in") || name.contains("built in") {
                return 45
            }
            if name.contains("usb") || name.contains("logitech") || name.contains("elgato") {
                return 80
            }
            return 70
        }
    }

    private static func logicWindowBoundsOnMainDisplay() -> CGRect? {
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let candidate = windowInfo.first { info in
            let owner = (info[kCGWindowOwnerName as String] as? String)?.lowercased() ?? ""
            let title = (info[kCGWindowName as String] as? String)?.lowercased() ?? ""
            return owner.contains("logic") || title.contains("logic")
        }
        guard let boundsDict = candidate?[kCGWindowBounds as String] as? [String: Any],
              let x = boundsDict["X"] as? CGFloat,
              let y = boundsDict["Y"] as? CGFloat,
              let width = boundsDict["Width"] as? CGFloat,
              let height = boundsDict["Height"] as? CGFloat else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }
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

    public func export(project: CamOrderProject, from folderURL: URL, to destinationURL: URL) async throws {
        progress = 0
        let composition = AVMutableComposition()
        let renderSize = Self.renderSize(for: project.exportSettings)
        let frameDuration = CMTime(seconds: 1.0 / max(1, project.frameRate.framesPerSecond), preferredTimescale: 600)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = frameDuration

        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RenderExportError.couldNotCreateVideoTrack
        }
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        let segments = Self.videoSegments(for: project)
        var maxVideoEndSeconds: Double = 0
        for segment in segments {
            guard let asset = project.media.first(where: { $0.id == segment.clip.mediaAssetId }) else {
                continue
            }
            let sourceAsset = AVURLAsset(url: folderURL.appendingPathComponent(asset.relativePath))
            guard let sourceTrack = try await sourceAsset.loadTracks(withMediaType: .video).first else {
                continue
            }

            let sourceDuration = try await sourceAsset.load(.duration)
            let sourceStartSeconds = max(0, segment.clip.trimInSeconds + segment.startSeconds - segment.clip.timelineStartSeconds + (segment.clip.playbackSyncOffsetSeconds ?? project.sync.defaultPlaybackSyncOffsetSeconds ?? 0))
            let availableSeconds = max(0, sourceDuration.seconds - sourceStartSeconds)
            let segmentDurationSeconds = min(segment.durationSeconds, availableSeconds)
            guard segmentDurationSeconds > 0 else { continue }

            let sourceRange = CMTimeRange(
                start: CMTime(seconds: sourceStartSeconds, preferredTimescale: 600),
                duration: CMTime(seconds: segmentDurationSeconds, preferredTimescale: 600)
            )
            let destinationTime = CMTime(seconds: segment.startSeconds, preferredTimescale: 600)
            try videoTrack.insertTimeRange(sourceRange, of: sourceTrack, at: destinationTime)

            if project.exportSettings.audioMode == .cameraOnly || project.exportSettings.audioMode == .masteredAndCamera,
               let sourceAudioTrack = try await sourceAsset.loadTracks(withMediaType: .audio).first,
               let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try? compositionAudioTrack.insertTimeRange(sourceRange, of: sourceAudioTrack, at: destinationTime)
            }

            let sourceSize = try await Self.displaySize(for: sourceTrack)
            let transform = try await Self.transform(
                for: sourceTrack,
                sourceSize: sourceSize,
                renderSize: renderSize,
                framing: segment.clip.framing ?? ClipFraming()
            )
            layerInstruction.setTransform(transform, at: destinationTime)
            maxVideoEndSeconds = max(maxVideoEndSeconds, segment.startSeconds + segmentDurationSeconds)
        }

        guard maxVideoEndSeconds > 0 else {
            throw RenderExportError.noRenderableVideo
        }
        try await insertMasterAudioIfNeeded(project: project, folderURL: folderURL, composition: composition)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: max(maxVideoEndSeconds, project.timeline.durationSeconds), preferredTimescale: 600)
        )
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw RenderExportError.couldNotCreateExportSession
        }
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        exportSession.outputURL = destinationURL
        exportSession.outputFileType = Self.outputFileType(for: project.exportSettings, destinationURL: destinationURL)
        exportSession.videoComposition = videoComposition

        let exportSessionBox = ExportSessionBox(exportSession)
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
        progress = 1
    }

    private func insertMasterAudioIfNeeded(project: CamOrderProject, folderURL: URL, composition: AVMutableComposition) async throws {
        guard project.exportSettings.audioMode == .masteredOnly || project.exportSettings.audioMode == .masteredAndCamera,
              let relativePath = project.audio.masteredAudioFile,
              let compositionTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return
        }
        let asset = AVURLAsset(url: folderURL.appendingPathComponent(relativePath))
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else { return }
        let duration = try await asset.load(.duration)
        let timelineDuration = max(project.timeline.durationSeconds, duration.seconds + max(0, project.audio.audioOffsetSeconds))
        let sourceStartSeconds = max(0, -project.audio.audioOffsetSeconds)
        let destinationSeconds = max(0, project.audio.audioOffsetSeconds)
        let usableDuration = min(duration.seconds - sourceStartSeconds, timelineDuration - destinationSeconds)
        guard usableDuration > 0 else { return }
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
        for lane in project.timeline.lanes where !lane.isMuted {
            for clip in lane.clips where clip.isEnabled {
                boundaries.insert(clip.timelineStartSeconds)
                boundaries.insert(clip.timelineStartSeconds + clip.durationSeconds)
            }
        }
        let sortedBoundaries = boundaries.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard sortedBoundaries.count >= 2 else { return [] }

        var segments: [RenderSegment] = []
        for index in 0..<(sortedBoundaries.count - 1) {
            let start = sortedBoundaries[index]
            let end = sortedBoundaries[index + 1]
            guard end - start > 0.001 else { continue }
            guard let clip = topClip(at: start + 0.0005, in: project) else { continue }
            segments.append(RenderSegment(clip: clip, startSeconds: start, durationSeconds: end - start))
        }
        return segments
    }

    private static func topClip(at seconds: Double, in project: CamOrderProject) -> VideoClip? {
        for lane in project.timeline.lanes where !lane.isMuted {
            if let clip = lane.clips.last(where: { clip in
                clip.isEnabled && seconds >= clip.timelineStartSeconds && seconds < clip.timelineStartSeconds + clip.durationSeconds
            }) {
                return clip
            }
        }
        return nil
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
        let translateY = (renderSize.height - scaledHeight) / 2 - CGFloat(framing.offsetY) * renderSize.height * 0.5
        var transform = preferredTransform
            .concatenating(normalize)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: translateX, y: translateY))
        let radians = CGFloat(framing.rotationDegrees * .pi / 180)
        if abs(radians) > 0.0001 {
            let center = CGPoint(x: renderSize.width / 2, y: renderSize.height / 2)
            transform = transform
                .concatenating(CGAffineTransform(translationX: -center.x, y: -center.y))
                .concatenating(CGAffineTransform(rotationAngle: radians))
                .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
        }
        return transform
    }
}

private struct RenderSegment {
    var clip: VideoClip
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
