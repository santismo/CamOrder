import AppKit
import CamOrderStudioCore

@MainActor
final class CaptureHelperDelegate: NSObject, NSApplicationDelegate {
    private let engine = CameraCaptureEngine()
    private var folder: URL!
    private var timer: Timer?
    private var quitting = false
    private var ownerPID: Int32 = 0
    private var acknowledgedSequence = 0
    private var lastHeartbeat = ProcessInfo.processInfo.systemUptime
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--channel" else { NSApp.terminate(nil); return }
        guard CommandLine.arguments[3] == "--owner-pid", let pid = Int32(CommandLine.arguments[4]), pid > 0 else { NSApp.terminate(nil); return }
        ownerPID = pid
        folder = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        guard folder.lastPathComponent.hasPrefix("camorder-capture-"), FileManager.default.fileExists(atPath: folder.path) else { NSApp.terminate(nil); return }
        engine.setPreviewImageDestination(folder.appendingPathComponent("preview.frames"))
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }
    private func poll() {
        let commands = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("command-") && $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in commands {
            if let data = try? Data(contentsOf: url), let command = try? JSONDecoder().decode(CaptureCommand.self, from: data) {
                handle(command)
                acknowledgedSequence = Int(url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "command-", with: "")) ?? acknowledgedSequence
            }
            try? FileManager.default.removeItem(at: url)
        }
        if let heartbeat = try? String(contentsOf: folder.appendingPathComponent("heartbeat")), let value = Double(heartbeat) { lastHeartbeat = value }
        if ProcessInfo.processInfo.systemUptime - lastHeartbeat > 15 && kill(ownerPID, 0) != 0 && errno == ESRCH { quitting = true; engine.stopRecording() }
        var status = CaptureStatus(engine: engine)
        status.acknowledgedSequence = acknowledgedSequence
        if let data = try? JSONEncoder().encode(status) { try? data.write(to: folder.appendingPathComponent("status.json"), options: .atomic) }
        if quitting && !engine.isRecording && !engine.isFinishingRecording {
            engine.stopPreview()
            timer?.invalidate()
            // All channel files belong to this helper instance; final movie lives in the project.
            try? FileManager.default.removeItem(at: folder)
            NSApp.terminate(nil)
        }
    }
    private func handle(_ command: CaptureCommand) {
        switch command.action {
        case "refresh": engine.refreshDevices()
        case "select": if let id = command.value { engine.selectDevice(id: id) }
        case "preview": engine.startPreview()
        case "stopPreview": engine.stopPreview()
        case "crop":
            if let rect = command.crop, rect.count == 4 { engine.setScreenCropRect(CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3])) }
            else { engine.setScreenCropRect(nil) }
        case "record":
            if let path = command.value {
                do { try engine.startRecording(to: URL(fileURLWithPath: path)) }
                catch { engine.reportCaptureFailure(error.localizedDescription, url: URL(fileURLWithPath: path)) }
            }
        case "stop": engine.stopRecording()
        case "quit": quitting = true; engine.stopRecording()
        default: break
        }
    }
}
MainActor.assumeIsolated {
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = CaptureHelperDelegate()
app.delegate = delegate
app.run()

}
