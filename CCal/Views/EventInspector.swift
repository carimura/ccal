import EventKit
import SwiftUI

struct EventInspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let session = model.editing {
            if session.isEditable {
                EventEditor(session: session)
            } else {
                EventDetails(event: session.event)
            }
        }
    }
}

private struct EventEditor: View {
    @Environment(\.fontScale) private var s
    @Environment(AppModel.self) private var model
    let session: EditSession
    @FocusState private var titleFocused: Bool

    var body: some View {
        @Bindable var model = model
        let draft = model.draft
        let dateComponents: DatePickerComponents = draft.isAllDay ? .date : [.date, .hourAndMinute]

        VStack(spacing: 0) {
            // A plain Grid in cards rather than Form(.grouped): the grouped form re-measures every row
            // to pick its arrangement, which was the main cost of opening the inspector.
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Title", text: $model.draft.title, prompt: Text("New Event"))
                        .textFieldStyle(.plain)
                        .font(.system(size: 18 * s, weight: .semibold))
                        .focused($titleFocused)
                        .padding(.horizontal, 4)

                    InspectorCard {
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                            row("All-day") {
                                Toggle("All-day", isOn: Binding(get: { model.draft.isAllDay }, set: { model.setDraftAllDay($0) }))
                                    .labelsHidden()
                            }
                            row("Starts") {
                                DatePicker("Starts", selection: Binding(get: { model.draft.start }, set: { model.setDraftStart($0) }),
                                           displayedComponents: dateComponents)
                                    .labelsHidden()
                            }
                            row("Ends") {
                                DatePicker("Ends", selection: Binding(get: { model.draft.end }, set: { model.setDraftEnd($0) }),
                                           in: draft.start..., displayedComponents: dateComponents)
                                    .labelsHidden()
                            }
                            row("Repeat") {
                                Picker("Repeat", selection: $model.draft.recurrence) {
                                    ForEach(RepeatRule.allCases.filter { $0 != .custom || draft.recurrence == .custom }) {
                                        Text($0.label).tag($0)
                                    }
                                }
                                .labelsHidden()
                                .fixedSize()
                                .disabled(draft.recurrence == .custom)
                            }
                            row("Calendar") {
                                Picker("Calendar", selection: $model.draft.calendarID) {
                                    ForEach(model.writableCalendars, id: \.calendarIdentifier) { calendar in
                                        Label {
                                            Text(calendar.title)
                                        } icon: {
                                            CalendarDot.image(calendar.cgColor)
                                        }
                                        .tag(calendar.calendarIdentifier)
                                    }
                                }
                                .labelsHidden()
                                .fixedSize()
                            }
                        }
                    }

                    InspectorCard {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Location", text: $model.draft.location)
                            TextField("URL", text: $model.draft.urlString)
                            if let join = JoinLink.find(in: [draft.location, draft.urlString, draft.notes]) {
                                JoinButton(url: join)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                    }

                    InspectorCard {
                        // A TextEditor (not a TextField) so Return starts a new line instead of saving.
                        // The Text doubles as the placeholder and, invisibly, sizes the box to the notes.
                        ZStack(alignment: .topLeading) {
                            Text(model.draft.notes.isEmpty ? "Notes" : model.draft.notes + "\n")
                                .foregroundStyle(model.draft.notes.isEmpty ? Color(nsColor: .placeholderTextColor) : .clear)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                            TextEditor(text: $model.draft.notes)
                                .scrollContentBackground(.hidden)
                        }
                        .frame(minHeight: 50 * s, maxHeight: 160 * s)
                    }
                }
                .padding(12)
            }
            .font(.system(size: 13 * s))
            .onSubmit { model.commit() }
            .onExitCommand { model.cancelEditing() }

            Divider()
            HStack {
                if !session.isNew {
                    Button("Delete", role: .destructive) { model.deleteEditing() }
                }
                Spacer()
                if session.isNew || model.editing?.hasChanges == true {
                    Button("Cancel") { model.cancelEditing() }
                    Button(session.isNew ? "Add Event" : "Save") { model.commit() }
                        .buttonStyle(.borderedProminent)
                        .disabled(session.isNew && draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(12)
        }
        .onAppear {
            if session.isNew {
                titleFocused = true
            } else {
                // The popover focuses its first field by itself, which would send typing (and the
                // single-key shortcuts) into an existing event's title.
                DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
            }
        }
        .onChange(of: session.id) { if session.isNew { titleFocused = true } }
        .onChange(of: model.titleFocusRequest) { titleFocused = true }
    }
}

extension EventEditor {
    fileprivate func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize() // never wrap or squeeze; the controls get the remaining width
                .gridColumnAlignment(.trailing)
            content()
        }
    }
}

private struct InspectorCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// Read-only view for events we don't edit yet (anything with guests, or read-only calendars).
private struct EventDetails: View {
    @Environment(\.fontScale) private var s
    let event: EKEvent

    var body: some View {
        let attendees = (event.attendees ?? []).sorted { ($0.name ?? "") < ($1.name ?? "") }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(DisplayEvent.displayTitle(event.title))
                        .font(.system(size: 20 * s, weight: .semibold))
                        .textSelection(.enabled)
                    Text(timeText).foregroundStyle(.secondary)
                    if let calendar = event.calendar {
                        Label {
                            Text(calendar.title)
                        } icon: {
                            Image(systemName: "circle.fill").foregroundStyle(Color(cgColor: calendar.cgColor))
                        }
                        .font(.system(size: 12 * s))
                    }
                }

