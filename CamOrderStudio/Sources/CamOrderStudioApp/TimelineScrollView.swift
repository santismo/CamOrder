import AppKit
import SwiftUI
import CamOrderStudioCore

/// Native scrolling keeps an absolute pixel origin; offset SwiftUI ruler labels
/// are not scroll targets. Clock ticks move this viewport without rebuilding clips.
struct TimelineScrollView<Content: View>: NSViewRepresentable {
    let width: CGFloat
    let height: CGFloat
    let scale: Double
    let seconds: () -> Double
    let playing: () -> Bool
    let zoom: (Double) -> Void
    let extend: (Double) -> Void
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> TimelineNativeScrollView {
        let view = TimelineNativeScrollView()
        view.hasHorizontalScroller = true; view.hasVerticalScroller = false
        view.scrollerStyle = .overlay; view.drawsBackground = false
        let host = NSHostingView(rootView: content())
        host.sizingOptions = []
        view.documentView = host
        context.coordinator.host = host; context.coordinator.view = view
        view.onMagnify = { [weak coordinator = context.coordinator] amount, anchor in coordinator?.magnify(amount, anchor: anchor) }
        context.coordinator.start()
        return view
    }
    func updateNSView(_ view: TimelineNativeScrollView, context: Context) {
        let state = context.coordinator
        let oldOrigin = view.contentView.bounds.origin.x
        let previousScale = state.scale
        state.seconds = seconds; state.playing = playing; state.zoom = zoom; state.extend = extend; state.scale = scale
        state.host?.rootView = content()
        state.host?.setFrameSize(NSSize(width: width, height: height))
        var origin = oldOrigin
        if abs(previousScale - scale) > 0.0001 {
            let anchor = state.zoomAnchor ?? view.contentView.bounds.width / 2
            origin = TimelineViewport.zoomedOrigin(oldOrigin: oldOrigin, oldScale: previousScale, newScale: scale, anchorX: anchor)
            state.zoomAnchor = nil
        }
        state.scroll(to: origin)
        state.follow()
    }
    static func dismantleNSView(_ view: TimelineNativeScrollView, coordinator: Coordinator) { coordinator.timer?.invalidate() }
    final class Coordinator {
        weak var view: TimelineNativeScrollView?
        var host: NSHostingView<Content>?
        var timer: Timer?
        var scale = 18.0
        var seconds: (() -> Double)?
        var playing: (() -> Bool)?
        var zoom: ((Double) -> Void)?
        var extend: ((Double) -> Void)?
        var zoomAnchor: CGFloat?
        var lastSeconds = -Double.infinity
        var hasPositioned = false
        var requestedExtent = 0.0
        deinit { timer?.invalidate() }
        func start() {
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.follow() }
            RunLoop.main.add(timer, forMode: .common); self.timer = timer
        }
        func scroll(to x: Double) {
            guard let view, let host else { return }
            let target = min(max(0, host.frame.width - view.contentView.bounds.width), max(0, x))
            guard abs(view.contentView.bounds.minX - target) > 0.5 else { return }
            view.contentView.scroll(to: CGPoint(x: target, y: 0))
            view.reflectScrolledClipView(view.contentView)
        }
        func follow() {
            guard let view, let host, let second = seconds?(), second.isFinite else { return }
            let bounds = view.contentView.bounds
            // SwiftUI first updates a zero-width NSScrollView. Wait for layout,
            // otherwise the initial playhead gets pinned to the left edge.
            guard bounds.width > 1, host.frame.width > 1 else { return }
            if second * scale > host.frame.width - 30 * scale, second > requestedExtent {
                requestedExtent = (second / 30).rounded(.up) * 30 + 30
                let requested = requestedExtent
                DispatchQueue.main.async { [weak self] in self?.extend?(requested) }
            }
            let changed = abs(lastSeconds - second) > 0.001
            lastSeconds = second
            guard ProcessInfo.processInfo.systemUptime >= view.manualUntil else { return }
            let outside = second * scale < bounds.minX || second * scale > bounds.maxX - 16
            if !hasPositioned || playing?() == true || (changed && outside) {
                scroll(to: TimelineViewport.centeredOrigin(seconds: second, scale: scale,
                    viewportWidth: bounds.width, contentWidth: host.frame.width))
                hasPositioned = true
            }
        }
        func magnify(_ amount: Double, anchor: CGFloat) {
            guard amount.isFinite else { return }
            zoomAnchor = anchor
            view?.manualUntil = ProcessInfo.processInfo.systemUptime + 0.3
            zoom?(min(240, max(4, scale * (1 + amount))))
        }
    }
}

final class TimelineNativeScrollView: NSScrollView {
    var onMagnify: ((Double, CGFloat) -> Void)?
    var manualUntil = 0.0
    override func magnify(with event: NSEvent) {
        let point = contentView.convert(event.locationInWindow, from: nil)
        onMagnify?(Double(event.magnification), point.x - contentView.bounds.minX)
    }
    override func scrollWheel(with event: NSEvent) {
        manualUntil = ProcessInfo.processInfo.systemUptime + 2
        super.scrollWheel(with: event)
    }
}
