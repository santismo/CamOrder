import AppKit
import SwiftUI
import CamOrderStudioCore

/// Owned by the document store, so clicking back into Logic does not lose input.
@MainActor
final class SyncCalculatorModel: ObservableObject {
    @Published var showingCalculator = false
    @Published var logicText = "" { didSet { invalidate() } }
    @Published var videoText = "" { didSet { invalidate() } }
    @Published var format: SyncClockFormat? = .decimalSeconds { didSet { invalidate() } }
    @Published var rate: SyncClockRate? { didSet { invalidate() } }
    @Published var sampleRateText = "" { didSet { invalidate() } }
    @Published var laneID = "" { didSet { invalidate() } }
    @Published private(set) var result: SyncCorrection?
    @Published private(set) var error: String?
    @Published private(set) var applied = false
    private(set) var previousOffset = 0.0
    private var projectAtCalculation: CamOrderProject?
    private var folderAtCalculation: URL?

    var proposedOffset: Double? { result?.resultingOffset(from: previousOffset) }
    private func invalidate() { result = nil; error = nil; applied = false }
    private func snapshot(_ project: CamOrderProject) -> CamOrderProject {
        var value = project
        for index in value.timeline.lanes.indices { value.timeline.lanes[index].isArmed = false }
        return value
    }
    func calculate(in store: ProjectStore) {
        guard !applied else { return }
        result = nil; error = nil
        guard let format else { error = "Choose the format used by both clocks."; return }
        guard laneID.isEmpty || store.project.timeline.lanes.contains(where: { $0.id == laneID }) else {
            error = "Choose an existing lane or Whole project."; return
        }
        do {
            let value = try SyncCalculator.compare(logic: logicText, video: videoText, format: format,
                rate: rate, sampleRate: Double(sampleRateText))
            previousOffset = laneID.isEmpty ? (store.project.sync.videoOffsetMS ?? 0)
                : (store.project.timeline.lanes.first { $0.id == laneID }?.videoOffsetMS ?? 0)
            projectAtCalculation = snapshot(store.project)
            folderAtCalculation = store.document?.folderURL
            result = value
        } catch { self.error = error.localizedDescription }
    }
    func isStale(in store: ProjectStore) -> Bool {
        result != nil && (projectAtCalculation != snapshot(store.project) || folderAtCalculation != store.document?.folderURL)
    }
    func canApply(in store: ProjectStore) -> Bool {
        guard let proposedOffset, store.document != nil, !applied, !isStale(in: store),
              !store.hasCaptureActivity, !store.hasArmedLane else { return false }
        return proposedOffset.isFinite && (-5000...5000).contains(proposedOffset) && abs(result?.milliseconds ?? 0) > 0.0001
    }
    func apply(in store: ProjectStore) {
        guard canApply(in: store), let proposedOffset else { return }
        store.setVideoOffsetMS(proposedOffset, laneID: laneID.isEmpty ? nil : laneID)
        applied = true
    }
    func newMeasurement() { logicText = ""; videoText = ""; invalidate() }
}

