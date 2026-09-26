import SwiftUI
import CamOrderStudioCore

struct LaneSourcePicker: View {
    @EnvironmentObject private var store: ProjectStore
    @ObservedObject var inputs: LaneCaptureInputs
    @ObservedObject var discovery: CameraCaptureEngine
    let lane: VideoLane
    var body: some View {
        Picker("Input for " + lane.name, selection: Binding<String>(
            get: { lane.captureSourceID ?? "__default__" },
            set: { id in store.setLaneCaptureSource(lane.id, sourceID: id == "__default__" ? nil : id, name: discovery.availableDevices.first { $0.id == id }?.displayName) })) {
            Text("Default · " + (inputs.defaultSourceID.map(inputs.name) ?? "Choose input")).tag("__default__")
            Text("No input").tag("")
            ForEach(discovery.availableDevices) { device in Text(device.displayName).tag(device.id) }
            if let id = lane.captureSourceID, !id.isEmpty, !discovery.availableDevices.contains(where: { $0.id == id }) {
                Text((lane.captureSourceName ?? id) + " · unavailable").tag(id)
            }
        }.labelsHidden().controlSize(.mini)
            .disabled(lane.isArmed || store.laneIsBusy(lane.id))
            .help("Use the shared default input, or choose another camera for this lane")
    }
}

struct MultiInputPreviewPane: View {
    @EnvironmentObject private var store: ProjectStore
    @ObservedObject var inputs: LaneCaptureInputs
    @ObservedObject var discovery: CameraCaptureEngine
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Live Inputs").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Button { discovery.refreshDevices(); inputs.engines.values.forEach { $0.refreshDevices() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Refresh connected cameras")
            }.padding(.horizontal, 10).frame(height: 27)
            HStack(spacing: 5) {
                Text("Default").font(.caption).foregroundStyle(.secondary)
                Picker("Default input", selection: Binding<String>(get: { store.project.defaultCaptureSourceID ?? "__auto__" }, set: {
                    store.setDefaultCaptureSource($0 == "__auto__" ? nil : $0)
                })) {
                    Text("Automatic camera").tag("__auto__")
                    Text("No default input").tag("")
                    ForEach(discovery.availableDevices) { device in Text(device.displayName).tag(device.id) }
                    if let id = store.project.defaultCaptureSourceID, !id.isEmpty, !discovery.availableDevices.contains(where: { $0.id == id }) {
                        Text(id + " · unavailable").tag(id)
                    }
                }.labelsHidden().controlSize(.small)
                    .disabled(!store.hasOpenProject || store.project.timeline.lanes.contains { $0.captureSourceID == nil && ($0.isArmed || store.laneIsBusy($0.id)) })
            }.padding(.horizontal, 10).padding(.bottom, 8)
            if inputs.sourceIDs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "video.badge.plus").font(.title)
                    Text(store.hasOpenProject ? "Choose a default input" : "Open a project to preview inputs").font(.caption)
                    Text("Every lane uses Default until you assign another camera.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
            } else if inputs.sourceIDs.count == 1, let id = inputs.sourceIDs.first {
                SourcePreviewCard(inputs: inputs, sourceID: id, compact: false)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], spacing: 8) {
                        ForEach(inputs.sourceIDs, id: \.self) { id in
                            SourcePreviewCard(inputs: inputs, sourceID: id, compact: true)
                        }
                    }.padding(4)
                }
            }
        }
    }
}

private struct SourcePreviewCard: View {
    @EnvironmentObject private var store: ProjectStore
    @ObservedObject var inputs: LaneCaptureInputs
    let sourceID: String
    let compact: Bool
    private var lanes: [VideoLane] { inputs.lanes(for: sourceID) }
    private var busy: Bool { lanes.contains { $0.isArmed || store.laneIsBusy($0.id) } }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(inputs.name(for: sourceID)).font(.caption.weight(.medium)).lineLimit(1)
                    Text(lanes.map(\.name).joined(separator: " · ")).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 2)
                Menu {
                    Button("Start / restart preview") { inputs.engines[sourceID]?.startPreview() }.disabled(busy)
                    Button("Stop preview") { inputs.engines[sourceID]?.stopPreview() }.disabled(busy)
                    if sourceID == "screen:region" {
                        Divider()
                        Button("Show capture region") { inputs.region(for: sourceID).show() }.disabled(busy)
                        Button("Apply capture region") { inputs.applyRegion(for: sourceID) }.disabled(busy)
                        Button("Hide capture region") { inputs.region(for: sourceID).hide() }
                    }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
            }.padding(.horizontal, 8).padding(.vertical, 5)
            if compact {
                preview.aspectRatio(16.0 / 9.0, contentMode: .fit)
            } else {
                preview.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(Color.white.opacity(0.03))
    }
    @ViewBuilder private var preview: some View {
        if let engine = inputs.engines[sourceID] {
            ActiveSourcePreview(engine: engine, recording: lanes.contains { store.pendingTakes[$0.id] != nil && store.captureEndSeconds[$0.id] == nil }, buffering: lanes.contains { store.armedBuffers[$0.id] != nil })
        } else {
            ZStack { Color.black; Text("Input preview").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

private struct ActiveSourcePreview: View {
    @ObservedObject var engine: CameraCaptureEngine
    let recording: Bool
    let buffering: Bool
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CapturePreviewPane(cameraEngine: engine).background(.black)
            VStack(alignment: .leading, spacing: 5) {
                if let error = engine.lastErrorMessage { Text(error).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(3) }
                HStack(spacing: 5) {
                    Circle().fill(recording ? .red : (engine.isPreviewing ? .green : .secondary)).frame(width: 6, height: 6)
                    Text(recording ? "Recording" : (engine.isFinishingRecording ? "Saving…" : (buffering ? "Armed" : (engine.isPreviewing ? "Live" : "Preview idle")))).font(.system(size: 10))
                }
            }.padding(6).background(.black.opacity(0.65)).padding(5)
        }
    }
}
