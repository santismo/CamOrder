import Foundation
import SwiftUI
import CamOrderStudioCore

@MainActor
final class ExportRangeSelection: ObservableObject {
    enum Choice: String, CaseIterable {
        case timeline = "Edited timeline"
        case selected = "Selected region range"
        case playhead = "From playhead"
        case origin = "From project start"
        case custom = "Custom range"
    }
    @Published var choice = Choice.timeline
    @Published var startText: String
    @Published var endText: String
    let timeline: MovieExportRange?
    let selected: MovieExportRange?
    let playhead: Double

    init(project: CamOrderProject, selectedClip: VideoClip?, playhead: Double) {
        timeline = RenderExportEngine.editedRange(in: project)
        selected = selectedClip.flatMap { clip in
            let presented = project.presentedClip(clip)
            return MovieExportRange(startSeconds: presented.timelineStartSeconds, endSeconds: presented.timelineStartSeconds + presented.durationSeconds)
        }
        self.playhead = playhead
        startText = String(format: "%.6f", timeline?.startSeconds ?? 0)
        endText = String(format: "%.6f", timeline?.endSeconds ?? 0)
    }
    var range: MovieExportRange? {
        switch choice {
        case .timeline: return timeline
        case .selected: return selected
        case .playhead: return MovieExportRange(startSeconds: playhead, endSeconds: timeline?.endSeconds ?? 0)
        case .origin: return MovieExportRange(startSeconds: 0, endSeconds: timeline?.endSeconds ?? 0)
        case .custom:
            guard let start = Double(startText), let end = Double(endText) else { return nil }
            return MovieExportRange(startSeconds: start, endSeconds: end)
        }
    }
}

struct ExportRangeAccessory: View {
    @ObservedObject var selection: ExportRangeSelection
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Range", selection: $selection.choice) {
                ForEach(ExportRangeSelection.Choice.allCases, id: \.self) { choice in
                    Text(choice.rawValue).tag(choice).disabled(choice == .selected && selection.selected == nil)
                }
            }
            if selection.choice == .custom {
                HStack {
                    Text("Start (s)"); TextField("0", text: $selection.startText)
                    Text("End (s)"); TextField("0", text: $selection.endText)
                }.textFieldStyle(.roundedBorder)
            } else if let range = selection.range {
                Text(String(format: "%.6f → %.6f s  ·  %.3f s movie", range.startSeconds, range.endSeconds, range.durationSeconds))
                    .font(.caption.monospacedDigit())
            }
            Text("Uses the edited regions and video sync offsets. All visible lanes are composited as shown on Main Stage.")
                .font(.caption).foregroundStyle(.secondary)
            if selection.range == nil { Text("Choose an end time after the start.").font(.caption).foregroundStyle(.red) }
        }.padding(12).frame(width: 430).preferredColorScheme(.dark)
    }
}
