import SwiftUI

@main
struct CamOrderStudioApp: App {
    @StateObject private var projectStore = ProjectStore()

    var body: some Scene {
        WindowGroup {
            StudioShellView()
                .environmentObject(projectStore)
                .frame(minWidth: 1120, minHeight: 720)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") {
                    projectStore.createProject()
                }
                .keyboardShortcut("n")

                Button("Open Project...") {
                    projectStore.openProject()
                }
                .keyboardShortcut("o")
            }

            CommandGroup(after: .saveItem) {
                Button("Save Project") {
                    projectStore.saveProject()
                }
                .keyboardShortcut("s")
                .disabled(projectStore.document == nil)

                Button("Save Project As...") {
                    projectStore.saveProjectAs()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(projectStore.document == nil)
            }

            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    projectStore.undoProjectChange()
                }
                .keyboardShortcut("z")
                .disabled(!projectStore.canUndo)

                Button("Redo") {
                    projectStore.redoProjectChange()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!projectStore.canRedo)
            }
        }
    }
}
