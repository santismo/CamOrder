import AppKit
import SwiftUI
import CamOrderStudioCore

@MainActor
func runSyncCalculatorRegression() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CamOrder-calculator-" + UUID().uuidString + ".camorderstudio")
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = ProjectStore()
    store.document = try ProjectDocument.create(at: folder, project: .empty(name: "Sync calculator"))
    store.setVideoOffsetMS(-82)
    store.setVideoOffsetMS(20, laneID: "lane_1")
    let model = store.syncCalculator
    require(model.format == .decimalSeconds, "Milliseconds are the default")
    model.logicText = "01:00:36.240"; model.videoText = "01:00:36.160"
    model.calculate(in: store)
    require(abs(model.result!.milliseconds + 80) < 0.00001 && abs(model.proposedOffset! + 162) < 0.00001)
    model.apply(in: store)
    require(abs(store.project.sync.videoOffsetMS! + 162) < 0.00001 && store.project.timeline.lanes[0].videoOffsetMS == 20)
    model.apply(in: store); model.calculate(in: store); model.apply(in: store)
    require(abs(store.project.sync.videoOffsetMS! + 162) < 0.00001, "The same result cannot be applied twice")
    store.undoProjectChange()
    require(store.project.sync.videoOffsetMS == -82, "Calculator Apply is one undo step")
    model.newMeasurement(); model.laneID = "lane_1"
    model.logicText = "00:36.240"; model.videoText = "00:36.160"; model.calculate(in: store)
    require(abs(model.proposedOffset! + 60) < 0.00001)
    model.apply(in: store)
    require(store.project.sync.videoOffsetMS == -82 && abs(store.project.timeline.lanes[0].videoOffsetMS! + 60) < 0.00001)
    let reopened = try ProjectDocument.open(at: folder)
    require(reopened.project.sync.videoOffsetMS == -82 && abs(reopened.project.timeline.lanes[0].videoOffsetMS! + 60) < 0.00001)
    model.newMeasurement(); model.laneID = ""
    model.logicText = "00:36.240"; model.videoText = "00:36.160"; model.calculate(in: store)
    store.setVideoOffsetMS(7, laneID: "lane_2")
    require(model.isStale(in: store) && !model.canApply(in: store), "Changed offsets invalidate the old measurement")
    model.apply(in: store); require(store.project.sync.videoOffsetMS == -82)
    model.calculate(in: store)
    store.armLane("lane_1")
    require(!model.canApply(in: store), "Do not change capture placement while armed")
    store.unarmAllLanes()
    require(model.canApply(in: store))
    model.videoText = "00:10.000"; model.calculate(in: store)
    require(!model.canApply(in: store), "Large/mismatched clock readings cannot silently clamp to the offset limit")
    model.newMeasurement(); model.logicText = "00:36.240"; model.videoText = "00:36.160"; model.calculate(in: store)

    // Render the production calculator; destroy/recreate its view to simulate a
    // dismissed Sync popover while the same AU session remains alive.
    func makeView() -> NSView {
        NSHostingView(rootView: ScrollView { SyncCalculatorView(model: model).padding(20) }
            .frame(width: 440, height: 790).environmentObject(store).preferredColorScheme(.dark))
    }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 790), styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "CamOrder · Sync calculator"
    window.contentView = makeView(); window.center(); window.makeKeyAndOrderFront(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    window.contentView = nil; window.contentView = makeView()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    require(model.logicText == "00:36.240" && model.videoText == "00:36.160" && model.result != nil,
        "Switching to Logic and reopening Sync preserves both entries and the result")
    if CommandLine.arguments.count > 1,
       let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) {
        let output = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("sync-calculator.png")
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: output)
    }
    window.orderOut(nil)
    print("PASS: calculator signs, existing-offset refinement, lane isolation, save/reopen and Undo; repeated/stale/out-of-range Apply protection; editor recreation retains inputs")
}
