import EventKit
import SwiftUI

/// A fetched EventKit event (or one occurrence of a repeating event).
struct CalEvent: Identifiable {
    let ek: EKEvent
    let id: String

    init(_ ek: EKEvent) {
        self.ek = ek
        self.id = CalEvent.id(for: ek)
    }

    /// Stable across moves: repeating events are keyed by their original occurrence date,
    /// which EventKit keeps even after an occurrence is rescheduled.
    static func id(for ek: EKEvent) -> String {
        guard ek.hasRecurrenceRules, let occurrence = ek.occurrenceDate else {
            return ek.calendarItemIdentifier
        }
        return "\(ek.calendarItemIdentifier)|\(occurrence.timeIntervalSinceReferenceDate)"
    }

    var hasGuests: Bool {
        (ek.attendees ?? []).contains { !$0.isCurrentUser }
    }

    /// Events with guests stay read-only until invites go through the Google API (step 2),
    /// so nothing here can trigger update emails to other people.
    var isEditable: Bool {
        (ek.calendar?.allowsContentModifications ?? false) && !hasGuests
    }
}

/// What the grid and month views draw: a fetched event with any in-progress edits applied.
struct DisplayEvent: Identifiable, Equatable {
    let id: String
    var calendarID: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var color: Color
    var location: String?
    var isEditable: Bool
    var isDraft = false
    /// On a hidden calendar: still takes part in layout, but isn't drawn.
    var isHidden = false

    init(_ event: CalEvent) {
        id = event.id
        calendarID = event.ek.calendar?.calendarIdentifier ?? ""
        title = DisplayEvent.displayTitle(event.ek.title)
        start = event.ek.startDate
        end = event.ek.endDate
        isAllDay = event.ek.isAllDay
        color = Color(cgColor: event.ek.calendar?.cgColor ?? CGColor(gray: 0.5, alpha: 1))
        location = event.ek.location
        isEditable = event.isEditable
    }

    init(draftID: String, draft: EventDraft, color: Color) {
        id = draftID
        calendarID = draft.calendarID
        title = ""
        start = draft.start
        end = draft.end
        isAllDay = false
        self.color = color
        isEditable = true
        isDraft = true
        apply(draft, color: color)
    }

    mutating func apply(_ draft: EventDraft, color: Color) {
        title = DisplayEvent.displayTitle(draft.title)
        isAllDay = draft.isAllDay
        start = draft.start
        // Drafts store an all-day event's last day; the views expect an exclusive end.
        end = draft.isAllDay ? Calendar.current.date(byAdding: .day, value: 1, to: draft.end)! : draft.end
        location = draft.location.isEmpty ? nil : draft.location
        calendarID = draft.calendarID
        self.color = color
    }

    static func displayTitle(_ title: String?) -> String {
        guard let title, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return "New Event" }
        return title
    }

    /// All-day events, plus timed events long enough that they read better as a bar.
    var isAllDayLike: Bool { isAllDay || end.timeIntervalSince(start) >= 24 * 3600 }

    func lastDay(in cal: Calendar) -> Date {
        cal.startOfDay(for: max(start, end.addingTimeInterval(-1)))
    }

    func occurs(on day: Date, in cal: Calendar) -> Bool {
        let dayStart = cal.startOfDay(for: day)
        if isAllDayLike {
            return cal.startOfDay(for: start) <= dayStart && dayStart <= lastDay(in: cal)
        }
        let nextDay = cal.date(byAdding: .day, value: 1, to: dayStart)!
        return start < nextDay && (end > dayStart || start >= dayStart)
    }

    var timeRangeText: String {
        isAllDay ? "All-day" : "\(start.shortTime) – \(end.shortTime)"
    }
}

enum RepeatRule: String, CaseIterable, Identifiable {
    case none, daily, weekdays, weekly, biweekly, monthly, yearly, custom

    var id: Self { self }

    var label: String {
        switch self {
        case .none: "Never"
        case .daily: "Every Day"
        case .weekdays: "Every Weekday"
        case .weekly: "Every Week"
        case .biweekly: "Every 2 Weeks"
        case .monthly: "Every Month"
        case .yearly: "Every Year"
        case .custom: "Custom"
        }
    }

    private static let weekdayNumbers: Set<Int> = [2, 3, 4, 5, 6] // Mon–Fri in EKWeekday

