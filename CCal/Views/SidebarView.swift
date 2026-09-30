import EventKit
import SwiftUI

struct SidebarView: View {
    var body: some View {
        ScrollView {
            CalendarListView()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
    }
}

private struct CalendarListView: View {
    @Environment(\.fontScale) private var s
    @Environment(AppModel.self) private var model

    var body: some View {
        let groups = Dictionary(grouping: model.sidebarCalendars) { $0.source?.sourceIdentifier ?? "" }
        let sourceIDs = groups.keys.sorted {
            (groups[$0]?.first?.source?.title ?? "") < (groups[$1]?.first?.source?.title ?? "")
        }

        let selectedID = model.newEventCalendar?.calendarIdentifier
        VStack(alignment: .leading, spacing: 16) {
            ForEach(sourceIDs, id: \.self) { sourceID in
                let calendars = groups[sourceID] ?? []
                VStack(alignment: .leading, spacing: 5) {
                    Text(calendars.first?.source?.title ?? "Other")
                        .font(.system(size: 11 * s, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    ForEach(calendars, id: \.calendarIdentifier) { calendar in
                        CalendarRow(calendar: calendar, isOn: model.isVisible(calendar),
                                    isSelected: calendar.calendarIdentifier == selectedID) {
                            if NSEvent.modifierFlags.contains(.command) {
                                model.solo(calendar)
                            } else {
                                model.toggle(calendar)
                            }
                        } select: {
                            if NSEvent.modifierFlags.contains(.command) {
                                model.solo(calendar)
                            } else {
                                model.select(calendar)
                            }
                        }
                        .contextMenu {
                            Button("Hide from Sidebar") { model.setInSidebar(calendar, false) }
                            SettingsLink { Text("Manage Calendars…") }
                        }
                    }
                }
            }
        }
    }
}

/// Checkbox shows/hides the calendar; the name selects it as the calendar for new events.
private struct CalendarRow: View {
    @Environment(\.fontScale) private var s
    let calendar: EKCalendar
    let isOn: Bool
    let isSelected: Bool
    let toggle: () -> Void
    let select: () -> Void

    var body: some View {
        let color = Color(cgColor: calendar.cgColor)
        HStack(spacing: 8) {
            Button(action: toggle) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3).fill(isOn ? color : Color.clear)
                    RoundedRectangle(cornerRadius: 3).strokeBorder(color, lineWidth: 1.5)
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8 * s, weight: .heavy))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 13 * s, height: 13 * s)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isOn ? "Hide events" : "Show events")

            Text(calendar.title)
                .font(.system(size: 13 * s, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: select)
                .help(calendar.allowsContentModifications ? "New events go to \(calendar.title)" : "Read-only calendar")
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 5)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.2))
            }
        }
        .padding(.horizontal, -5)
    }
}
