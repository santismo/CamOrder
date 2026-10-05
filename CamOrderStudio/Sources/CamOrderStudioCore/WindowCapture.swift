import AppKit
@preconcurrency import ScreenCaptureKit
@preconcurrency import AVFoundation

@MainActor
protocol WindowCaptureSession: AnyObject {
    func choose()
    func resume()
    func stop()
}

/// Lives in the capture helper, so Logic never owns screen capture permissions.
/// Only a deliberate Choose Window action presents the macOS consent picker.
@available(macOS 14.0, *)
@MainActor
final class WindowCapture: NSObject, WindowCaptureSession, SCContentSharingPickerObserver, SCStreamDelegate {
    private let writer: CaptureWriter
    private let canChange: () -> Bool
    private let state: (Bool, String?) -> Void
    private var filter: SCContentFilter?
    private var stream: SCStream?
    private var output: WindowStreamOutput?
    private var token: UUID?
    private var picking = false
    private var observing = false
    private var revision: UInt64 = 0
    private let background = CGColor(gray: 0, alpha: 1)

    init(writer: CaptureWriter, canChange: @escaping () -> Bool, state: @escaping (Bool, String?) -> Void) {
        self.writer = writer; self.canChange = canChange; self.state = state
        super.init()
    }

    func choose() {
        guard canChange(), !picking else { return }
        let picker = SCContentSharingPicker.shared
        if !observing { picker.add(self); observing = true }
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleWindow]
        // Replacement is explicit through CamOrder, never midway through a take.
        configuration.allowsChangingSelectedContent = false
        picker.defaultConfiguration = configuration
        picker.isActive = true
        picking = true
        NSApp.activate(ignoringOtherApps: true)
        picker.present(using: .window)
    }

    func resume() {
        guard canChange() else { return }
        if stream != nil { return }
        guard let filter else { state(false, "Choose a window to start its preview."); return }
        start(filter)
    }

    func stop() {
        revision &+= 1
        picking = false
        if observing {
            SCContentSharingPicker.shared.remove(self)
            SCContentSharingPicker.shared.isActive = false
            observing = false
        }
        stopStream()
    }

    private func stopStream() {
        if let token { writer.queue.async { [writer] in writer.endWindowStream(token: token) } }
        token = nil
        let previous = stream
        stream = nil; output = nil
        if let previous { Task { try? await previous.stopCapture() } }
    }

    private func start(_ filter: SCContentFilter) {
        guard canChange() else { return }
        let picker = SCContentSharingPicker.shared
        if !observing { picker.add(self); observing = true }
        picker.isActive = true
        revision &+= 1
        let generation = revision
        stopStream()
        self.filter = filter
        state(false, nil)
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        let size = filter.contentRect.size
        guard size.width.isFinite, size.height.isFinite, scale.isFinite,
              size.width > 0, size.height > 0, scale > 0 else {
            state(false, "This window has no visible content. Choose another window."); return
        }
        configuration.width = max(2, Int((size.width * scale / 2).rounded(.up)) * 2)
        configuration.height = max(2, Int((size.height * scale / 2).rounded(.up)) * 2)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 5
        configuration.capturesAudio = false
        configuration.showsCursor = true
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.ignoreShadowsSingleWindow = true
        configuration.backgroundColor = background
        let token = UUID()
        self.token = token
        let output = WindowStreamOutput(writer: writer, token: token) { [weak self] ready, message in
            Task { @MainActor in
                guard let self, self.revision == generation, self.stream != nil else { return }
                if !ready { self.stop(); self.filter = nil }
                self.state(ready, message)
            }
        }
        self.output = output
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.stream = stream
        writer.queue.async { [writer] in writer.beginWindowStream(token: token) }
        Task {
            do {
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: writer.queue)
                try await stream.startCapture()
                // A stop or a newer selection may have overtaken async start.
                if revision != generation { try? await stream.stopCapture() }
            } catch {
                guard revision == generation else { return }
                stop(); self.filter = nil
                state(false, "Window capture could not start: \(error.localizedDescription). Choose the window again.")
            }
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            guard self.picking else { return }
            self.picking = false
            guard self.canChange() else { return }
            self.start(filter)
        }
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in
            guard self.picking else { return }
            self.picking = false
            if self.stream == nil { self.state(false, "No window selected. Use Choose window to try again.") }
        }
    }
    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in
            guard self.picking else { return }
            self.picking = false
            self.state(self.stream != nil, "Could not open the window picker: \(error.localizedDescription)")
        }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard self.stream === stream else { return }
            self.stop(); self.filter = nil
            self.state(false, "Window sharing stopped: \(error.localizedDescription). Choose the window again.")
        }
    }
}

@available(macOS 14.0, *)
private final class WindowStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let writer: CaptureWriter
    private let token: UUID
    private let state: @Sendable (Bool, String?) -> Void
    private var delivered = false
    private var stopped = false
    init(writer: CaptureWriter, token: UUID, state: @escaping @Sendable (Bool, String?) -> Void) {
        self.writer = writer; self.token = token; self.state = state
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !stopped,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
        switch status {
        case .complete:
            guard writer.receiveWindowFrame(sample, token: token) else { return }
            if !delivered { delivered = true; state(true, nil) }
        case .idle, .started: break
        case .blank, .suspended, .stopped:
            stopped = true
            writer.endWindowStream(token: token)
            state(false, "The window is no longer available. Restore it, then choose it again.")
        @unknown default: break
        }
    }
}
