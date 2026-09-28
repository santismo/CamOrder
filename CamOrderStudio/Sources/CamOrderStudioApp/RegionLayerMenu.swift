import SwiftUI
import CamOrderStudioCore

func regionLayerName(_ number: Int) -> String {
    switch number {
    case 1: return "1 · Foreground"
    case 2: return "2 · Middle ground"
    case 3: return "3 · Background"
    default: return "\(number) · Behind layer \(number - 1)"
    }
}

func regionLayerColor(_ number: Int?) -> Color {
    switch number ?? 0 {
    case 1: return .cyan
    case 2: return .mint
    case 3: return .purple
    case 4...9: return .orange
    default: return .gray
    }
}

struct RegionLayerMenu: View {
    @EnvironmentObject private var store: ProjectStore
    private var label: String {
        let regions = store.selectedRegions()
        guard let first = regions.first else { return "Output Layer" }
        guard regions.allSatisfy({ $0.compositingLayer == first.compositingLayer }) else { return "Mixed Layers" }
        return first.compositingLayer.map(regionLayerName) ?? "Layer · Auto"
    }
    var body: some View {
        Menu {
            ForEach(1...9, id: \.self) { number in
                Button(regionLayerName(number)) { store.setSelectedRegionLayer(number) }
            }
            Divider()
            Button("Automatic · Lane Order (0)") { store.setSelectedRegionLayer(nil) }
        } label: {
            Label(label, systemImage: "square.3.layers.3d")
        }
        .frame(width: 158)
        .disabled(store.selectedClipIDs.isEmpty)
        .help("Assign selected regions to output layers: 1 is frontmost, 2–9 are behind. Number keys assign directly; 0 restores automatic lane order. Numbered layers appear above automatic regions; the latest assignment wins equal numbers. Yellow outlines show selection; colored borders and badges show output layers.")
    }
}