struct SyncCalculatorView: View {
    @EnvironmentObject private var store: ProjectStore
    @ObservedObject var model: SyncCalculatorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Measure video sync").font(.headline)
            Text("Place a fresh export at its original start in Logic, then pause with both clocks visible. Enter Logic’s time and the clock recorded inside the video at that same moment.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Clock format", selection: $model.format) {
                Text("Choose Logic’s display format").tag(Optional<SyncClockFormat>.none)
                ForEach(SyncClockFormat.allCases) { Text($0.name).tag(Optional($0)) }
            }
            if let format = model.format {
                if format.usesFrames {
                    Picker("Logic frame rate", selection: $model.rate) {
                        Text("Choose fps").tag(Optional<SyncClockRate>.none)
                        ForEach(SyncClockRate.allCases) { Text("\($0.rawValue) fps").tag(Optional($0)) }
                    }
                }
                if format.usesSamples {
                    HStack {
                        Text("Logic sample rate")
                        TextField("e.g. 48000", text: $model.sampleRateText).frame(width: 100)
                        Text("Hz").foregroundStyle(.secondary)
                    }
                }
                Text(formatHelp(format)).font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Actual Logic time").font(.caption.weight(.semibold))
                TextField(model.format?.example ?? "Choose a format above", text: $model.logicText)
                    .accessibilityIdentifier("sync-logic-time")
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Clock visible inside the video").font(.caption.weight(.semibold))
                TextField(model.format?.example ?? "Same paused moment", text: $model.videoText)
                    .accessibilityIdentifier("sync-video-time")
            }
            Picker("Adjust", selection: $model.laneID) {
                Text("Whole project").tag("")
                ForEach(store.project.timeline.lanes) { Text($0.name).tag($0.id) }
            }
            Text("Use a fresh export made with your current offsets. This adds the measured correction to the chosen setting; other lane settings stay as they are.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Calculate") { model.calculate(in: store) }
                    .disabled(model.applied).accessibilityIdentifier("sync-calculate")
                Spacer()
                Button("New measurement") { model.newMeasurement() }.buttonStyle(.link)
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange) }
            if let result = model.result { resultView(result).id("sync-calculator-result") }
            Link("Logic display formats", destination: URL(string: "https://support.apple.com/guide/logicpro/customize-the-control-bar-lgcp5bdd6d9d/mac")!)
                .font(.caption)
        }
        .textFieldStyle(.roundedBorder)
        .onSubmit { model.calculate(in: store) }
    }

    @ViewBuilder
    private func resultView(_ result: SyncCorrection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(direction(result.milliseconds)).font(.headline)
            Text(String(format: "Correction: %+.3f ms", result.milliseconds))
                .font(.title3.monospacedDigit()).textSelection(.enabled)
            if let rate = model.rate, model.format?.usesFrames == true {
                Text(String(format: "%+.3f frames at %@ fps", result.milliseconds * rate.fps / 1000, rate.rawValue))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(String(format: "Offset: %+.3f → %+.3f ms", model.previousOffset, model.proposedOffset ?? 0))
                .font(.body.monospacedDigit()).textSelection(.enabled)
            DisclosureGroup("How the clocks were read") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Logic: \(result.logic.interpretation)")
                    Text("Video: \(result.video.interpretation)")
                }.font(.caption).textSelection(.enabled)
            }
            if model.applied {
                Label("Applied. Re-export and compare again.", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.teal)
            } else if model.isStale(in: store) {
                Text("The project changed after this calculation. Use a fresh export and calculate again.")
                    .font(.caption).foregroundStyle(.orange)
            } else if abs(model.proposedOffset ?? 0) > 5000 {
                Text("This exceeds the ±5000 ms offset range. Check both clock formats, frame rates and SMPTE view offsets.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Apply offset") { model.apply(in: store) }
                    .disabled(!model.canApply(in: store)).accessibilityIdentifier("sync-apply")
                Button("Copy correction") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(String(format: "%+.3f ms", result.milliseconds), forType: .string)
                }.buttonStyle(.link)
            }
            Text("Original video stays intact. The correction changes Main Stage and your next export. Reimport at the same Logic position.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(12).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
    private func direction(_ ms: Double) -> String {
        abs(ms) < 0.0001 ? "These readings match" : (ms < 0 ? "Move video earlier" : "Move video later")
    }
    private func formatHelp(_ format: SyncClockFormat) -> String {
        switch format {
        case .frames: return "Hours:minutes:seconds:frames. Hours may be omitted. Match Logic’s timecode fps, not the movie’s fps."
        case .framesAndBits: return "Hours:minutes:seconds:frames.bits. Bits are 0–79 per frame. Hours may be omitted."
        case .decimalSeconds: return "Minutes:seconds.fraction, or hours:minutes:seconds.fraction. Every digit after the point is a decimal fraction of one second."
        case .secondsAndSamples: return "Minutes:seconds.samples, with optional hours. The final number is samples within one second, not decimal seconds."
        case .framesAndSamples: return "Hours:minutes:seconds:frames.samples. Separate the frames and samples; hours may be omitted."
        case .framesAndMilliseconds: return "Hours:minutes:seconds:frames.milliseconds. The last number is milliseconds within one frame; hours may be omitted."
        }
    }
}
