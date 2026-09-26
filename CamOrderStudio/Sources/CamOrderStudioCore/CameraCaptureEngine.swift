import Foundation
@preconcurrency import AVFoundation
import CoreGraphics
import CoreMediaIO
import AppKit
import CoreImage

@MainActor
public final class CameraCaptureEngine: NSObject, ObservableObject {
    @Published public private(set) var isPreviewing = false
    @Published public private(set) var isRecording = false
    @Published public private(set) var isFinishingRecording = false
    @Published public private(set) var availableDevices: [CameraDeviceInfo] = []
    @Published public private(set) var selectedDeviceID: String?
    @Published public private(set) var lastErrorMessage: String?
    @Published public private(set) var lastRecordedFileURL: URL?
    @Published public private(set) var lastRecordingStartedHostTime: UInt64?
    @Published public private(set) var lastRecordingDuration: Double = 0
    public let previewSession: AVCaptureSession
    public private(set) var screenCropRect: CGRect?
    public let previewFrames = CapturePreviewFrames()
    private var previewWanted = false
    private var didAutoPreview = false
    public var usesCaptureHelper: Bool { remote != nil }
    private var remote: CaptureHelperClient?
    private var remoteRecordingURL: URL?
    private let worker: CaptureWriter
    private var startingPreview = false
    private var previewConfigurationRevision: UInt64 = 0
    private var observers: [NSObjectProtocol] = []

