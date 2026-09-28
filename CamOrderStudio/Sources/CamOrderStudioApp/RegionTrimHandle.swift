import AppKit
import SwiftUI

/// Window coordinates and callbacks captured on mouse-down keep a moving left
/// edge stable while SwiftUI lays out the region's temporary trim preview.
struct RegionTrimHandle: NSViewRepresentable {
    let clipID: String
    let left: Bool
    let selected: Bool
    let onSelect: () -> Void
    let onChange: (CGFloat) -> Void
    let onEnd: (CGFloat) -> Void

    func makeNSView(context: Context) -> RegionTrimNSView { RegionTrimNSView() }
    func updateNSView(_ view: RegionTrimNSView, context: Context) {
        view.identifier = NSUserInterfaceItemIdentifier("trim-\(left ? "left" : "right")-\(clipID)")
        view.toolTip = left ? "Drag to trim or extend the region’s left edge" : "Drag to trim or extend the region’s right edge"
        view.setAccessibilityLabel(left ? "Region left edge" : "Region right edge")
        view.selected = selected
        view.onSelect = { _ in onSelect() }; view.onChange = onChange; view.onEnd = onEnd
        view.needsDisplay = true
    }
}

struct RegionMoveHandle: NSViewRepresentable {
    let clipID: String
    let onSelect: (NSEvent.ModifierFlags) -> Void
    let onClick: () -> Void
    let onChange: (CGFloat) -> Void
    let onEnd: (CGFloat) -> Void
    func makeNSView(context: Context) -> RegionTrimNSView {
        let view = RegionTrimNSView(); view.isBody = true; return view
    }
    func updateNSView(_ view: RegionTrimNSView, context: Context) {
        view.identifier = NSUserInterfaceItemIdentifier("region-body-\(clipID)")
        view.toolTip = "Shift-click to add/remove a region. Drag to move the selection. Option-drag bypasses snapping."
        view.setAccessibilityLabel("Select or move region")
        view.onSelect = onSelect; view.onClick = onClick
        view.onChange = onChange; view.onEnd = onEnd
    }
}

final class RegionTrimNSView: NSView {
    var isBody = false
    var selected = false
    var onSelect: ((NSEvent.ModifierFlags) -> Void)?
    var onClick: (() -> Void)?
    var onChange: ((CGFloat) -> Void)?
    var onEnd: ((CGFloat) -> Void)?
    private var origin: CGFloat?
    private var dragging = false
    private var extendingSelection = false
    private var dragChange: ((CGFloat) -> Void)?
    private var dragEnd: ((CGFloat) -> Void)?
    private weak var timeline: TimelineNativeScrollView?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: isBody ? .openHand : .resizeLeftRight) }
    override func draw(_ dirtyRect: NSRect) {
        guard !isBody else { return }
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 4, yRadius: 4).fill()
        (selected ? NSColor.systemYellow : NSColor.white.withAlphaComponent(0.75)).setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 1.5, y: 10, width: 3, height: max(1, bounds.height - 20)), xRadius: 1.5, yRadius: 1.5).fill()
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        origin = event.locationInWindow.x; dragging = false
        extendingSelection = event.modifierFlags.contains(.shift)
        dragChange = onChange; dragEnd = onEnd
        timeline = enclosingScrollView as? TimelineNativeScrollView
        timeline?.manualUntil = .infinity
        onSelect?(event.modifierFlags)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let origin else { return }
        let delta = event.locationInWindow.x - origin
        if abs(delta) >= 2 { dragging = true }
        if dragging { dragChange?(delta) }
    }
    override func mouseUp(with event: NSEvent) {
        guard let origin else { return }
        if dragging { dragEnd?(event.locationInWindow.x - origin) }
        else if isBody && !extendingSelection { onClick?() }
        finishDrag()
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { finishDrag() }
        super.viewWillMove(toWindow: newWindow)
    }
    private func finishDrag() {
        timeline?.manualUntil = ProcessInfo.processInfo.systemUptime + 2
        origin = nil; dragging = false; dragChange = nil; dragEnd = nil; timeline = nil
    }
}
