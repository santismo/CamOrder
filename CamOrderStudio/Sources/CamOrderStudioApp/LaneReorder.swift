import AppKit
import SwiftUI

/// An in-editor gesture: keep the lane in place until release, then save one
/// reorder. SwiftUI's item-provider drag/drop was unreliable inside AU hosts.
@MainActor
final class LaneReorderController: ObservableObject {
    struct Destination: Equatable { let laneID: String; let after: Bool }
    @Published private(set) var destination: Destination?
    @Published private(set) var draggedLaneID: String?
    private final class Row { weak var view: NSView?; init(_ view: NSView) { self.view = view } }
    private var rows: [String: Row] = [:]
    private weak var store: ProjectStore?
    private weak var scrollView: NSScrollView?
    private weak var window: NSWindow?
    private var projectPath: String?
    private var point = NSPoint.zero
    private var timer: Timer?

    func register(_ view: NSView, laneID: String) { rows[laneID] = Row(view) }
    func unregister(_ view: NSView, laneID: String) {
        if rows[laneID]?.view === view { rows.removeValue(forKey: laneID) }
    }
    func begin(laneID: String, store: ProjectStore, source: NSView) {
        cancel()
        guard let path = store.document?.folderURL.path, let window = source.window else { return }
        self.store = store; self.window = window; projectPath = path
        scrollView = source.enclosingScrollView
        draggedLaneID = laneID
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoscroll() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func update(at point: NSPoint) {
        self.point = point
        guard let store, store.document?.folderURL.path == projectPath,
              let window, let scrollView else { cancel(); return }
        let viewport = scrollView.contentView.convert(scrollView.contentView.bounds, to: nil)
        guard viewport.contains(point) else { setDestination(nil); return }
        let frames = store.project.timeline.lanes.compactMap { lane -> (String, NSRect)? in
            guard let view = rows[lane.id]?.view, view.window === window else { return nil }
            return (lane.id, view.convert(view.bounds, to: nil))
        }
        // Window coordinates increase upward. Gaps belong to the closest row.
        guard let nearest = frames.min(by: { abs($0.1.midY - point.y) < abs($1.1.midY - point.y) }) else {
            setDestination(nil); return
        }
        setDestination(Destination(laneID: nearest.0, after: point.y < nearest.1.midY))
    }
    func finish(at point: NSPoint) {
        update(at: point)
        let target = destination, source = draggedLaneID, store = store
        cancel()
        if let target, let source { store?.moveLane(source, relativeTo: target.laneID, after: target.after) }
    }
    func cancel() {
        timer?.invalidate(); timer = nil
        if draggedLaneID != nil { draggedLaneID = nil }
        setDestination(nil)
        store = nil; window = nil; scrollView = nil; projectPath = nil
    }
    private func setDestination(_ value: Destination?) {
        if destination != value { destination = value }
    }
    private func autoscroll() {
        guard let scrollView, let document = scrollView.documentView, draggedLaneID != nil else { return }
        let clip = scrollView.contentView
        let viewport = clip.convert(clip.bounds, to: nil)
        guard viewport.insetBy(dx: 0, dy: -24).contains(point) else { return }
        let down: CGFloat = point.y < viewport.minY + 28 ? 12 : (point.y > viewport.maxY - 28 ? -12 : 0)
        guard down != 0 else { return }
        var origin = clip.bounds.origin
        let minimum = document.bounds.minY, maximum = max(minimum, document.bounds.maxY - clip.bounds.height)
        origin.y = min(maximum, max(minimum, origin.y + (document.isFlipped ? down : -down)))
        guard origin != clip.bounds.origin else { return }
        clip.scroll(to: origin); scrollView.reflectScrolledClipView(clip)
        scrollView.layoutSubtreeIfNeeded()
        update(at: point)
    }
}

struct LaneReorderGrip: View {
    let laneID: String
    let number: Int
    let store: ProjectStore
    let controller: LaneReorderController
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal")
            Text("\(number)").monospacedDigit()
        }
        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
        .frame(width: 32, height: 22)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
        .overlay { LaneReorderMouseHandle(laneID: laneID, store: store, controller: controller) }
    }
}

private struct LaneReorderMouseHandle: NSViewRepresentable {
    let laneID: String
    let store: ProjectStore
    let controller: LaneReorderController
    func makeNSView(context: Context) -> LaneReorderNSView { LaneReorderNSView() }
    func updateNSView(_ view: LaneReorderNSView, context: Context) {
        view.laneID = laneID; view.store = store; view.controller = controller
        view.identifier = NSUserInterfaceItemIdentifier("lane-grip-\(laneID)")
        view.toolTip = "Drag this grip up or down across lanes. Release at the insertion line. Hold near the top or bottom to scroll. Escape cancels."
        view.setAccessibilityLabel("Reorder lane")
    }
}

final class LaneReorderNSView: NSView {
    var laneID = ""
    weak var store: ProjectStore?
    weak var controller: LaneReorderController?
    private var origin: NSPoint?
    private var dragging = false
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        origin = event.locationInWindow; dragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let origin, let store else { return }
        let point = event.locationInWindow
        if !dragging, hypot(point.x - origin.x, point.y - origin.y) >= 3 {
            controller?.begin(laneID: laneID, store: store, source: self)
            dragging = true
        }
        if dragging { controller?.update(at: point) }
    }
    override func mouseUp(with event: NSEvent) {
        let shouldFinish = dragging
        origin = nil; dragging = false
        if shouldFinish { controller?.finish(at: event.locationInWindow) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { origin = nil; dragging = false; controller?.cancel() }
        else { super.keyDown(with: event) }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, origin != nil {
            origin = nil; dragging = false; controller?.cancel()
        }
        super.viewWillMove(toWindow: newWindow)
    }
}

struct LaneReorderTarget: ViewModifier {
    @ObservedObject var controller: LaneReorderController
    let laneID: String
    var registerGeometry = true
    func body(content: Content) -> some View {
        content
            .background {
                if registerGeometry { LaneReorderRow(laneID: laneID, controller: controller) }
            }
            .overlay(alignment: controller.destination?.after == true ? .bottom : .top) {
                if controller.destination?.laneID == laneID {
                    Rectangle().fill(Color.accentColor).frame(height: 3).allowsHitTesting(false)
                }
            }
    }
}

private struct LaneReorderRow: NSViewRepresentable {
    let laneID: String
    let controller: LaneReorderController
    func makeNSView(context: Context) -> LaneReorderRowNSView { LaneReorderRowNSView() }
    func updateNSView(_ view: LaneReorderRowNSView, context: Context) {
        view.laneID = laneID; view.controller = controller
        controller.register(view, laneID: laneID)
    }
    static func dismantleNSView(_ view: LaneReorderRowNSView, coordinator: ()) {
        view.controller?.unregister(view, laneID: view.laneID)
    }
}
private final class LaneReorderRowNSView: NSView {
    var laneID = ""
    weak var controller: LaneReorderController?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