    /// Recognizes the simple rules this app can edit; anything richer is `.custom` and left untouched.
    init(rules: [EKRecurrenceRule]?) {
        guard let rules, !rules.isEmpty else { self = .none; return }
        guard rules.count == 1, let r = rules.first, r.recurrenceEnd == nil,
              r.daysOfTheMonth == nil, r.monthsOfTheYear == nil, r.weeksOfTheYear == nil,
              r.daysOfTheYear == nil, r.setPositions == nil
        else { self = .custom; return }

        let days = Set((r.daysOfTheWeek ?? []).map { $0.dayOfTheWeek.rawValue })
        switch (r.frequency, r.interval) {
        case (.daily, 1) where days.isEmpty: self = .daily
        case (.weekly, 1) where days == RepeatRule.weekdayNumbers: self = .weekdays
        case (.weekly, 1) where days.count <= 1: self = .weekly
        case (.weekly, 2) where days.count <= 1: self = .biweekly
        case (.monthly, 1) where days.isEmpty: self = .monthly
        case (.yearly, 1) where days.isEmpty: self = .yearly
        default: self = .custom
        }
    }

    var rules: [EKRecurrenceRule]? {
        switch self {
        case .none, .custom: nil
        case .daily: [EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)]
        case .weekly: [EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)]
        case .biweekly: [EKRecurrenceRule(recurrenceWith: .weekly, interval: 2, end: nil)]
        case .monthly: [EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: nil)]
        case .yearly: [EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: nil)]
        case .weekdays:
            [EKRecurrenceRule(
                recurrenceWith: .weekly, interval: 1,
                daysOfTheWeek: RepeatRule.weekdayNumbers.sorted().map { EKRecurrenceDayOfWeek(EKWeekday(rawValue: $0)!) },
                daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil,
                daysOfTheYear: nil, setPositions: nil, end: nil)]
        }
    }
}

/// Editable copy of an event's fields. Changes are written to EventKit only on commit,
/// so typing in the inspector never produces a stream of saves.
/// For all-day events, `start` and `end` are the first and last days (midnight, inclusive).
struct EventDraft: Equatable {
    var title = ""
    var start: Date
    var end: Date
    var isAllDay = false
    var location = ""
    var notes = ""
    var urlString = ""
    var calendarID: String
    var recurrence: RepeatRule = .none

    init(start: Date, end: Date, isAllDay: Bool, calendarID: String) {
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendarID = calendarID
    }

    init(_ ek: EKEvent) {
        let cal = Calendar.current
        title = ek.title ?? ""
        isAllDay = ek.isAllDay
        start = ek.startDate
        end = ek.endDate
        if isAllDay {
            start = cal.startOfDay(for: start)
            end = cal.startOfDay(for: max(start, end.addingTimeInterval(-1)))
        }
        location = ek.location ?? ""
        notes = ek.notes ?? ""
        urlString = ek.url?.absoluteString ?? ""
        calendarID = ek.calendar?.calendarIdentifier ?? ""
        recurrence = RepeatRule(rules: ek.recurrenceRules)
    }

    /// Writes changed fields onto `ek`. Pass `original: nil` for a brand-new event.
    func apply(to ek: EKEvent, store: EventStoring, original: EventDraft?) {
        func changed<T: Equatable>(_ keyPath: KeyPath<EventDraft, T>) -> Bool {
            original.map { $0[keyPath: keyPath] != self[keyPath: keyPath] } ?? true
        }
        if changed(\.title) { ek.title = title.trimmingCharacters(in: .whitespacesAndNewlines) }
        if changed(\.isAllDay) || changed(\.start) || changed(\.end) {
            // Order matters: with isAllDay already set, EventKit snaps the end to 23:59:59 of the given
            // (last) day. Setting the end first and isAllDay after would treat it as exclusive and lose a day.
            ek.isAllDay = isAllDay
            ek.startDate = start
            ek.endDate = end
        }
        if changed(\.location) { ek.location = location.isEmpty ? nil : location }
        if changed(\.notes) { ek.notes = notes.isEmpty ? nil : notes }
        if changed(\.urlString) {
            let trimmed = urlString.trimmingCharacters(in: .whitespaces)
            ek.url = trimmed.isEmpty ? nil : URL(string: trimmed)
        }
        if changed(\.calendarID), let calendar = store.calendar(withIdentifier: calendarID) {
            ek.calendar = calendar
        }
        if changed(\.recurrence), recurrence != .custom {
            ek.recurrenceRules = recurrence.rules
        }
    }
}

struct EditSession {
    let id: String
    let event: EKEvent
    let isNew: Bool
    let isEditable: Bool
    var draft: EventDraft
    var original: EventDraft
    /// The event's box on screen (window points, top-left origin), for the editor popover to attach to.
    var anchor: CGRect?
    /// A single click only selects; the editor popover opens on double-click, Return, or for new events.
    var showsEditor = false

    var hasChanges: Bool { draft != original }
}

/// "This event or all future events?" for repeating events.
struct SpanPrompt: Identifiable {
    let id = UUID()
    let title: String
    let verb: String
    let perform: (EKSpan) -> Void
    var onCancel: () -> Void = {}
}

enum ViewMode: String, CaseIterable, Identifiable {
    case day, week, month

    var id: Self { self }
    var title: String { rawValue.capitalized }

    var step: Calendar.Component {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }
}
