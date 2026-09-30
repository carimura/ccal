import AppKit

/// Single-key shortcuts (t, d/w/m, j/k, arrows, n, delete, esc) that only fire
/// when you're not typing in a text field.
@MainActor
enum KeyboardShortcuts {
    static func install(model: AppModel) -> [Any] {
        [
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                handle(event, model: model) ? nil : event
            },
            NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                endEditingIfClickedOutside(event)
                return event
            },
        ].compactMap { $0 }
    }

    static func remove(_ monitors: [Any]) {
        monitors.forEach(NSEvent.removeMonitor)
    }

    /// Clicking anywhere outside the text field being edited ends editing (like a browser), so the
    /// single-key and ⌘-arrow shortcuts work again. Clicking into another field still focuses it.
    private static func endEditingIfClickedOutside(_ event: NSEvent) {
        guard let window = event.window, let editor = window.firstResponder as? NSTextView else { return }
        // A TextField edits through the window's shared field editor, whose delegate is the field itself.
        let focused: NSView = editor.isFieldEditor ? (editor.delegate as? NSView ?? editor) : (editor.enclosingScrollView ?? editor)
        let root = window.contentView?.superview ?? window.contentView
        if let hit = root?.hitTest(event.locationInWindow), hit.isDescendant(of: focused) { return }
        window.makeFirstResponder(nil)
    }

    private static func handle(_ event: NSEvent, model: AppModel) -> Bool {
        // ⌘= means "bigger" too; the menu's ⌘+ only matches when shift is held.
        if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           event.charactersIgnoringModifiers == "=" {
            model.adjustFontScale(by: 0.1)
            return true
        }
        // ⌘← / ⌘→ navigate, except while typing (where they move the cursor).
        if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           [123, 124].contains(event.keyCode),
           !(event.window?.firstResponder is NSText), event.window?.attachedSheet == nil {
            model.step(event.keyCode == 123 ? -1 : 1)
            return true
        }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let window = event.window, window.attachedSheet == nil,
              model.spanPrompt == nil,
              !(window.firstResponder is NSText)
        else { return false }

        switch event.keyCode {
        case 53: // esc: close the editor first (back to search results), then search
            if model.editing != nil {
                model.cancelEditing()
            } else if model.isSearching {
                model.closeSearch()
            } else {
                return false
            }
            return true
        case 51, 117: // delete, forward delete
            guard model.canDeleteEditing else { return false }
            model.deleteEditing()
            return true
        case 36: // return: jump into the title field
            guard model.editing?.isEditable == true else { return false }
            model.requestTitleFocus()
            return true
        default: break
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "t": model.goToToday()
        case "d": model.mode = .day
        case "w": model.mode = .week
        case "m": model.mode = .month
        case "j": model.step(1)
        case "k": model.step(-1)
        case "n": model.newEventAtNextSlot()
        case "?": model.showingShortcuts = true
        default: return false
        }
        return true
    }
}
