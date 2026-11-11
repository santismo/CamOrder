import AppKit
import SwiftUI
import Combine
import CamOrderStudioCore

@MainActor
final class InputCropWindowController: NSWindowController, NSWindowDelegate {
    init(store: ProjectStore, inputs: LaneCaptureInputs, engine: CameraCaptureEngine, sourceID: String) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 680),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Crop input · " + inputs.name(for: sourceID)
        window.minSize = CGSize(width: 680, height: 500)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: InputCropEditor(store: store, engine: engine,
            sourceID: sourceID, name: inputs.name(for: sourceID), projectURL: store.document?.folderURL,
            initial: store.project.inputCrops?[sourceID] ?? .full, close: { [weak self] in self?.close() }))
        window.center()
    }
    func windowWillClose(_ notification: Notification) { window?.contentView = nil }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private struct InputCropEditor: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var engine: CameraCaptureEngine
    let sourceID: String
    let name: String
    let projectURL: URL?
    let close: () -> Void
    @State private var draft: InputCrop
    init(store: ProjectStore, engine: CameraCaptureEngine, sourceID: String, name: String, projectURL: URL?, initial: InputCrop, close: @escaping () -> Void) {
        self.store = store; self.engine = engine; self.sourceID = sourceID; self.name = name
        self.projectURL = projectURL; self.close = close
        _draft = State(initialValue: initial.normalized ?? .full)
    }
    private var busy: Bool {
        engine.isRecording || engine.isFinishingRecording || store.captureInputs?.inputIsBusy(sourceID) == true || store.document?.folderURL != projectURL
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(name).font(.headline).lineLimit(1)
            Text("Drag the edges or corners to remove borders. Drag inside to move the selection.")
                .font(.callout).foregroundStyle(.secondary)
            ZStack {
                InputCropCanvas(frames: engine.previewFrames, crop: $draft, editable: !busy)
                if !engine.isPreviewing {
                    VStack(spacing: 10) {
                        Text("Start the input preview to position the crop.")
                        Button("Start preview") { engine.startPreview() }.disabled(busy)
                        if let error = engine.lastErrorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
                    }.padding().background(.black.opacity(0.85))
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
            HStack(spacing: 20) {
                marginControl("Left", edge: 0)
                marginControl("Top", edge: 1)
                marginControl("Right", edge: 2)
                marginControl("Bottom", edge: 3)
            }.disabled(busy)
            Text(busy ? "Disarm this input’s lanes and wait for the take to finish before applying changes." : "Applies to new recordings from this input. Removed borders stay removed on Main Stage and in exports. Existing clips keep their original crop.")
                .font(.caption).foregroundStyle(busy ? .orange : .secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Reset to full frame") { draft = .full }.disabled(busy)
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Apply crop") {
                    guard !busy, store.setInputCrop(draft, sourceID: sourceID) else { return }
                    close()
                }.keyboardShortcut(.defaultAction).disabled(busy)
            }
        }.padding(18).frame(minWidth: 640, minHeight: 440)
            .onChange(of: store.document?.folderURL) { _ in close() }
    }
    private func marginControl(_ name: String, edge: Int) -> some View {
        let rect = draft.rect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let margins = [rect.minX, rect.minY, 1 - rect.maxX, 1 - rect.maxY]
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(name) · \(margins[edge] * 100, specifier: "%.1f")%").font(.caption.monospacedDigit())
            Slider(value: Binding(get: { margins[edge] }, set: { value in
                var left = rect.minX, top = rect.minY, right = rect.maxX, bottom = rect.maxY
                switch edge {
                case 0: left = min(value, right - 0.02)
                case 1: top = min(value, bottom - 0.02)
                case 2: right = max(1 - value, left + 0.02)
                default: bottom = max(1 - value, top + 0.02)
                }
                draft = InputCrop(x: left, y: top, width: right - left, height: bottom - top)
            }), in: 0...0.98).accessibilityLabel(name + " border removed")
        }
    }
}

struct InputCropCanvas: NSViewRepresentable {
    let frames: CapturePreviewFrames
    @Binding var crop: InputCrop
    var editable: Bool
    func makeNSView(context: Context) -> InputCropCanvasView { InputCropCanvasView(frames: frames) }
    func updateNSView(_ view: InputCropCanvasView, context: Context) {
        view.crop = crop; view.editable = editable
        view.onChange = { crop = $0 }
    }
}

