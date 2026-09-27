import AppKit
import SwiftUI

/// Commit a lane name on Return or an outside click, and relinquish keyboard focus.
struct LaneNameEditor: NSViewRepresentable {
    let name: String
    let commit: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: name)
        field.isBordered = false; field.drawsBackground = false
        field.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .labelColor; field.focusRingType = .none
        field.placeholderString = "Lane name"
        field.setAccessibilityLabel("Lane name")
        field.delegate = context.coordinator
        context.coordinator.field = field
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak field] event in
            guard let field, let window = field.window, event.window === window, field.currentEditor() != nil else { return event }
            let point = field.convert(event.locationInWindow, from: nil)
            if !field.bounds.contains(point) { window.makeFirstResponder(nil) }
            return event
        }
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.original = name; context.coordinator.commit = commit
        if field.currentEditor() == nil { field.stringValue = name }
    }
    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        if field.currentEditor() != nil { field.window?.makeFirstResponder(nil) }
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor); coordinator.monitor = nil }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        weak var field: NSTextField?
        var original = ""
        var commit: ((String) -> Void)?
        var monitor: Any?
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field else { return }
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            field.stringValue = value.isEmpty ? original : value
            commit?(field.stringValue)
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                field?.window?.makeFirstResponder(nil); return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                field?.stringValue = original
                textView.string = original
                field?.window?.makeFirstResponder(nil); return true
            }
            return false
        }
    }
}
