import Foundation
import AppKit

public struct CaptureCommand: Codable {
    public var action: String
    public var value: String?
    public var crop: [Double]?
    public init(_ action: String, value: String? = nil, crop: [Double]? = nil) { self.action = action; self.value = value; self.crop = crop }
}
public struct CaptureStatus: Codable {
    public var devices: [CameraDeviceInfo]
    public var selectedID: String?
    public var previewing: Bool
    public var recording: Bool
    public var finishing: Bool
    public var error: String?
    public var recordedPath: String?
    public var firstFrameHostTime: UInt64?
    public var duration: Double
    public var acknowledgedSequence: Int = 0
    public var updated: Double
    @MainActor public init(engine: CameraCaptureEngine) {
        devices = engine.availableDevices; selectedID = engine.selectedDeviceID
        previewing = engine.isPreviewing; recording = engine.isRecording; finishing = engine.isFinishingRecording
        error = engine.lastErrorMessage; recordedPath = engine.lastRecordedFileURL?.path
        firstFrameHostTime = engine.lastRecordingStartedHostTime; duration = engine.lastRecordingDuration
        updated = ProcessInfo.processInfo.systemUptime
    }
}

@MainActor
final class CaptureHelperClient {
    let folder: URL
    var onStatus: ((CaptureStatus) -> Void)?
    var onImage: ((CGImage) -> Void)?
    var onWarning: ((String) -> Void)?
    var onError: ((String) -> Void)?
    private var timer: Timer?
    private var sequence = 0
    private var lastStatus: Double = 0
    private var receiver: PreviewReceiver?
    private var heartbeat: DispatchSourceTimer?
    private var application: NSRunningApplication?
    private var warned = false
    private var started = ProcessInfo.processInfo.systemUptime
    private var pending = Set<String>()

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("camorder-capture-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func launch() {
        guard let bundle = Bundle(identifier: "com.santismo.CamOrderStudio.AudioUnit"),
              let helper = bundle.url(forResource: "CamOrder Capture", withExtension: "app") else {
            onError?("The capture helper is missing. Reinstall CamOrder Studio.component.")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--channel", folder.path, "--owner-pid", String(ProcessInfo.processInfo.processIdentifier)]
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: helper, configuration: configuration) { [weak self] application, error in
            Task { @MainActor in
                self?.application = application
                if let error { self?.onError?("Could not start CamOrder Capture: \(error.localizedDescription)") }
            }
        }
        receiver = PreviewReceiver(url: folder.appendingPathComponent("preview.frames")) { [weak self] image in
            MainActor.assumeIsolated { self?.onImage?(image) }
        }
        let heartbeatURL = folder.appendingPathComponent("heartbeat")
        let heartbeat = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.santismo.CamOrder.heartbeat"))
        heartbeat.schedule(deadline: .now(), repeating: 1)
        heartbeat.setEventHandler {
            try? Data(String(ProcessInfo.processInfo.systemUptime).utf8).write(to: heartbeatURL, options: .atomic)
        }
        self.heartbeat = heartbeat
        heartbeat.resume()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func send(_ command: CaptureCommand) {
        sequence += 1
        let name = String(format: "command-%08d.json", sequence)
        do {
            try JSONEncoder().encode(command).write(to: folder.appendingPathComponent(name), options: .atomic)
            pending.insert(name)
        } catch { onError?(error.localizedDescription) }
    }
    private func poll() {
        let now = ProcessInfo.processInfo.systemUptime
        pending = pending.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        if pending.isEmpty,
           let data = try? Data(contentsOf: folder.appendingPathComponent("status.json")),
           let status = try? JSONDecoder().decode(CaptureStatus.self, from: data), status.updated > lastStatus, status.acknowledgedSequence >= sequence {
            lastStatus = status.updated
            warned = false
            onStatus?(status)
        }
        if now - max(started, lastStatus) > 12, !warned {
            warned = true
            if application?.isTerminated == true {
                onError?("CamOrder Capture closed. Save the project and reopen Logic to reconnect it.")
            } else {
                onWarning?("Capture status is delayed. An active recording will continue; use Stop Take when ready.")
            }
        }
    }

    func shutdown() { send(CaptureCommand("quit")); timer?.invalidate(); timer = nil; heartbeat?.cancel(); heartbeat = nil; receiver = nil }
}
