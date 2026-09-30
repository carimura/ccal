import EventKit
import Foundation

/// A searchable event: display values plus folded text (title, location, notes) to match against.
struct SearchItem: Identifiable {
    let event: DisplayEvent
    let isRecurring: Bool
    let calendarTitle: String
    let text: String

    var id: String { event.id }

    init(_ event: CalEvent) {
        self.event = DisplayEvent(event)
        isRecurring = event.ek.hasRecurrenceRules
        calendarTitle = event.ek.calendar?.title ?? ""
        text = SearchItem.fold([event.ek.title, event.ek.location, event.ek.notes].compactMap { $0 }.joined(separator: "\n"))
    }

    /// Case- and accent-insensitive form, so "cafe" finds "Café".
    static func fold(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// Every word in the query must appear somewhere in the event.
    static func tokens(_ query: String) -> [String] {
        fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