    public init(useCaptureHelper: Bool = false, automaticallyPreviewsDefaultSource: Bool = true) {
        worker = CaptureWriter()
        previewSession = worker.session
        super.init()
        worker.onStarted = { [weak self] seconds in
            Task { @MainActor in self?.lastRecordingStartedHostTime = UInt64(max(0, seconds) * 1e9) }
        }
        worker.onFinished = { [weak self] url, duration, error in
            Task { @MainActor in
                guard let self else { return }
                self.isRecording = false
                self.isFinishingRecording = false
                self.lastRecordingDuration = duration
                self.lastErrorMessage = error
                // Publish completion even on failure so a pending take can be cleared.
                self.lastRecordedFileURL = url
            }
        }
        if useCaptureHelper {
            do {
                let remote = try CaptureHelperClient()
                self.remote = remote
                remote.onStatus = { [weak self] status in
                    guard let self else { return }
                    if self.availableDevices != status.devices { self.availableDevices = status.devices }
                    if self.selectedDeviceID != status.selectedID { self.selectedDeviceID = status.selectedID }
                    if self.isPreviewing != status.previewing { self.isPreviewing = status.previewing }
                    if self.isRecording != status.recording { self.isRecording = status.recording }
                    if self.isFinishingRecording != status.finishing { self.isFinishingRecording = status.finishing }
                    if self.lastErrorMessage != status.error { self.lastErrorMessage = status.error }
                    if self.lastRecordingStartedHostTime != status.firstFrameHostTime { self.lastRecordingStartedHostTime = status.firstFrameHostTime }
                    if self.lastRecordingDuration != status.duration { self.lastRecordingDuration = status.duration }
                    let recordedURL = status.recordedPath.map { URL(fileURLWithPath: $0) }
                    if self.lastRecordedFileURL != recordedURL { self.lastRecordedFileURL = recordedURL }
                    if automaticallyPreviewsDefaultSource, !self.didAutoPreview, status.selectedID != nil, !status.recording {
                        self.didAutoPreview = true
                        if ProcessInfo.processInfo.environment["CAMORDER_DISABLE_AUTOPREVIEW_FOR_TESTS"] != "1" { self.startPreview() }
                    }
                }
                remote.onImage = { [weak self] in self?.previewFrames.display($0) }
                remote.onWarning = { [weak self] in self?.lastErrorMessage = $0 }
                remote.onError = { [weak self] message in
                    guard let self else { return }
                    if let url = self.remoteRecordingURL, self.isRecording || self.isFinishingRecording { self.reportCaptureFailure(message, url: url) }
                    else { self.lastErrorMessage = message }
                }
                remote.launch()
            } catch { lastErrorMessage = error.localizedDescription }
            return
        }
        refreshDevices()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshDevices() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: previewSession, queue: .main) { [weak self] note in
            let message = (note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "The capture input stopped. Reconnect it and restart preview."
            Task { @MainActor in
                self?.lastErrorMessage = message
                self?.stopRecording()
                self?.isPreviewing = false
            }
        })
    }
    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        let worker = worker
        if let remote { Task { @MainActor in remote.shutdown() } }
        worker.queue.async { worker.finish(); worker.session.stopRunning() }
    }
    public func refreshDevices() {
        if let remote { remote.send(CaptureCommand("refresh")); return }
        // Expose a trusted wired iPhone/iPad screen when macOS supplies it as a capture device.
        var address = CMIOObjectPropertyAddress(mSelector: UInt32(kCMIOHardwarePropertyAllowScreenCaptureDevices), mScope: UInt32(kCMIOObjectPropertyScopeGlobal), mElement: UInt32(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, 4, &allow)
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .externalUnknown]
        if #available(macOS 14.0, *) { types.append(.continuityCamera) }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
        let devices = discovery.devices + AVCaptureDevice.DiscoverySession(deviceTypes: [.externalUnknown], mediaType: .muxed, position: .unspecified).devices
        var seen = Set<String>()
        availableDevices = devices.compactMap { device in
            guard seen.insert(device.uniqueID).inserted else { return nil }
            return CameraDeviceInfo(id: device.uniqueID, displayName: device.localizedName)
        }
        availableDevices += [
            CameraDeviceInfo(id: "screen:main", displayName: "Main display", kind: .screen),
            CameraDeviceInfo(id: "screen:region", displayName: "Screen region (main display)", kind: .screen)
        ]
        if selectedDeviceID == nil { selectedDeviceID = availableDevices.first?.id }
    }
    public func selectDevice(id: String) {
        guard !isRecording, !isFinishingRecording else { return }
        previewConfigurationRevision &+= 1
        selectedDeviceID = id
        previewWanted = true
        previewFrames.clear()
        didAutoPreview = true
        if let remote { remote.send(CaptureCommand("select", value: id)); return }
        startPreview()
    }
    public func selectedDeviceInfo() -> CameraDeviceInfo? { availableDevices.first { $0.id == selectedDeviceID } }
    public func setScreenCropRect(_ rect: CGRect?) {
        guard !isRecording, !isFinishingRecording else { return }
        if screenCropRect != rect { previewConfigurationRevision &+= 1 }
        screenCropRect = rect
        if rect == nil, selectedDeviceID == "screen:region" {
            stopPreview()
            lastErrorMessage = "Keep the capture frame on the main display, then apply the region again."
        }
        if let remote { remote.send(CaptureCommand("crop", crop: rect.map { [$0.origin.x, $0.origin.y, $0.width, $0.height] })); return }
        if selectedDeviceID == "screen:region", rect != nil { startPreview() }
    }
    public func startPreview() {
        previewWanted = true
        if let remote { remote.send(CaptureCommand("preview")); return }
        guard !isRecording, !isFinishingRecording, !startingPreview, let id = selectedDeviceID else { return }
        startingPreview = true
        isPreviewing = false
        let configurationRevision = previewConfigurationRevision
        Task {
            defer {
                startingPreview = false
                if previewWanted, previewConfigurationRevision != configurationRevision { startPreview() }
            }
            if id.hasPrefix("screen:") || id.hasPrefix("window:") {
                guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
                    lastErrorMessage = "Allow Screen Recording for CamOrder Capture (or CamOrder Studio when running standalone) in System Settings → Privacy & Security, then reopen the host."
                    return
                }
                if id == "screen:region", screenCropRect == nil {
                    lastErrorMessage = "Use Show Region, position the frame on the main display, then Apply before starting preview."
                    return
                }
            } else {
                let status = AVCaptureDevice.authorizationStatus(for: .video)
                var allowed = status == .authorized
                if status == .notDetermined { allowed = await AVCaptureDevice.requestAccess(for: .video) }
                guard allowed else {
                    lastErrorMessage = "Allow Camera access for CamOrder Capture (or CamOrder Studio) in System Settings → Privacy & Security."
                    return
                }
            }
            guard previewWanted, selectedDeviceID == id else { return }
            let crop = screenCropRect
            let result: String? = await withCheckedContinuation { continuation in
                worker.queue.async { [worker] in
                    do { try worker.configure(id: id, crop: crop); continuation.resume(returning: nil) }
                    catch { continuation.resume(returning: error.localizedDescription) }
                }
            }
            isPreviewing = result == nil && previewWanted && previewConfigurationRevision == configurationRevision
            lastErrorMessage = result
            if !previewWanted { worker.queue.async { [worker] in worker.session.stopRunning() } }
        }
    }
    public func stopPreview() {
        previewWanted = false
        didAutoPreview = true
        previewFrames.clear()
        if let remote { remote.send(CaptureCommand("stopPreview")); isPreviewing = false; return }
        guard !isRecording, !isFinishingRecording else { return }
        worker.queue.async { [worker] in worker.session.stopRunning() }
        isPreviewing = false
    }
    public func startRecording(to url: URL) throws {
        guard isPreviewing, !startingPreview, !isRecording, !isFinishingRecording else {
            throw CaptureFailure("Start the input preview and wait for the live image before arming a lane.")
        }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw CaptureFailure("This recording file already exists. Choose a new take; existing media will never be overwritten.")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        lastRecordedFileURL = nil
        lastRecordingStartedHostTime = nil
        lastRecordingDuration = 0
        lastErrorMessage = nil
        isRecording = true
        if let remote { remoteRecordingURL = url; remote.send(CaptureCommand("record", value: url.path)); return }
        worker.queue.async { [worker] in worker.begin(url: url) }
    }
    public func stopRecording() {
        guard isRecording, !isFinishingRecording else { return }
        isFinishingRecording = true
        if let remote { remote.send(CaptureCommand("stop")); return }
        worker.queue.async { [worker] in worker.finish() }
    }
    public func setPreviewImageDestination(_ url: URL) {
        worker.queue.async { [worker] in worker.previewPublisher = try? PreviewPublisher(url: url) }
    }
    public func reportCaptureFailure(_ message: String, url: URL) {
        isRecording = false; isFinishingRecording = false
        lastErrorMessage = message; lastRecordingDuration = 0; lastRecordedFileURL = url
    }
    public func markRecordingStoppedForUnsupportedSource() { isRecording = false; isFinishingRecording = false }
    public static func estimatedLatencyMs(for source: CameraDeviceInfo?) -> Int { 0 }
}