                if let join = JoinLink.find(in: [event.location, event.url?.absoluteString, event.notes]) {
                    JoinButton(url: join)
                }

                if let location = event.location, !location.isEmpty {
                    Label(location, systemImage: "mappin.and.ellipse").textSelection(.enabled)
                }
                if let url = event.url {
                    Link(destination: url) { Label(url.absoluteString, systemImage: "link").lineLimit(1) }
                }

                if !attendees.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Guests").font(.system(size: 13 * s, weight: .bold))
                        ForEach(attendees, id: \.url) { attendee in
                            AttendeeRow(attendee: attendee, isOrganizer: attendee.url == event.organizer?.url)
                        }
                    }
                }

                if let notes = event.notes, !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Notes").font(.system(size: 13 * s, weight: .bold))
                        Text(notes).textSelection(.enabled).font(.system(size: 12 * s))
                    }
                }

                Label(readOnlyReason, systemImage: "lock")
                    .font(.system(size: 10 * s))
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .font(.system(size: 13 * s))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var timeText: String {
        let cal = Calendar.current
        let start = event.startDate!, end = event.endDate!
        if event.isAllDay {
            let last = cal.startOfDay(for: max(start, end.addingTimeInterval(-1)))
            if cal.isDate(start, inSameDayAs: last) { return start.formatted(date: .complete, time: .omitted) }
            return "\(start.formatted(date: .abbreviated, time: .omitted)) – \(last.formatted(date: .abbreviated, time: .omitted))"
        }
        if cal.isDate(start, inSameDayAs: end) {
            return "\(start.formatted(date: .complete, time: .omitted))\n\(start.shortTime) – \(end.shortTime)"
        }
        return "\(start.formatted(date: .abbreviated, time: .shortened)) – \(end.formatted(date: .abbreviated, time: .shortened))"
    }

    private var readOnlyReason: String {
        if event.calendar?.allowsContentModifications == false { return "This calendar is read-only." }
        return "Events with guests are read-only for now."
    }
}

private struct AttendeeRow: View {
    @Environment(\.fontScale) private var s
    let attendee: EKParticipant
    let isOrganizer: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon.name).foregroundStyle(icon.color)
            VStack(alignment: .leading, spacing: 0) {
                Text(attendee.name ?? email) + Text(attendee.isCurrentUser ? " (you)" : "").foregroundStyle(.secondary)
                if isOrganizer {
                    Text("Organizer").font(.system(size: 10 * s)).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
        .font(.system(size: 12 * s))
        .help(email)
    }

    private var email: String {
        attendee.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
    }

    private var icon: (name: String, color: Color) {
        switch attendee.participantStatus {
        case .accepted: ("checkmark.circle.fill", .green)
        case .declined: ("xmark.circle.fill", .red)
        case .tentative: ("questionmark.circle.fill", .orange)
        default: ("circle.dashed", .secondary)
        }
    }
}

private struct JoinButton: View {
    let url: URL

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            Label("Join \(JoinLink.serviceName(for: url))", systemImage: "video.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}

enum JoinLink {
    private static let services: [(host: String, name: String)] = [
        ("meet.google.com", "Google Meet"),
        ("zoom.us", "Zoom"),
        ("teams.microsoft.com", "Teams"),
        ("teams.live.com", "Teams"),
        ("webex.com", "Webex"),
        ("whereby.com", "Whereby"),
    ]

    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// First video-call link found in any of the given strings.
    static func find(in texts: [String?]) -> URL? {
        for text in texts.compactMap({ $0 }) where !text.isEmpty {
            let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches {
                if let url = match.url, let host = url.host?.lowercased(),
                   services.contains(where: { host == $0.host || host.hasSuffix("." + $0.host) }) {
                    return url
                }
            }
        }
        return nil
    }

    static func serviceName(for url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        return services.first { host == $0.host || host.hasSuffix("." + $0.host) }?.name ?? "Call"
    }
}

/// A colored dot for menus. Pop-up menus draw SF Symbols as monochrome templates (losing the
/// calendar color), so this is a real bitmap marked as non-template.
enum CalendarDot {
    static func image(_ color: CGColor) -> Image {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(cgColor: color)?.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            return true
        }
        image.isTemplate = false
        return Image(nsImage: image)
    }
}

/// Right-click menu for an event: Copy to ▸ any other calendar you can add events to.
struct EventContextMenu: View {
    @Environment(AppModel.self) private var model
    let eventID: String

    var body: some View {
        if let event = model.events.first(where: { $0.id == eventID }) {
            let current = event.ek.calendar?.calendarIdentifier
            Menu("Copy to") {
                ForEach(model.writableCalendars.filter { $0.calendarIdentifier != current }, id: \.calendarIdentifier) { calendar in
                    Button { model.copy(eventID, to: calendar) } label: {
                        Label { Text(calendar.title) } icon: { CalendarDot.image(calendar.cgColor) }
                    }
                }
            }
        }
    }
}
