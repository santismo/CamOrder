import AppKit
import CamOrderStudioCore
import Combine
import SwiftUI

/// Owned by the project session, not the editor window or toolbar position.
@MainActor
final class ProjectExportController: ObservableObject {
    @Published private(set) var isRendering = false
    @Published private(set) var progress = 0.0
    @Published private(set) var lastExportURL: URL?
    @Published private(set) var finished = false
    @Published var errorMessage: String?
    private let engine = RenderExportEngine()

    init() { engine.$progress.assign(to: &$progress) }

    func start(project: CamOrderProject, folderURL: URL, destinationURL: URL, range: MovieExportRange) {
        guard !isRendering else { return }
        isRendering = true
        progress = 0
        finished = false
        errorMessage = nil
        Task {
            defer { isRendering = false }
            do {
                try await engine.export(project: project, from: folderURL, to: destinationURL, range: range)
                lastExportURL = destinationURL
                finished = true
                do {
                    try Self.placementNotes(destinationURL: destinationURL, start: range.startSeconds)
                        .write(to: destinationURL.deletingPathExtension().appendingPathExtension("logic-placement.txt"), atomically: true, encoding: .utf8)
                } catch {
                    errorMessage = "The movie exported, but its placement note could not be saved. Movie start: \(String(format: "%.6f", range.startSeconds)) seconds. \(error.localizedDescription)"
                }
            } catch {
                let detail = error as NSError
                errorMessage = "\(error.localizedDescription) (\(detail.domain) \(detail.code))"
            }
        }
    }

    static func placementNotes(destinationURL: URL, start: Double) -> String {
        """
        CamOrder Studio — Logic movie placement
        Movie: \(destinationURL.lastPathComponent)
        Edited timeline start: \(String(format: "%.6f", start)) seconds from the Logic project timeline origin.

        1. In Logic Pro, choose File > Movie > Open Movie and select this export.
        2. Move Logic's playhead to the start you want (the edited timeline start above to preserve placement).
        3. In Logic's Key Commands, find and use “Move Movie Region to Playhead”.
           Alternatively set Movie Start in File > Project Settings > Movie; add your project's SMPTE origin offset to the seconds above.

        This export is a rendered movie. CamOrder does not insert or move Logic's movie track automatically.
        The Audio Unit passes audio through; it does not record Logic's mix into the movie.
        Import a bounced mix under Master Audio / Export if you want audio in the export.
        """
    }
}

struct ExportControls: View {
    @ObservedObject var controller: ProjectExportController
    let disabled: Bool
    let export: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if controller.isRendering {
                VStack(spacing: 2) {
                    Text("Export \(Int(controller.progress * 100))%")
                        .font(.caption2.monospacedDigit())
                    ProgressView(value: controller.progress).frame(width: 72)
                }.accessibilityLabel("Export \(Int(controller.progress * 100)) percent complete")
            } else if controller.finished {
                Label("Export finished", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.tint).lineLimit(1)
                    .help(controller.lastExportURL?.lastPathComponent ?? "Export finished")
            }
            Button(action: export) { Label("Export", systemImage: "square.and.arrow.up") }
                .buttonStyle(.borderedProminent).disabled(disabled || controller.isRendering)
            if let url = controller.lastExportURL {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    Image(systemName: "folder")
                }
                .help("Show exported movie in Finder: \(url.lastPathComponent)")
                .accessibilityLabel("Show exported movie in Finder")
            }
        }
        .alert("CamOrder export", isPresented: Binding(get: { controller.errorMessage != nil }, set: { if !$0 { controller.errorMessage = nil } })) {
            Button("OK", role: .cancel) { controller.errorMessage = nil }
        } message: { Text(controller.errorMessage ?? "") }
    }
}