private struct CaptureFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// All session configuration, sample callbacks and writer changes share this serial queue.
// Camera/video timestamps are mapped into the same host clock used by the Audio Unit.
final class CaptureWriter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "com.santismo.CamOrderStudio.capture", qos: .userInitiated)
    var onStarted: (@Sendable (Double) -> Void)?
    var onFinished: (@Sendable (URL, Double, String?) -> Void)?
    private let output = AVCaptureVideoDataOutput()
    private var destination: URL?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var firstTime: CMTime?
    private var lastTime: CMTime?
    private var droppedFrames = 0
    var previewPublisher: PreviewPublisher?

    func configure(id: String, crop: CGRect?) throws {
        session.stopRunning()
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.inputs.forEach(session.removeInput)
        let captureInput: AVCaptureInput
        if id.hasPrefix("screen:") || id.hasPrefix("window:") {
            guard let screen = AVCaptureScreenInput(displayID: CGMainDisplayID()) else { throw CaptureFailure("Screen capture is unavailable.") }
            screen.minFrameDuration = CMTime(value: 1, timescale: 30)
            screen.capturesCursor = true
            if id == "screen:region" || id.hasPrefix("window:"), let crop { screen.cropRect = crop }
            captureInput = screen
        } else {
            guard let device = AVCaptureDevice(uniqueID: id) else { throw CaptureFailure("The selected camera was disconnected. Reconnect it, refresh inputs, and try again.") }
            captureInput = try AVCaptureDeviceInput(device: device)
        }
        guard session.canAddInput(captureInput) else { throw CaptureFailure("This camera is busy or cannot provide video. Close other camera apps and try again.") }
        session.addInput(captureInput)
        if !session.outputs.contains(output) {
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else { throw CaptureFailure("Cannot create video capture output.") }
            session.addOutput(output)
        }
        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
        // Enqueued after commitConfiguration, on this same serial queue.
        queue.async { [self] in session.startRunning() }
    }
    func begin(url: URL) {
        destination = url
        firstTime = nil; lastTime = nil; droppedFrames = 0
        // A disconnected or silent device must not remain 'Recording' indefinitely.
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.destination == url, self.firstTime == nil else { return }
            self.finish(error: "No video frames arrived. Check the camera connection and restart preview.")
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if destination != nil { droppedFrames += 1 }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard CMSampleBufferDataIsReady(sample), let pixel = CMSampleBufferGetImageBuffer(sample) else { return }
        previewPublisher?.offer(pixel, timestamp: CMSampleBufferGetPresentationTimeStamp(sample).seconds)
        guard let url = destination else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        guard time.isValid, time.isNumeric else { return }
        do {
            if writer == nil {
                let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: CVPixelBufferGetWidth(pixel),
                    AVVideoHeightKey: CVPixelBufferGetHeight(pixel)
                ])
                input.expectsMediaDataInRealTime = true
                guard writer.canAdd(input) else { throw CaptureFailure("This capture format cannot be encoded.") }
                writer.add(input)
                guard writer.startWriting() else { throw writer.error ?? CaptureFailure("Cannot start recording.") }
                writer.startSession(atSourceTime: time)
                self.writer = writer; self.input = input
            }
            guard let writer, let input else { return }
            guard input.isReadyForMoreMediaData else { droppedFrames += 1; return }
            guard input.append(sample) else { throw writer.error ?? CaptureFailure("Video encoding failed.") }
            if firstTime == nil {
                firstTime = time
                let hostTime = session.synchronizationClock.map { CMSyncConvertTime(time, from: $0, to: CMClockGetHostTimeClock()) } ?? time
                onStarted?(hostTime.seconds)
            }
            lastTime = time
        } catch { finish(error: error.localizedDescription) }
    }
    func finish(error: String? = nil) {
        guard let url = destination else { return }
        destination = nil
        let writer = self.writer, input = self.input
        self.writer = nil; self.input = nil
        let duration = max(0, (lastTime?.seconds ?? 0) - (firstTime?.seconds ?? 0) + 1.0 / 30.0)
        let warning = error ?? (droppedFrames > 0 ? "Capture dropped \(droppedFrames) frames. Try a smaller resolution or close other video apps." : nil)
        guard let writer, firstTime != nil else {
            onFinished?(url, 0, error ?? "No video frames were recorded.")
            return
        }
        input?.markAsFinished()
        if writer.status == .writing {
            writer.finishWriting { [onFinished] in
                onFinished?(url, writer.status == .completed ? duration : 0, writer.error?.localizedDescription ?? warning)
            }
        } else {
            onFinished?(url, 0, writer.error?.localizedDescription ?? warning ?? "Recording failed.")
        }
        firstTime = nil; lastTime = nil
    }
}
