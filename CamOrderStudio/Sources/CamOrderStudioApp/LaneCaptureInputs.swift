import AppKit
import CamOrderStudioCore
import Combine

/// One physical capture connection per distinct source, shared by any lanes that
/// use it. Lane assignment and arming remain independent of preview visibility.
@MainActor
final class LaneCaptureInputs: ObservableObject {
    let discovery: CameraCaptureEngine
    private unowned let store: ProjectStore
    private let createsEngines: Bool
    private let defaultOverride: String?
    @Published private(set) var engines: [String: CameraCaptureEngine] = [:]
    @Published private(set) var sourceIDs: [String] = []
    private var crops: [String: [Double]] = [:]
    private var regions: [String: CaptureRegionController] = [:]

    init(store: ProjectStore, discovery: CameraCaptureEngine, createsEngines: Bool = true, defaultOverride: String? = nil) {
        self.store = store; self.discovery = discovery
        self.createsEngines = createsEngines; self.defaultOverride = defaultOverride
    }
    var defaultSourceID: String? {
        let id = store.project.defaultCaptureSourceID ?? defaultOverride ?? discovery.availableDevices.first(where: { $0.kind == .camera })?.id
        return id?.isEmpty == false ? id : nil
    }
    func sourceID(for lane: VideoLane) -> String? {
        let id = lane.captureSourceID ?? defaultSourceID
        return id?.isEmpty == false ? id : nil
    }
    func lanes(for sourceID: String) -> [VideoLane] {
        store.project.timeline.lanes.filter { self.sourceID(for: $0) == sourceID }
    }
    func name(for id: String) -> String {
        discovery.availableDevices.first { $0.id == id }?.displayName ??
        lanes(for: id).compactMap(\.captureSourceName).first ?? id
    }
    func reconcile() {
        // Resolve the initial default once and persist it. Device-list reordering
        // or a disconnected camera must never silently switch a recording input.
        if store.hasOpenProject, store.project.defaultCaptureSourceID == nil, let id = defaultSourceID {
            store.project.defaultCaptureSourceID = id
            store.saveProject()
        }
        let lanes = store.hasOpenProject ? store.project.timeline.lanes : []
        var ids: [String] = []
        for lane in lanes {
            if let id = sourceID(for: lane), !ids.contains(id) { ids.append(id) }
        }
        if sourceIDs != ids { sourceIDs = ids }
        for id in Array(engines.keys) where !ids.contains(id) {
            guard let engine = engines[id], !engine.isRecording, !engine.isFinishingRecording else { continue }
            engine.stopPreview(); engines[id] = nil; crops[id] = nil
            regions[id]?.hide(); regions[id] = nil
        }
        guard createsEngines else { return }
        for id in ids {
            let crop = lanes.filter { sourceID(for: $0) == id }.compactMap(\.captureCrop).first
            if engines[id] == nil {
                let engine = CameraCaptureEngine(useCaptureHelper: true, automaticallyPreviewsDefaultSource: false)
                engines[id] = engine
                if let crop, let rect = Self.rect(crop) { engine.setScreenCropRect(rect); crops[id] = crop }
                engine.selectDevice(id: id)
            } else if let engine = engines[id], !engine.isRecording, !engine.isFinishingRecording, crops[id] != crop {
                engine.setScreenCropRect(crop.flatMap(Self.rect)); crops[id] = crop
            }
        }
    }
    func region(for id: String) -> CaptureRegionController {
        if let existing = regions[id] { return existing }
        let region = CaptureRegionController()
        regions[id] = region
        return region
    }
    func applyRegion(for id: String) {
        let rect = region(for: id).captureRectForMainDisplay()
        guard !lanes(for: id).contains(where: { $0.isArmed || store.laneIsBusy($0.id) }) else { return }
        for lane in lanes(for: id) { store.setLaneCaptureCrop(lane.id, rect: rect) }
    }
    func stopAllPreviews() {
        engines.values.forEach { $0.stopPreview() }
        regions.values.forEach { $0.hide() }
        discovery.stopPreview()
    }
    private static func rect(_ crop: [Double]) -> CGRect? {
        guard crop.count == 4, crop.allSatisfy(\.isFinite), crop[2] > 0, crop[3] > 0 else { return nil }
        return CGRect(x: crop[0], y: crop[1], width: crop[2], height: crop[3])
    }
}
