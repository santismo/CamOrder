import AppKit
import CoreGraphics

@MainActor
final class CaptureRegionController: NSObject, ObservableObject {
    private var panel: NSPanel?
    private var liveUpdateTimer: Timer?
    private var lastNotifiedRect: CGRect?
    var onRegionChanged: ((CGRect?) -> Void)?

    func show() {
        if panel == nil {
            panel = makePanel()
        }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startLiveUpdates()
        notifyRegionChanged()
    }

    func hide() {
        panel?.orderOut(nil)
        stopLiveUpdates()
    }

    func captureRectForMainDisplay() -> CGRect? {
        guard let panel else { return nil }
        guard let contentView = panel.contentView else { return nil }
        guard let screen = panel.screen ?? NSScreen.main else { return nil }
        let screenFrame = screen.frame
        let contentBounds = contentView.bounds.insetBy(dx: 8, dy: 8)
        let windowRect = contentView.convert(contentBounds, to: nil)
        let screenRect = panel.convertToScreen(windowRect)
        let x = max(0, screenRect.minX - screenFrame.minX)
        let y = max(0, screenRect.minY - screenFrame.minY)
        let maxWidth = max(1, screenFrame.width - x)
        let maxHeight = max(1, screenFrame.height - y)
        return CGRect(
            x: x,
            y: y,
            width: min(screenRect.width, maxWidth),
            height: min(screenRect.height, maxHeight)
        )
    }

    private func makePanel() -> NSPanel {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 100, y: 100, width: 1280, height: 720)
        let initialFrame = NSRect(
            x: screenFrame.midX - 320,
            y: screenFrame.midY - 180,
            width: 640,
            height: 360
        )
        let panel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "CamOrder Capture Region"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.alphaValue = 0.98
        panel.sharingType = .none
        panel.contentView = CaptureRegionView(frame: initialFrame)
        panel.minSize = NSSize(width: 160, height: 90)
        panel.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(regionPanelChanged(_:)), name: NSWindow.didMoveNotification, object: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(regionPanelChanged(_:)), name: NSWindow.didResizeNotification, object: panel)
        return panel
    }

    @objc private func regionPanelChanged(_ notification: Notification) {
        notifyRegionChanged()
    }

    private func notifyRegionChanged() {
        let rect = captureRectForMainDisplay()
        guard rect != lastNotifiedRect else { return }
        lastNotifiedRect = rect
        onRegionChanged?(rect)
    }

    private func startLiveUpdates() {
        liveUpdateTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.notifyRegionChanged()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        liveUpdateTimer = timer
    }

    private func stopLiveUpdates() {
        liveUpdateTimer?.invalidate()
        liveUpdateTimer = nil
    }
}

extension CaptureRegionController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        stopLiveUpdates()
    }
}

private final class CaptureRegionView: NSView {
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill()

        let border = NSBezierPath(rect: bounds.insetBy(dx: 4, dy: 4))
        NSColor.systemRed.setStroke()
        border.lineWidth = 2
        border.stroke()
    }
}
