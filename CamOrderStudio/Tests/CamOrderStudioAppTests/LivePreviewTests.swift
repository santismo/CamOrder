import XCTest
import SwiftUI
@testable import CamOrderStudioApp
@testable import CamOrderStudioCore

@MainActor
final class LivePreviewTests: XCTestCase {
    private func image(_ gray: CGFloat) -> CGImage {
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return context.makeImage()!
    }

    func testReusedLayerFollowsNewSourceAndIgnoresOldSource() {
        let camera = CapturePreviewFrames(), screen = CapturePreviewFrames(), window = CapturePreviewFrames()
        let cameraImage = image(0.2), screenImage = image(0.5), windowImage = image(0.8)
        camera.display(cameraImage); screen.display(screenImage)
        let view = LivePreviewLayerView(frames: camera)
        XCTAssertTrue((view.layer?.contents as AnyObject?) === cameraImage)
        view.bind(to: screen)
        XCTAssertTrue((view.layer?.contents as AnyObject?) === screenImage)
        camera.clear()
        XCTAssertTrue((view.layer?.contents as AnyObject?) === screenImage)
        view.bind(to: window)
        XCTAssertNil(view.layer?.contents, "A new idle input must clear the previous input's picture")
        screen.display(cameraImage)
        XCTAssertNil(view.layer?.contents)
        window.display(windowImage)
        XCTAssertTrue((view.layer?.contents as AnyObject?) === windowImage)
        view.bind(to: window)
        window.clear()
        XCTAssertNil(view.layer?.contents, "Repeated SwiftUI updates must keep the current subscription alive")
    }

    func testSwiftUIRepresentableReconnectsAfterInputReplacement() async throws {
        _ = NSApplication.shared
        let camera = CapturePreviewFrames(), screen = CapturePreviewFrames()
        let first = image(0.2), second = image(0.8)
        camera.display(first); screen.display(second)
        let host = NSHostingView(rootView: LivePreviewImage(frames: camera))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 120, height: 80), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        func preview(in view: NSView) -> LivePreviewLayerView? {
            (view as? LivePreviewLayerView) ?? view.subviews.lazy.compactMap { preview(in: $0) }.first
        }
        let native = try XCTUnwrap(preview(in: host))
        XCTAssertTrue((native.layer?.contents as AnyObject?) === first)
        host.rootView = LivePreviewImage(frames: screen)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(preview(in: host) === native, "Exercise reuse, not recreation of the native view")
        XCTAssertTrue((native.layer?.contents as AnyObject?) === second)
        camera.clear()
        XCTAssertTrue((native.layer?.contents as AnyObject?) === second)
        window.contentView = nil
    }
}