/// Only the image layer changes on incoming frames. SwiftUI and the drag handles
/// update on crop edits or source-size changes, not at video frame rate.
final class InputCropCanvasView: NSView {
    override var isFlipped: Bool { true }
    var crop = InputCrop.full { didSet { updateOverlay() } }
    var editable = true
    var onChange: ((InputCrop) -> Void)?
    private let picture = CALayer()
    private let border = CALayer()
    private let shades = (0..<4).map { _ in CALayer() }
    private let handles = (0..<8).map { _ in CALayer() }
    private var subscription: AnyCancellable?
    private var imageSize = CGSize(width: 16, height: 9)
    private(set) var imageRect = CGRect.zero
    private var drag: (start: CGPoint, rect: CGRect, x: Int, y: Int)?
    init(frames: CapturePreviewFrames) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(picture)
        picture.contentsGravity = .resize
        for shade in shades { shade.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor; layer?.addSublayer(shade) }
        border.borderWidth = 1.5; border.borderColor = NSColor.systemCyan.cgColor; layer?.addSublayer(border)
        for handle in handles {
            handle.backgroundColor = NSColor.white.cgColor; handle.cornerRadius = 2
            handle.borderWidth = 1; handle.borderColor = NSColor.systemCyan.cgColor
            layer?.addSublayer(handle)
        }
        for item in [picture, border] + shades + handles { item.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull()] }
        subscription = frames.$image.sink { [weak self] image in
            guard let self else { return }
            self.picture.contents = image
            if let image {
                let size = CGSize(width: image.width, height: image.height)
                if self.imageSize != size { self.imageSize = size; self.needsLayout = true }
            }
        }
        setAccessibilityLabel("Input crop preview. Drag edges or corners, or use the border sliders.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        let available = bounds.insetBy(dx: 12, dy: 12)
        let scale = max(0, min(available.width / imageSize.width, available.height / imageSize.height))
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        imageRect = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        picture.frame = imageRect
        updateOverlay()
    }
    private var selection: CGRect {
        let rect = crop.rect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        return CGRect(x: imageRect.minX + rect.minX * imageRect.width, y: imageRect.minY + rect.minY * imageRect.height, width: rect.width * imageRect.width, height: rect.height * imageRect.height)
    }
    private func updateOverlay() {
        let r = selection, f = imageRect
        border.frame = r
        shades[0].frame = CGRect(x: f.minX, y: f.minY, width: f.width, height: max(0, r.minY - f.minY))
        shades[1].frame = CGRect(x: f.minX, y: r.maxY, width: f.width, height: max(0, f.maxY - r.maxY))
        shades[2].frame = CGRect(x: f.minX, y: r.minY, width: max(0, r.minX - f.minX), height: r.height)
        shades[3].frame = CGRect(x: r.maxX, y: r.minY, width: max(0, f.maxX - r.maxX), height: r.height)
        let points = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                      CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY),
                      CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
        for (handle, point) in zip(handles, points) { handle.frame = CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10) }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard editable, imageRect.width > 0, imageRect.height > 0 else { return }
        let p = convert(event.locationInWindow, from: nil), r = selection
        guard r.insetBy(dx: -12, dy: -12).contains(p), let rect = crop.rect else { return }
        let x = abs(p.x - r.minX) < 12 ? -1 : (abs(p.x - r.maxX) < 12 ? 1 : 0)
        let y = abs(p.y - r.minY) < 12 ? -1 : (abs(p.y - r.maxY) < 12 ? 1 : 0)
        drag = (p, rect, x, y)
    }
    override func mouseDragged(with event: NSEvent) {
        guard editable, let drag else { return }
        let p = convert(event.locationInWindow, from: nil)
        let dx = (p.x - drag.start.x) / imageRect.width, dy = (p.y - drag.start.y) / imageRect.height
        let r = drag.rect
        var l = r.minX, t = r.minY, right = r.maxX, bottom = r.maxY
        if drag.x == 0 && drag.y == 0 {
            l = min(1 - r.width, max(0, l + dx)); t = min(1 - r.height, max(0, t + dy))
            right = l + r.width; bottom = t + r.height
        } else {
            if drag.x < 0 { l = min(right - 0.02, max(0, l + dx)) }
            if drag.x > 0 { right = max(l + 0.02, min(1, right + dx)) }
            if drag.y < 0 { t = min(bottom - 0.02, max(0, t + dy)) }
            if drag.y > 0 { bottom = max(t + 0.02, min(1, bottom + dy)) }
        }
        crop = InputCrop(x: l, y: t, width: right - l, height: bottom - t)
        onChange?(crop)
    }
    override func mouseUp(with event: NSEvent) { drag = nil }
}
