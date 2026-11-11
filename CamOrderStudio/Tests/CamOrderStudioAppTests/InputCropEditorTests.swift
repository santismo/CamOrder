import XCTest
import SwiftUI
@testable import CamOrderStudioApp
@testable import CamOrderStudioCore

@MainActor
final class InputCropEditorTests: XCTestCase {
    func testPerSourcePersistenceSharedLanesBusyGuardsAndUndo() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".camorderstudio")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ProjectStore()
        var project = CamOrderProject.empty(); project.defaultCaptureSourceID = "ipad"
        project.timeline.lanes[2].captureSourceID = "iphone"
        store.document = try ProjectDocument.create(at: folder, project: project)
        let inputs = LaneCaptureInputs(store: store, discovery: CameraCaptureEngine(), createsEngines: false)
        store.captureInputs = inputs; inputs.reconcile()
        let crop = InputCrop(x: 0.1, y: 0.2, width: 0.7, height: 0.6)
        XCTAssertTrue(store.setInputCrop(crop, sourceID: "ipad"))
        XCTAssertEqual(inputs.lanes(for: "ipad").count, 2)
        XCTAssertEqual(try ProjectDocument.open(at: folder).project.inputCrops?["ipad"], crop.normalized)
        XCTAssertNil(store.project.inputCrops?["iphone"])
        store.undoProjectChange(); XCTAssertNil(store.project.inputCrops?["ipad"])
        store.redoProjectChange(); XCTAssertEqual(store.project.inputCrops?["ipad"], crop.normalized)
        store.armLane(project.timeline.lanes[1].id)
        XCTAssertFalse(store.setInputCrop(.full, sourceID: "ipad"), "Any armed lane locks its shared input")
        XCTAssertTrue(store.setInputCrop(crop, sourceID: "iphone"), "An unrelated idle input can still change")
        store.undoProjectChange(); store.undoProjectChange()
        XCTAssertEqual(store.project.inputCrops?["ipad"], crop.normalized, "Undo cannot alter an active pre-roll crop")
        store.unarmAllLanes()
        XCTAssertTrue(store.setInputCrop(.full, sourceID: "ipad"))
        XCTAssertNil(try ProjectDocument.open(at: folder).project.inputCrops?["ipad"])
    }

    func testPreviewCropAndRawEditorStayIndependent() throws {
        let frames = CapturePreviewFrames()
        let image = fixture()
        frames.display(image)
        let view = LivePreviewLayerView(frames: frames, crop: InputCrop(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        let contents = try XCTUnwrap(view.layer?.contents)
        let cropped = contents as! CGImage
        XCTAssertEqual(cropped.width, 320); XCTAssertEqual(cropped.height, 180)
        XCTAssertTrue(frames.image === image, "Cropping a live card must retain the full feed for the editor")
        view.setCrop(nil)
        XCTAssertTrue((view.layer?.contents as AnyObject?) === image)
    }

    func testCropCanvasDragResizesAndMovesWithinLetterboxedSource() throws {
        _ = NSApplication.shared
        let frames = CapturePreviewFrames(); frames.display(fixture())
        let view = InputCropCanvasView(frames: frames)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view; view.layoutSubtreeIfNeeded()
        defer { window.contentView = nil }
        let f = view.imageRect
        func event(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(CGPoint(x: x, y: y), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: event(.leftMouseDown, x: f.minX, y: f.minY))
        view.mouseDragged(with: event(.leftMouseDragged, x: f.minX + f.width * 0.25, y: f.minY + f.height * 0.2))
        view.mouseUp(with: event(.leftMouseUp, x: f.minX, y: f.minY))
        XCTAssertEqual(view.crop.x, 0.25, accuracy: 0.001); XCTAssertEqual(view.crop.y, 0.2, accuracy: 0.001)
        XCTAssertEqual(view.crop.width, 0.75, accuracy: 0.001)
        view.mouseDown(with: event(.leftMouseDown, x: f.midX, y: f.midY))
        view.mouseDragged(with: event(.leftMouseDragged, x: -400, y: -400))
        view.mouseUp(with: event(.leftMouseUp, x: 0, y: 0))
        XCTAssertEqual(view.crop.x, 0); XCTAssertEqual(view.crop.y, 0)
        XCTAssertEqual(view.crop.width, 0.75, accuracy: 0.001)
        view.editable = false
        view.mouseDown(with: event(.leftMouseDown, x: f.minX, y: f.minY))
        view.mouseDragged(with: event(.leftMouseDragged, x: f.midX, y: f.midY))
        XCTAssertEqual(view.crop.x, 0)
    }

    func testCropWindowShowsFullPreviewAndClosesWithoutChangingProject() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".camorderstudio")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ProjectStore()
        var project = CamOrderProject.empty(name: "Crop editor check"); project.defaultCaptureSourceID = "fixture"
        project.inputCrops = ["fixture": InputCrop(x: 0.125, y: 0.15, width: 0.75, height: 0.7)]
        store.document = try ProjectDocument.create(at: folder, project: project)
        let engine = CameraCaptureEngine()
        engine.previewFrames.display(fixture())
        let inputs = LaneCaptureInputs(store: store, discovery: engine, createsEngines: false)
        store.captureInputs = inputs
        let controller = InputCropWindowController(store: store, inputs: inputs, engine: engine, sourceID: "fixture")
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        window.orderFront(nil)
        try await Task.sleep(nanoseconds: 250_000_000)
        content.layoutSubtreeIfNeeded()
        if let path = ProcessInfo.processInfo.environment["CAMORDER_CROP_PREVIEW_PATH"],
           let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) {
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        controller.close()
        XCTAssertEqual(store.project, project, "Closing or cancelling an editor never commits its draft")
    }
    private func fixture() -> CGImage {
        let context = CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 2560,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.darkGray.cgColor); context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        context.setFillColor(NSColor.systemBlue.cgColor); context.fill(CGRect(x: 80, y: 54, width: 480, height: 252))
        context.setFillColor(NSColor.systemOrange.cgColor); context.fill(CGRect(x: 100, y: 230, width: 90, height: 60))
        return context.makeImage()!
    }
}
