import SwiftUI

@main
struct CCalApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("CCal", id: "main") {
            ContentView()
                .environment(model)
                .environment(\.fontScale, model.fontScale)
                .frame(minWidth: 860, minHeight: 560)
        }
        .defaultSize(width: 1280, height: 820)
        .commands { CalendarCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
                .environment(\.fontScale, model.fontScale)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct CalendarCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Event") { model.newEventAtNextSlot() }
                .keyboardShortcut("n")
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Search Events…") { model.openSearch() }
                .keyboardShortcut("k")
            // Plain Delete (handled in KeyboardShortcuts) so ⌘⌫ keeps working in text fields.
            Button("Delete Event") { model.deleteEditing() }
                .disabled(!model.canDeleteEditing)
        }
        CommandGroup(before: .toolbar) {
            ForEach(Array(ViewMode.allCases.enumerated()), id: \.element) { index, mode in
                Button(mode.title) { model.mode = mode }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
            Divider()
            // ⌘= (no shift) is also handled in KeyboardShortcuts.
            Button("Bigger Text") { model.adjustFontScale(by: 0.1) }
                .keyboardShortcut("+")
            Button("Smaller Text") { model.adjustFontScale(by: -0.1) }
                .keyboardShortcut("-")
            Button("Actual Size") { model.fontScale = 1 }
                .keyboardShortcut("0")
            Divider()
        }
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { model.showingShortcuts = true }
                .keyboardShortcut("/", modifiers: .command)
        }
        CommandMenu("Go") {
            Button("Today") { model.goToToday() }
                .keyboardShortcut("t")
            // ⌘← / ⌘→ are handled in KeyboardShortcuts so they still move the cursor in text fields.
            Button("Previous") { model.step(-1) }
            Button("Next") { model.step(1) }
            Divider()
            Button("Sync Calendars") { model.refresh() }
                .keyboardShortcut("r")
        }
    }
}
