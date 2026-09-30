import EventKit
import SwiftUI

/// ⌘, — choose which calendars appear in the sidebar.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let groups = Dictionary(grouping: model.calendars) { $0.source?.sourceIdentifier ?? "" }
        let sourceIDs = groups.keys.sorted {
            (groups[$0]?.first?.source?.title ?? "") < (groups[$1]?.first?.source?.title ?? "")
        }

        Form {
            Text("Calendars hidden here are removed from the sidebar and their events aren't shown.")
                .foregroundStyle(.secondary)
            ForEach(sourceIDs, id: \.self) { sourceID in
                let calendars = groups[sourceID] ?? []
                Section(calendars.first?.source?.title ?? "Other") {
                    ForEach(calendars, id: \.calendarIdentifier) { calendar in
                        Toggle(isOn: Binding(get: { model.isInSidebar(calendar) },
                                             set: { model.setInSidebar(calendar, $0) })) {
                            Label {
                                Text(calendar.title)
                            } icon: {
                                Image(systemName: "circle.fill").foregroundStyle(Color(cgColor: calendar.cgColor))
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 560)
        .navigationTitle("Calendars")
    }
}

struct ShortcutsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private let groups: [(title: String, items: [(keys: String, action: String)])] = [
        ("Navigate", [
            ("T", "Go to today"),
            ("⌘← ⌘→  or  K J", "Previous / next"),
            ("D  W  M", "Day / week / month"),
            ("⌘R", "Sync calendars"),
            ("⌘K", "Search events"),
        ]),
        ("Events", [
            ("N", "New event"),
            ("Drag on grid", "New event for that time"),
            ("Double-click", "New event"),
            ("Return", "Edit title of selected event"),
            ("Esc", "Discard changes and close"),
            ("Delete", "Delete selected event"),
        ]),
        ("View", [
            ("⌘+  ⌘-  ⌘0", "Bigger / smaller / actual text size"),
            ("⌘-click calendar", "Show only that calendar (again for all)"),
            ("⌘,", "Show or hide calendars"),
            ("?", "This list"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Keyboard Shortcuts").font(.title2.weight(.semibold))
            ForEach(groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.title).font(.headline).foregroundStyle(.secondary)
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                        ForEach(group.items, id: \.keys) { item in
                            GridRow {
                                Text(item.keys)
                                    .font(.system(.body, design: .rounded).weight(.medium))
                                    .frame(width: 130, alignment: .leading)
                                Text(item.action)
                            }
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onExitCommand { dismiss() }
    }
}
