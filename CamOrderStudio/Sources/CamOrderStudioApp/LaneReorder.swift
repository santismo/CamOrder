import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let laneDragType = UTType(exportedAs: "com.santismo.camorder-studio.lane")

struct LaneReorderGrip: View {
    let laneID: String
    let number: Int
    let projectPath: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "line.3.horizontal")
            Text("\(number)").monospacedDigit()
        }
        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
        .padding(.vertical, 3).contentShape(Rectangle())
        .help("Drag to reorder this lane. During playback, keys 1–9 switch to the numbered lanes.")
        .onDrag {
            let payload = try? JSONEncoder().encode(LaneDrag(laneID: laneID, projectPath: projectPath))
            return NSItemProvider(item: (payload ?? Data()) as NSData, typeIdentifier: laneDragType.identifier)
        }
    }
}

private struct LaneDrag: Codable { let laneID: String; let projectPath: String }

struct LaneReorderTarget: ViewModifier {
    let store: ProjectStore
    let laneID: String
    @State private var insertAfter: Bool?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: insertAfter == true ? .bottom : .top) {
                if insertAfter != nil { Rectangle().fill(Color.accentColor).frame(height: 2).allowsHitTesting(false) }
            }
            .onDrop(of: [laneDragType], delegate: LaneDrop(store: store, laneID: laneID, insertAfter: $insertAfter))
    }
}

private struct LaneDrop: DropDelegate {
    let store: ProjectStore
    let laneID: String
    @Binding var insertAfter: Bool?

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [laneDragType]) }
    func dropEntered(info: DropInfo) { insertAfter = info.location.y >= 28 }
    func dropExited(info: DropInfo) { insertAfter = nil }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        insertAfter = info.location.y >= 28
        return DropProposal(operation: .move)
    }
    func performDrop(info: DropInfo) -> Bool {
        let after = info.location.y >= 28
        insertAfter = nil
        guard let provider = info.itemProviders(for: [laneDragType]).first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: laneDragType.identifier) { data, _ in
            guard let data, let payload = try? JSONDecoder().decode(LaneDrag.self, from: data) else { return }
            Task { @MainActor in
                guard store.document?.folderURL.path == payload.projectPath else { return }
                store.moveLane(payload.laneID, relativeTo: laneID, after: after)
            }
        }
        return true
    }
}
